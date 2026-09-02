#!/usr/bin/env bash
#
# require-agent-model.sh — PreToolUse hook para el tool `Agent`
#
# Impone dos reglas:
#   1. Toda llamada a `Agent` debe declarar `model` explícito.
#      Omitirlo hereda el modelo de la sesión (Opus) = gasto no decidido.
#   2. Un brief de recolección (buscar/listar/mapear/consolidar) no puede ir en Opus.
#
# Aplica TAMBIÉN dentro de subagentes: la doc confirma que los hooks corren en
# subagentes con agent_id/agent_type en el payload. El enforcement es transitivo:
# un nieto lanzado por un hijo pasa por acá igual.
#
# Escape consciente: escribir `MODELO JUSTIFICADO:` seguido del motivo en el prompt.
# No es un bypass mudo — obliga a dejar por escrito por qué.


set -uo pipefail   # sin -e: un fallo no debe romper el flujo de trabajo

INPUT="$(cat)"
LOG="$HOME/.claude/hooks/agent-model.log"

python3 - "$INPUT" "$LOG" <<'PYEOF'
import json, sys, re, os, datetime

raw, logpath = sys.argv[1], sys.argv[2]

def emit(decision, reason=None):
    out = {"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                  "permissionDecision": decision}}
    if reason:
        out["hookSpecificOutput"]["permissionDecisionReason"] = reason
    print(json.dumps(out))
    sys.exit(0)

try:
    data = json.loads(raw)
except Exception:
    emit("allow")            # payload ilegible: no obstruir

ti      = data.get("tool_input", {}) or {}
model   = (ti.get("model") or "").strip()
prompt  = (ti.get("prompt") or "")
desc    = (ti.get("description") or "")
sub     = (ti.get("subagent_type") or "")
blob    = f"{desc}\n{prompt}".lower()

# Registro de toda invocación, para auditar después qué modelo se usó y para qué.
try:
    with open(logpath, "a", encoding="utf-8") as f:
        f.write(json.dumps({
            "ts": datetime.datetime.now().isoformat(timespec="seconds"),
            "model": model or "(AUSENTE)",
            "subagent_type": sub,
            "agent_id": data.get("agent_id"),        # presente si el llamador es un subagente
            "agent_type": data.get("agent_type"),
            "desc": desc[:120],
        }, ensure_ascii=False) + "\n")
except Exception:
    pass

TABLA = ("Tabla: traer/buscar/listar/mapear/consolidar/reindexar -> sonnet "
         "(haiku si es mecanico puro) | decidir/diagnosticar/juzgar/disenar/auditar -> opus | "
         "veredicto final -> fable.")

# --- 1. model explícito, siempre ---
if not model:
    emit("deny",
         "BLOQUEADO: la llamada a Agent no declara `model`. "
         "Omitirlo NO es un default neutro: hereda el modelo de la sesion (Opus) y gasta "
         "cuota sin decidirlo. Reintenta pasando model explicitamente. " + TABLA)

# --- 2. coherencia tarea/modelo ---
if "modelo justificado:" in blob:
    emit("allow")                                   # override consciente y por escrito

norm = model.lower()
es_caro = ("opus" in norm) or ("fable" in norm)

RECOLECCION = r"\b(busca\w*|buscar|lista\w*|listar|mapea\w*|mapear|encuentra\w*|localiza\w*|" \
              r"inventaria\w*|recopila\w*|recolecta\w*|consolida\w*|reindexa\w*|renombra\w*|" \
              r"extrae\w*|resume\w*|resumir|cuenta\w*|contar|grep|find|escanea\w*|" \
              r"search|list|map|gather|collect|count)\b"
JUICIO      = r"\b(decide\w*|decidir|diagnostica\w*|diagnosticar|juzga\w*|juzgar|disena\w*|" \
              r"disenar|diseña\w*|diseñar|arquitect\w*|veredicto|audita\w*|auditar|refuta\w*|" \
              r"refutar|evalua\w*|evaluar|critica\w*|council|decide|judge|design|verdict|" \
              r"audit|refute|adversarial)\b"

# --- 2.a Lista blanca para modelos caros -------------------------------------
# La regla vieja era una lista NEGRA: bloqueaba Opus solo si el brief parecía recoleccion
# Y NO contenia ninguna palabra de juicio. Se esquivaba escribiendo "evalua" al pasar, sin
# intencion de burlarla — es como se redacta normalmente. Medido el 2-sep-2026: 118 de 340
# invocaciones de 14 dias corrieron en Opus y ni una en Haiku.
# Ahora la carga de la prueba se invierte: un modelo caro pasa solo si hay una decision
# previa por escrito. Las hay de dos formas.
AGENTES_DIR = os.path.expanduser("~/.claude/agents")

def modelo_de_definicion(nombre):
    """Modelo declarado en el frontmatter del agente, si el agente existe.

    Un `model: opus` puesto a mano en la definicion ES la justificacion escrita: el usuario
    ya decidio que ese especialista vale Opus. Volver a preguntarselo en cada invocacion es
    fricción sin informacion nueva.
    """
    if not nombre:
        return None
    ruta = os.path.join(AGENTES_DIR, f"{nombre}.md")
    try:
        with open(ruta, encoding="utf-8") as fh:
            for i, linea in enumerate(fh):
                if i > 15:
                    break
                m = re.match(r"^model:\s*(\S+)", linea)
                if m:
                    return m.group(1).strip().lower()
    except Exception:
        return None
    return None

if es_caro:
    declarado = modelo_de_definicion(sub)
    if declarado and (("opus" in declarado) or ("fable" in declarado)):
        emit("allow")        # el especialista nacio caro por decision explicita
    if declarado:            # definido como sonnet y se pide opus: contradice su definicion
        emit("deny",
             f"BLOQUEADO: pediste model='{model}' para el agente '{sub}', cuya definicion "
             f"declara model='{declarado}'. Si esta invocacion de verdad necesita mas modelo, "
             "escribe en el prompt 'MODELO JUSTIFICADO: <razon>'. " + TABLA)
    # Agente genérico (general-purpose, claude, fork, Explore, Plan...) con modelo caro:
    # aca es donde se concentra el gasto no decidido, asi que exige la razon por escrito.
    emit("deny",
         f"BLOQUEADO: model='{model}' en un agente genérico ('{sub or 'sin tipo'}') sin "
         "justificacion. Un modelo caro en un agente genérico es la via por la que se gasta "
         "cuota sin decidirlo: 118 de 340 invocaciones de los ultimos 14 dias fueron Opus y "
         "ninguna Haiku. Si la tarea es traer/listar/mapear/extraer, relanza con "
         "model='haiku' (mecanico puro) o 'sonnet' (hay que evaluar relevancia). Si de verdad "
         "pide juicio, escribe en el prompt 'MODELO JUSTIFICADO: <razon>' y pasa. " + TABLA)

if False:  # rama muerta: la logica de recoleccion quedo cubierta arriba
    tiene_recol  = re.search(RECOLECCION, blob) is not None
    tiene_juicio = re.search(JUICIO, blob) is not None
    if tiene_recol and not tiene_juicio:
        emit("deny",
             f"BLOQUEADO: model='{model}' para un brief que es RECOLECCION, "
             "no juicio. El costo se concentra donde hay criterio, no donde hay lectura. "
             "Relanza con model='sonnet' (o 'haiku' si es mecanico puro). " + TABLA +
             " Si de verdad requiere Opus, escribe en el prompt 'MODELO JUSTIFICADO: <razon>'.")

emit("allow")
PYEOF
