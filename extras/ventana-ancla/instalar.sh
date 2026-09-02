#!/bin/bash
# Instala (o desinstala con --desinstalar) el anclaje de la ventana de 5 h.
set -euo pipefail

LABEL="cl.claude.ventana-ancla"
DESTINO="$HOME/.claude/bin/ventana-ancla.sh"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
ORIGEN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "${1:-}" = "--desinstalar" ]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "Desinstalado. El script sigue en $DESTINO por si lo quieres correr a mano."
  exit 0
fi

command -v claude >/dev/null 2>&1 || [ -x "$HOME/.local/bin/claude" ] || {
  echo "No encuentro el CLI de Claude Code. Instálalo antes de esto." >&2; exit 1; }

mkdir -p "$HOME/.claude/bin" "$HOME/.claude/logs" "$HOME/.claude/state"
install -m 755 "$ORIGEN/ventana-ancla.sh" "$DESTINO"
sed "s|__HOME__|$HOME|g" "$ORIGEN/cl.claude.ventana-ancla.plist.template" > "$PLIST"
plutil -lint "$PLIST" >/dev/null

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "Instalado. Rejilla por defecto: 06 / 11 / 16 / 21."
echo "Para cambiarla, edita TARGETS en $DESTINO"
echo "Log de decisiones: $HOME/.claude/logs/ventana-ancla.log"
