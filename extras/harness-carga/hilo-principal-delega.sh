#!/bin/bash
# PreToolUse: vigila que el hilo principal no haga por su cuenta el trabajo de volumen.
#
# Por qué hace falta un hook para esto:
#   - No existe límite nativo de gasto para sesiones interactivas: `--max-budget-usd` y
#     `--max-turns` solo funcionan en modo -p (verificado en la doc, 2-sep-2026).
#   - El payload de los hooks no trae NINGUNA telemetría de tokens ni de contexto. Lo más
#     cercano es `effort.level`, que es configuración, no consumo.
#   - Con permissionDecision "allow", el `permissionDecisionReason` se le muestra al usuario
#     pero NO a Claude. El único canal que llega al modelo es `additionalContext`.
#
# Así que esto cuenta, compara y avisa AL MODELO. No bloquea: interrumpir a media faena
# hace más daño que el gasto que evita.
#
# El aviso se dispara cada AVISO_CADA tool calls de volumen sin ninguna delegación nueva.
set -uo pipefail

INPUT="$(cat)"
AVISO_CADA=15

# agent_id solo está presente cuando el hook corre DENTRO de un subagente. Si está, no es
# el hilo principal y acá no hay nada que vigilar: el subagente ya es la delegación.
AGENT_ID=$(printf '%s' "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null)
[ -n "$AGENT_ID" ] && { echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'; exit 0; }

SID=$(printf '%s' "$INPUT" | jq -r '.session_id // "sin-sesion"' 2>/dev/null)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
EST="$HOME/.claude/state/hilo/${SID//[^A-Za-z0-9._-]/_}"

# estado: <tool_calls> <delegaciones> <tools_en_el_ultimo_aviso>
if [ -f "$EST" ]; then read -r N D A < "$EST"; else N=0; D=0; A=0; fi
case "$N$D$A" in ''|*[!0-9]*) N=0; D=0; A=0 ;; esac

if [ "$TOOL" = "Agent" ] || [ "$TOOL" = "Task" ]; then
  D=$((D + 1))
  A=$N                     # delegó: se reinicia la cuenta para el próximo aviso
  echo "$N $D $A" > "$EST"
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
  exit 0
fi

N=$((N + 1))
PENDIENTE=$((N - A))

if (( PENDIENTE < AVISO_CADA )); then
  echo "$N $D $A" > "$EST"
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
  exit 0
fi

# Toca avisar. Solo acá se lee la cuota, y por el caché de carga-llm.sh (5 min), así que
# esto no puede gatillar el rate limit del endpoint por más tool calls que haya.
CUOTA=$(bash "$HOME/.claude/bin/carga-llm.sh" --json 2>/dev/null || echo "")
A=$N
echo "$N $D $A" > "$EST"

python3 - "$N" "$D" "$AVISO_CADA" "$CUOTA" <<'PY'
import json, sys
n, d, cada = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
crudo = sys.argv[4] if len(sys.argv) > 4 else ""

corta = None
try:
    c = (json.loads(crudo) or {}).get("claude") or {}
    corta = c.get("corta_usado")
except Exception:
    pass

linea_cuota = ""
if corta is not None:
    linea_cuota = f" La ventana de 5 h va en {corta:.0f}%."
    if corta >= 85:
        linea_cuota += (" Sobre 85 % el margen para terminar algo largo es corto: lo que "
                        "quede de volumen conviene mandarlo a subagentes ahora, no después.")

texto = (
    f"⚠ Aviso del harness al hilo principal: llevas {n} tool calls propias en esta sesión y "
    f"{d} delegaciones. Las últimas {cada} las hiciste sin delegar nada.{linea_cuota}\n\n"
    "Recordatorio de por qué importa: el hilo principal corre en el modelo más caro y "
    "arrastra todo el contexto acumulado, así que cada tool call suya se paga con la ventana "
    "entera, mientras un subagente parte de cero y paga solo su brief. Medido: el 64 % de los "
    "tokens sale de este hilo.\n\n"
    "Antes de la próxima tool call, decide explícitamente una de estas tres:\n"
    "1. Esto es leer/buscar/listar/extraer volumen → delegarlo (haiku si es mecánico, sonnet "
    "si hay que evaluar relevancia).\n"
    "2. Esto es decidir, verificar con un comando corto, o una edición de 1-2 líneas → hacerlo "
    "acá es correcto, seguir sin más.\n"
    "3. Esto es una faena larga que ya empezó acá → cerrarla y delegar lo que queda.\n\n"
    "No respondas a este aviso en el chat ni se lo expliques al usuario: es para tu decisión "
    "interna. Si la opción correcta es la 2, simplemente sigue."
)
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "allow",
        "additionalContext": texto,
    }
}, ensure_ascii=False))
PY
