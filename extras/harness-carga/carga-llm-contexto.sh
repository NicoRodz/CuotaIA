#!/bin/bash
# SessionStart: inyecta al contexto la carga de los dos ejecutores.
#
# Por qué existe: la decisión "¿esto lo hace Claude o Codex?" se venía tomando por
# intuición, y la intuición mira la ventana de 5 h — el número que se recupera solo.
# El 2-sep-2026 eso apuntaba al revés: Codex tenía el 97 % de su ventana corta libre
# y a la vez su semanal iba a agotarse al día siguiente. Sin este bloque en el
# contexto, el modelo no tiene con qué enrutar y hay que pedirle el dato a mano.
#
# Nunca falla la sesión: si no hay datos, no imprime nada y sale 0.
set -uo pipefail

SALIDA=$(bash "$HOME/.claude/bin/carga-llm.sh" 2>/dev/null) || exit 0
[ -n "$SALIDA" ] || exit 0
echo "$SALIDA" | grep -q "sin datos" && [ "$(echo "$SALIDA" | grep -c "sin datos")" -ge 2 ] && exit 0

# Reglas propias de cada instalación (restricciones de zona, ejecutores autorizados por
# proyecto, casos concretos). Vive fuera del repo a propósito: el repo es agnóstico y esto
# es lo que cada quien tiene de particular.
LOCAL=""
[ -f "$HOME/.claude/carga-llm.local.md" ] && LOCAL=$(cat "$HOME/.claude/carga-llm.local.md")

python3 - "$SALIDA" "$LOCAL" <<'PY'
import json, sys
cuerpo = sys.argv[1]
local = sys.argv[2] if len(sys.argv) > 2 else ""
contexto = (
    "## Carga de ejecutores (medida al iniciar esta sesión)\n\n"
    "```\n" + cuerpo + "\n```\n\n"
    "Cómo usarlo al decidir ejecutor y modelo:\n"
    "- La columna que decide es **ritmo**, no la ventana corta: la corta se recupera en 5 h, "
    "el semanal no se recupera hasta su reset y es el que puede dejar un proyecto sin ejecutor.\n"
    "- Un ejecutor con ritmo > 1.0x está gastando más rápido de lo que aguanta hasta su reset. "
    "Con ⚠ hay que bajarle carga, no subírsela, aunque su ventana corta esté vacía.\n"
    "- Si hay restricciones sobre qué ejecutor puede tocar qué proyecto, esas mandan sobre "
    "todo lo anterior: cuando el ejecutor con margen no está autorizado en ese proyecto, el "
    "único ajuste posible es el modelo del subagente y diferir trabajo a la ventana siguiente.\n"
    "- Si los dos van con ⚠, mover trabajo de uno a otro no resuelve nada: hay que bajar el "
    "costo por tarea (modelo más chico para recolectar, briefs con techo de salida, menos "
    "relecturas) o posponer lo no urgente al próximo reset.\n"
    "\n"
    "## El hilo principal opera poco: decide y delega\n\n"
    "Medido el 2-sep-2026 sobre 401 transcripts de 14 días: **el 93 % del consumo es Opus, y el "
    "64 % de los tokens sale del hilo principal**. La razón es estructural — el hilo principal "
    "corre en Opus y arrastra todo el contexto acumulado, así que cada tool call suya se paga "
    "con la ventana entera, mientras un subagente parte de cero y paga solo su brief.\n\n"
    "Su trabajo es entender, decidir, escribir briefs, verificar y cerrar. NO ejecutar.\n\n"
    "Lo que sí hace el hilo principal, y nada más:\n"
    "- leer un archivo puntual para tomar una decisión\n"
    "- comandos cortos de verificación, y ejecutar para comprobar (la evidencia no se delega)\n"
    "- ediciones de 1-2 líneas\n"
    "- escribir en la memoria persistente y en el registro de lecciones\n\n"
    "Todo lo demás va a subagente con `model` declarado. Omitir `model` nunca es neutro: hereda "
    "Opus, que es justo lo que hay que evitar en trabajo de volumen.\n"
    "- traer / buscar / listar / mapear / contar / extraer → **Haiku** si es mecánico, "
    "**Sonnet** si hay que evaluar relevancia o aplicar reglas\n"
    "- decidir / diagnosticar causa raíz / revisar código / dar veredicto → **Opus**\n"
    "- diseño de software o solución compleja, y veredicto final en casos difíciles → **Fable**\n\n"
    "Casos reales que corrieron en Opus y debían ir más abajo (medidos en los últimos 14 días, "
    "para reconocer el patrón, no para repasar el pasado):\n"
    "- *\"inventario exhaustivo, no diseño, no opinión\"* → **Haiku**. Si el brief dice "
    "explícitamente que no quiere criterio, no hay nada que pagarle a un modelo caro.\n"
    "- *\"aplica estos seis cambios ya aprobados, uno por uno\"* → **Haiku**. La parte "
    "difícil ya la resolvió el humano; queda ejecución.\n"
    "- *\"trae 3 casos concretos para que el usuario los revise\"* → **Sonnet**. Es buscar evidencia "
    "para que otro decida, no diagnosticar.\n"
    "- *\"arma el deck con el contenido ya aprobado\"* → **Sonnet**. Ensamblar no es decidir.\n"
    "- Nunca relanzar en Opus una tarea que ya corrió bien en Sonnet con el mismo prompt: eso "
    "es costumbre, no necesidad. Si el output de Sonnet falló, decir en qué falló.\n\n"
    "Umbral operativo: antes de emprender algo que va a costar más de 2 tool calls, preguntarse "
    "si un subagente con un brief de ≤250 palabras lo haría igual de bien. Si la respuesta es sí, "
    "delegarlo — el brief cuesta menos que el trabajo. Bajar el modelo NO es bajar la calidad del "
    "entregable: es dejar de pagar precio de decisión por trabajo de recolección.\n"
)
if local.strip():
    contexto += "\n## Reglas propias de esta instalación\n\n" + local.strip() + "\n"

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": contexto,
    }
}, ensure_ascii=False))
PY
