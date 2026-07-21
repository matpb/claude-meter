#!/usr/bin/env bash
# Claude Meter — uninstaller.
set -uo pipefail
ID="org.mat.claudemeter"

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

say "Removing the plasmoid…"
kpackagetool6 -t Plasma/Applet -r "$ID" 2>/dev/null \
    || rm -rf "$HOME/.local/share/plasma/plasmoids/$ID"
kbuildsycoca6 >/dev/null 2>&1 || true

# Remove the cached org id (no secrets are stored anywhere else).
rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/claude-meter/org_id" 2>/dev/null || true
rmdir "${XDG_CONFIG_HOME:-$HOME/.config}/claude-meter" 2>/dev/null || true

say "Removed. Remove the widget from your panel by right-clicking it → Remove."
say "Restart the shell to fully unload it:  kquitapp6 plasmashell && kstart plasmashell"
