#!/bin/bash
# Ancla la ventana rodante de 5 h de Claude Code en una rejilla fija: 06 / 11 / 16 / 21.
#
# Por qué existe: la ventana de 5 h se ancla en el primer mensaje que manda el usuario
# después de que expiró la anterior, y lo hace AL MINUTO EXACTO (medido 2-sep-2026:
# ancla 09:09 -> reset 14:09; no redondea a la hora en punto, al contrario de lo que
# dicen los blogs sobre el tema). Como 24 no es múltiplo de 5, el corte de la tarde
# depende por completo de a qué hora arrancó el día.
#
# Con la rejilla clavada en 06/11/16/21, el tercer corte cae a las 21:00. Si esa es la
# hora de mayor consumo, la ventana fresca entra intacta justo ahí. Conviene elegir los
# targets midiendo en qué franjas se consume de verdad, no por intuición.
#
# Por qué no basta un solo cron matutino (que es lo que hace github.com/vdsmon/claude-warmup):
# el drift es acumulativo. Si a las 11:00 el usuario está en pausa y vuelve 11:40, la ventana
# pasa a 11:40-16:40 y el corte de la noche se corre a 21:40 — justo lo que se quería
# evitar. Por eso esto corre cada 10 min y reintenta dentro de una ventana de gracia:
# el primer chequeo que encuentre la ventana anterior ya expirada, ancla.

set -uo pipefail

TARGETS=(06:00 11:00 16:00 21:00)
GRACIA_MIN=90                  # cuánto tiempo después del target se sigue intentando
TECHO_SEG=90                   # techo duro al heartbeat, por si `claude -p` se cuelga
TOLERANCIA_MIN=3               # desvío aceptable del reset resultante vs. lo esperado

# Se resuelve en tiempo de ejecución: launchd no hereda el PATH del shell, así que
# `command -v` puede fallar aunque en la terminal funcione. De ahí las rutas de respaldo.
CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude 2>/dev/null)}"
for cand in "$HOME/.local/bin/claude" "/opt/homebrew/bin/claude" "/usr/local/bin/claude"; do
  [ -x "$CLAUDE_BIN" ] && break
  [ -x "$cand" ] && CLAUDE_BIN="$cand"
done
if [ ! -x "$CLAUDE_BIN" ]; then
  printf '%s no encuentro el binario de claude\n' "$(date '+%F %T')" >> "$HOME/.claude/logs/ventana-ancla.log"
  exit 1
fi
STATE="$HOME/.claude/state/ventana-ancla.state"
CACHE_RESET="$HOME/.claude/state/ventana-ancla.reset"   # epoch del último reset conocido
CACHE_ESPERA="$HOME/.claude/state/ventana-ancla.espera" # para loguear la espera una sola vez
LOG="$HOME/.claude/logs/ventana-ancla.log"

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

# --- rejilla -----------------------------------------------------------------
# Overrides solo para probar la rejilla con horas simuladas; en producción van vacíos.
AHORA=${VENTANA_ANCLA_AHORA:-$(date +%s)}
HOY=${VENTANA_ANCLA_HOY:-$(date '+%F')}

# Devuelve el target vigente (HH:MM) si ahora cae en [target, target+gracia).
target_vigente() {
  local t t_epoch
  for t in "${TARGETS[@]}"; do
    t_epoch=$(date -j -f '%Y-%m-%d %H:%M' "$HOY $t" '+%s' 2>/dev/null) || continue
    if (( AHORA >= t_epoch && AHORA < t_epoch + GRACIA_MIN * 60 )); then
      echo "$t"; return 0
    fi
  done
  return 1
}

TARGET=$(target_vigente) || exit 0          # fuera de toda ventana de gracia: nada que hacer
TARGET_EPOCH=$(date -j -f '%Y-%m-%d %H:%M' "$HOY $TARGET" '+%s')

# Un target se ancla una sola vez al día.
if [ -f "$STATE" ] && grep -qxF "$HOY $TARGET" "$STATE"; then exit 0; fi

# --- corto circuito: no gastar llamadas al endpoint si ya sé cuándo expira ---
# CuotaIA sondea el MISMO endpoint cada 5 min y este tiene rate limit propio (429 con
# ~11 llamadas en 15 min, medido 2-sep-2026). Si en una corrida anterior ya supe que la
# ventana expira a las 14:09, preguntar de nuevo a las 12:10 no aporta nada: se espera
# en seco. Esto baja de ~9 consultas por target a ~2.
RESET_CONOCIDO=$(cat "$CACHE_RESET" 2>/dev/null || echo 0)
case "$RESET_CONOCIDO" in ''|*[!0-9]*) RESET_CONOCIDO=0 ;; esac
if (( RESET_CONOCIDO > AHORA )); then
  if ! grep -qxF "$HOY $TARGET" "$CACHE_ESPERA" 2>/dev/null; then
    log "target=$TARGET espera-cacheada hasta $(date -r "$RESET_CONOCIDO" '+%H:%M') (sin consultar endpoint)"
    echo "$HOY $TARGET" >> "$CACHE_ESPERA"
  fi
  exit 0
fi

# --- estado de cuota ---------------------------------------------------------
# Mismo endpoint que consume CuotaIA. `five_hour` viene con model:None — la ventana
# no está segmentada por modelo, así que un heartbeat con Haiku la ancla igual.
cuota() {
  local tok resp
  tok=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["claudeAiOauth"]["accessToken"])' 2>/dev/null) || return 1
  [ -n "$tok" ] || return 1
  local http
  resp=$(curl -sS --max-time 20 -w '\n%{http_code}' https://api.anthropic.com/api/oauth/usage \
           -H "Authorization: Bearer $tok" \
           -H "anthropic-beta: oauth-2025-04-20" 2>/dev/null) || return 1
  http="${resp##*$'\n'}"; resp="${resp%$'\n'*}"
  printf '%s' "$http" > "$HOME/.claude/state/ventana-ancla.http"   # para el log de arriba
  [ "$http" = "200" ] || return 1
  # El endpoint tiene rate limit PROPIO (HTTP 429, comprobado el 2-sep-2026 con ~8
  # llamadas en 15 min). Un 429 nunca puede traducirse a "no hay ventana viva": eso
  # dispararía un heartbeat a ciegas. Cualquier respuesta que no traiga la clave
  # five_hour hace fallar la función, y el script reintenta en 10 min.
  printf '%s' "$resp" | python3 -c '
import json,sys,datetime
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if not isinstance(d, dict) or "error" in d or "five_hour" not in d:
    sys.exit(1)
f = d.get("five_hour") or {}          # null = no hay ventana activa
w = d.get("seven_day") or {}
r = f.get("resets_at")
epoch = int(datetime.datetime.fromisoformat(r.replace("Z","+00:00")).timestamp()) if r else 0
print(f.get("utilization") or 0, epoch, w.get("utilization") or 0)
' 2>/dev/null
}

ESTADO=$(cuota) || ESTADO=""
if [ -z "$ESTADO" ]; then
  # Sin red o sin credenciales. No se escribe state: el próximo chequeo reintenta.
  HTTP=$(cat "$HOME/.claude/state/ventana-ancla.http" 2>/dev/null || echo "?")
  log "target=$TARGET sin-datos http=$HTTP (429 = rate limit del propio endpoint), reintento en 10 min"
  exit 0
fi
read -r UTIL RESET_EPOCH SEMANAL <<< "$ESTADO"

reloj() { [ "$1" -gt 0 ] && date -r "$1" '+%H:%M' || echo "null"; }

# Ventana viva: el heartbeat no anclaría nada, solo gastaría. Se espera a que expire.
if (( RESET_EPOCH > AHORA )); then
  echo "$RESET_EPOCH" > "$CACHE_RESET"
  log "target=$TARGET espera ventana-viva util=${UTIL}% reset=$(reloj "$RESET_EPOCH") semanal=${SEMANAL}%"
  exit 0
fi

# --- anclar ------------------------------------------------------------------
cd "$HOME" || exit 1
"$CLAUDE_BIN" -p "ok" --model haiku --no-session-persistence >/dev/null 2>&1 &
PID=$!
# Techo con SIGTERM antes de SIGKILL (nada de kill -9 a la primera).
# El watchdog comprueba que este script siga vivo ($$ no cambia en el subshell) antes
# de disparar: si el padre ya murió, el PID pudo haber sido reciclado por otro proceso
# y matarlo a ciegas es exactamente la clase de daño que L39 castiga.
PADRE=$$
( sleep "$TECHO_SEG"
  kill -0 "$PADRE" 2>/dev/null || exit 0
  kill -TERM "$PID" 2>/dev/null; sleep 5
  kill -0 "$PADRE" 2>/dev/null || exit 0
  kill -KILL "$PID" 2>/dev/null ) &
WD=$!
disown "$WD" 2>/dev/null || true      # sin esto el shell escupe "Terminated: 15" al .err
wait "$PID"; RC=$?
kill "$WD" 2>/dev/null || true

if (( RC != 0 )); then
  log "target=$TARGET FALLO heartbeat rc=$RC (no se marca el target, reintento en 10 min)"
  exit 0
fi

# --- verificar que la rejilla quedó donde debía ------------------------------
sleep 3
NUEVO=$(cuota) || NUEVO=""
if [ -n "$NUEVO" ]; then
  read -r N_UTIL N_RESET _ <<< "$NUEVO"
else
  N_UTIL="?"; N_RESET=0
fi

ESPERADO=$(( TARGET_EPOCH + 5 * 3600 ))
if (( N_RESET > 0 )); then
  DESVIO_MIN=$(( (N_RESET - ESPERADO) / 60 ))
  (( DESVIO_MIN < 0 )) && DESVIO_MIN=$(( -DESVIO_MIN ))
  if (( DESVIO_MIN <= TOLERANCIA_MIN )); then
    log "target=$TARGET ANCLADA reset=$(reloj "$N_RESET") util=${N_UTIL}% semanal=${SEMANAL}%"
  else
    log "target=$TARGET ANCLADA-CORRIDA reset=$(reloj "$N_RESET") esperado=$(reloj "$ESPERADO") desvio=${DESVIO_MIN}min util=${N_UTIL}%"
  fi
else
  log "target=$TARGET heartbeat-ok pero el endpoint no devolvió reset (sin verificar)"
fi

(( N_RESET > 0 )) && echo "$N_RESET" > "$CACHE_RESET"
echo "$HOY $TARGET" >> "$STATE"
# El state solo guarda los últimos 30 días de marcas.
tail -n 200 "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
[ -f "$CACHE_ESPERA" ] && { tail -n 200 "$CACHE_ESPERA" > "$CACHE_ESPERA.tmp" && mv "$CACHE_ESPERA.tmp" "$CACHE_ESPERA"; }
