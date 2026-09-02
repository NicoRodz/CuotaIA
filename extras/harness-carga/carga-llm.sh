#!/bin/bash
# Foto de carga de los dos ejecutores (Claude Code y Codex) con la única métrica que
# decide algo: el ritmo de consumo del límite SEMANAL contra el ritmo sostenible.
#
# Por qué el semanal y no la ventana de 5 h: la ventana corta se recupera sola cada 5
# horas, así que un pico ahí no cuesta nada mañana. El semanal no se recupera hasta su
# reset, así que es el único techo que puede dejar un proyecto sin ejecutor a mitad de
# semana. El 2-sep-2026 los dos números decían cosas opuestas: Codex tenía el 97 % de su
# ventana corta libre y a la vez el 79 % del semanal quemado. Mirar solo el corto lleva
# a cargar precisamente al que se está muriendo.
#
# Uso:  carga-llm.sh          formato humano
#       carga-llm.sh --json   para hooks y scripts
set -uo pipefail

CACHE="$HOME/.claude/state/carga-claude.json"
CACHE_SEG=300      # el endpoint de cuota tiene rate limit propio (429): no se sondea más seguido
FORMATO="${1:-humano}"

mkdir -p "$HOME/.claude/state"

# --- Claude: endpoint de cuota, con caché para no gatillar el 429 -------------
claude_json() {
  if [ -f "$CACHE" ]; then
    local edad
    edad=$(( $(date +%s) - $(stat -f %m "$CACHE") ))
    if (( edad < CACHE_SEG )); then cat "$CACHE"; return 0; fi
  fi
  local tok resp
  tok=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["claudeAiOauth"]["accessToken"])' 2>/dev/null) || return 1
  [ -n "$tok" ] || return 1
  resp=$(curl -sS --max-time 20 https://api.anthropic.com/api/oauth/usage \
           -H "Authorization: Bearer $tok" -H "anthropic-beta: oauth-2025-04-20" 2>/dev/null) || return 1
  # Solo se cachea una respuesta que de verdad trae los datos: un 429 o un error jamás
  # debe quedar guardado como si fuera una lectura buena.
  printf '%s' "$resp" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if "five_hour" in d else 1)' 2>/dev/null || return 1
  printf '%s' "$resp" > "$CACHE"
  printf '%s' "$resp"
}

# --- Codex: último rate_limits que dejó en su rollout más reciente ------------
codex_rollout() {
  find "$HOME/.codex/sessions" -name "rollout-*.jsonl" -type f -print0 2>/dev/null \
    | xargs -0 ls -t 2>/dev/null | head -1
}

CLAUDE_RAW=$(claude_json) || CLAUDE_RAW=""
CODEX_FILE=$(codex_rollout)

# El JSON va por archivo, no por stdin: stdin ya lo ocupa el heredoc con el programa.
CLAUDE_TMP=$(mktemp -t carga-llm)
trap 'rm -f "$CLAUDE_TMP"' EXIT
printf '%s' "$CLAUDE_RAW" > "$CLAUDE_TMP"

python3 - "$FORMATO" "$CODEX_FILE" "$CLAUDE_TMP" <<'PY'
import json, sys, os, datetime, zoneinfo
formato = sys.argv[1]
codex_file = sys.argv[2] if len(sys.argv) > 2 else ""
claude_tmp = sys.argv[3] if len(sys.argv) > 3 else ""
def zona_local():
    """Zona del sistema CON sus reglas de horario de verano.

    `datetime.now().astimezone().tzinfo` no sirve acá: devuelve el offset fijo de hoy,
    así que toda fecha futura que cruce el cambio de hora se muestra corrida (medido:
    con Chile pasando de -04 a -03 el 6-sep-2026, un reset del lunes 00:33 aparecía
    como domingo 23:33). Hay que resolver el NOMBRE de la zona, no su offset.
    """
    nombre = os.environ.get("TZ") or None
    if not nombre:
        try:
            real = os.path.realpath("/etc/localtime")
            if "/zoneinfo/" in real:
                nombre = real.split("/zoneinfo/")[-1]
        except Exception:
            nombre = None
    if nombre:
        try:
            return zoneinfo.ZoneInfo(nombre)
        except Exception:
            pass
    return datetime.datetime.now().astimezone().tzinfo   # último recurso

tz = zona_local()
ahora = datetime.datetime.now(tz)
SEMANA = 7 * 86400

def reloj(dt):
    return dt.strftime("%a %d %H:%M") if dt else "?"

def ritmo(usado_pct, reset_epoch, largo_seg=SEMANA):
    """Compara el consumo real contra el sostenible y proyecta el agotamiento."""
    if usado_pct is None or not reset_epoch:
        return None
    reset = datetime.datetime.fromtimestamp(reset_epoch, tz)
    inicio = reset - datetime.timedelta(seconds=largo_seg)
    transcurrido = (ahora - inicio).total_seconds()
    if transcurrido <= 0:
        return None
    frac = transcurrido / largo_seg                  # cuánto de la semana ya pasó
    sostenible = frac * 100                          # cuánto podrías haber gastado
    dias_restantes = (reset - ahora).total_seconds() / 86400
    restante = 100 - usado_pct
    proyeccion = None
    if usado_pct > 0:
        # A este ritmo, ¿cuándo llega al 100 %?
        seg_al_100 = transcurrido * (100 / usado_pct)
        proyeccion = inicio + datetime.timedelta(seconds=seg_al_100)
    return {
        "usado": usado_pct, "restante": restante, "reset": reset,
        "sostenible": sostenible, "factor": usado_pct / sostenible if sostenible else None,
        "dias_restantes": dias_restantes,
        "diario_disponible": restante / dias_restantes if dias_restantes > 0 else None,
        "proyeccion_agotamiento": proyeccion,
        "alcanza": (proyeccion is None) or (proyeccion >= reset),
    }

datos = {"claude": None, "codex": None}

# --- Claude ---
try:
    with open(claude_tmp, encoding="utf-8") as fh:
        d = json.load(fh)
except Exception:
    d = None
if isinstance(d, dict) and "five_hour" in d:
    f, w = d.get("five_hour") or {}, d.get("seven_day") or {}
    def ep(s):
        return int(datetime.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()) if s else 0
    datos["claude"] = {
        "corta_usado": f.get("utilization"),
        "corta_reset": datetime.datetime.fromtimestamp(ep(f.get("resets_at")), tz) if f.get("resets_at") else None,
        "semanal": ritmo(w.get("utilization"), ep(w.get("resets_at"))),
    }

# --- Codex ---
if codex_file and os.path.exists(codex_file):
    ult = None
    def busca(o):
        if isinstance(o, dict):
            if isinstance(o.get("rate_limits"), dict):
                return o["rate_limits"]
            for v in o.values():
                r = busca(v)
                if r: return r
        elif isinstance(o, list):
            for v in o:
                r = busca(v)
                if r: return r
        return None
    with open(codex_file, encoding="utf-8", errors="ignore") as fh:
        for ln in fh:
            if '"rate_limits"' not in ln:
                continue
            try:
                r = busca(json.loads(ln))
            except Exception:
                continue
            if r: ult = r
    if ult:
        pri, sec = ult.get("primary") or {}, ult.get("secondary") or {}
        def reset_ep(w):
            if w.get("resets_at"): return int(w["resets_at"])
            s = w.get("resets_in_seconds")
            return int(ahora.timestamp() + s) if isinstance(s, (int, float)) else 0
        largo_sec = (sec.get("window_minutes") or 10080) * 60
        datos["codex"] = {
            "corta_usado": pri.get("used_percent"),
            "corta_reset": datetime.datetime.fromtimestamp(reset_ep(pri), tz) if reset_ep(pri) else None,
            "semanal": ritmo(sec.get("used_percent"), reset_ep(sec), largo_sec),
        }

if formato == "--json":
    def ser(o):
        if isinstance(o, datetime.datetime): return o.isoformat()
        return o
    print(json.dumps(datos, default=ser, ensure_ascii=False))
    sys.exit(0)

# --- formato humano ----------------------------------------------------------
print(f"Carga de ejecutores · {ahora:%a %d-%b %H:%M}")
print()
print(f"{'':8} {'ventana corta':>16} {'semanal':>10} {'sostenible':>11} {'ritmo':>7} {'queda/día':>10}")
for nombre, etq in (("claude", "Claude"), ("codex", "Codex")):
    v = datos[nombre]
    if not v:
        print(f"{etq:8} {'sin datos':>16}")
        continue
    s = v["semanal"] or {}
    corta = f"{v['corta_usado']:.0f}% → {v['corta_reset']:%H:%M}" if v.get("corta_usado") is not None and v.get("corta_reset") else "?"
    factor = f"{s['factor']:.1f}x" if s.get("factor") else "?"
    diario = f"{s['diario_disponible']:.1f}%" if s.get("diario_disponible") else "?"
    print(f"{etq:8} {corta:>16} {s.get('usado', '?'):>9}% {s.get('sostenible', 0):>10.0f}% {factor:>7} {diario:>10}")

print()
for nombre, etq in (("claude", "Claude"), ("codex", "Codex")):
    s = (datos[nombre] or {}).get("semanal")
    if not s: continue
    if not s["alcanza"]:
        print(f"⚠ {etq}: a este ritmo el semanal se agota {reloj(s['proyeccion_agotamiento'])}, "
              f"antes del reset ({reloj(s['reset'])}). Tope sostenible: {s['diario_disponible']:.1f}%/día.")
    else:
        print(f"✓ {etq}: el ritmo alcanza hasta el reset ({reloj(s['reset'])}). "
              f"Margen: {s['diario_disponible']:.1f}%/día.")
PY
