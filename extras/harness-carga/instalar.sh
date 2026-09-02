#!/bin/bash
# Instala el medidor de carga y el hook SessionStart que lo inyecta al contexto de
# Claude Code. Idempotente: correrlo dos veces no duplica el hook.
set -euo pipefail

ORIGEN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="$HOME/.claude/settings.json"

mkdir -p "$HOME/.claude/bin" "$HOME/.claude/hooks" "$HOME/.claude/state"
install -m 755 "$ORIGEN/carga-llm.sh"          "$HOME/.claude/bin/carga-llm.sh"
install -m 755 "$ORIGEN/carga-llm-contexto.sh" "$HOME/.claude/hooks/carga-llm-contexto.sh"
install -m 755 "$ORIGEN/require-agent-model.sh"  "$HOME/.claude/hooks/require-agent-model.sh"
install -m 755 "$ORIGEN/hilo-principal-delega.sh" "$HOME/.claude/hooks/hilo-principal-delega.sh"
mkdir -p "$HOME/.claude/state/hilo"

command -v jq >/dev/null 2>&1 || echo "AVISO: falta jq; el vigilante del hilo principal no contará nada sin él (brew install jq)." >&2

if [ "${1:-}" = "--solo-scripts" ]; then
  echo "Scripts instalados. Hook NO registrado (--solo-scripts)."
  echo "Pruébalo con: ~/.claude/bin/carga-llm.sh"
  exit 0
fi

[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak-$(date +%Y%m%d-%H%M%S)"

python3 - "$SETTINGS" <<'PY'
import json, sys, collections
ruta = sys.argv[1]
with open(ruta) as fh:
    d = json.load(fh, object_pairs_hook=collections.OrderedDict)
hooks = d.setdefault("hooks", collections.OrderedDict())
cambios = []

sesion = hooks.setdefault("SessionStart", [])
if "carga-llm-contexto" in json.dumps(sesion):
    print("SessionStart ya estaba registrado; no se toca.")
else:
    sesion.append({"hooks": [{"type": "command",
                              "command": "bash $HOME/.claude/hooks/carga-llm-contexto.sh"}]})
    cambios.append("SessionStart")

# El guardián de modelo va en PreToolUse y necesita el matcher de los dos nombres del tool:
# segun la version del harness la invocacion de subagente llega como Agent o como Task, y un
# matcher que solo cubra uno deja el guardian sin dispararse nunca, en silencio.
pre = hooks.setdefault("PreToolUse", [])
if "require-agent-model" in json.dumps(pre):
    print("PreToolUse (guardián de modelo) ya estaba registrado; no se toca.")
else:
    pre.append({"matcher": "Agent|Task",
                "hooks": [{"type": "command",
                           "command": "bash $HOME/.claude/hooks/require-agent-model.sh"}]})
    cambios.append("PreToolUse")

if "hilo-principal-delega" in json.dumps(pre):
    print("PreToolUse (vigilante del hilo principal) ya estaba registrado; no se toca.")
else:
    pre.append({"matcher": "Bash|Read|Grep|Glob|Edit|Write|NotebookEdit|Agent|Task",
                "hooks": [{"type": "command",
                           "command": "bash $HOME/.claude/hooks/hilo-principal-delega.sh"}]})
    cambios.append("PreToolUse (vigilante)")

if cambios:
    with open(ruta, "w") as fh:
        json.dump(d, fh, indent=2, ensure_ascii=False)
    print("Registrados:", ", ".join(cambios))
PY

echo "Listo. Se guardó un respaldo de settings.json junto al original."
echo "Verifica con: ~/.claude/bin/carga-llm.sh"
