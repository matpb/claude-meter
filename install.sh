#!/usr/bin/env bash
# Claude Meter — installer for KDE Plasma 6.
# Installs the plasmoid (which bundles its own reader script), then offers to add it to your panel.
set -euo pipefail

ID="org.mat.claudemeter"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$HERE/plasmoid/$ID"
DEST="$HOME/.local/share/plasma/plasmoids/$ID"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m  %s\n' "$*"; }

# ---- 1. dependency check ---------------------------------------------------
say "Checking dependencies…"
missing=()
for c in jq sqlite3 openssl curl python3; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
command -v qdbus-qt6 >/dev/null 2>&1 || command -v qdbus6 >/dev/null 2>&1 || missing+=("qdbus (qt6)")
command -v kpackagetool6 >/dev/null 2>&1 || missing+=("kpackagetool6")
if [ "${#missing[@]}" -gt 0 ]; then
    warn "Missing: ${missing[*]}"
    warn "Install them with your package manager, e.g.:"
    warn "  Fedora/KDE : sudo dnf install jq sqlite openssl curl python3 qt6-qttools kf6-kpackage"
    warn "  Arch       : sudo pacman -S jq sqlite openssl curl python qt6-tools"
    warn "  openSUSE   : sudo zypper install jq sqlite3 openssl curl python3 qt6-tools"
    echo
    read -r -p "Continue anyway? [y/N] " a; [ "${a,,}" = "y" ] || exit 1
fi

# ---- 2. install the plasmoid ----------------------------------------------
say "Installing the plasmoid ($ID)…"
if kpackagetool6 -t Plasma/Applet -s "$ID" >/dev/null 2>&1; then
    kpackagetool6 -t Plasma/Applet -u "$PKG"
else
    kpackagetool6 -t Plasma/Applet -i "$PKG" 2>/dev/null || {
        warn "kpackagetool install failed; copying files directly."
        mkdir -p "$DEST"; cp -rT "$PKG" "$DEST"
    }
fi
kbuildsycoca6 >/dev/null 2>&1 || true
say "Installed."

# ---- 3. offer to add it to a panel ----------------------------------------
echo
read -r -p "Add 'Claude Meter' to your top panel now? [Y/n] " a
if [ "${a,,}" != "n" ]; then
    Q=$(command -v qdbus-qt6 || command -v qdbus6 || true)
    if [ -n "$Q" ]; then
        "$Q" org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript '
            var ps = panels(); var target = ps.find(p => p.location == "top") || ps[0];
            if (target) { target.addWidget("org.mat.claudemeter"); }
        ' >/dev/null 2>&1 && say "Added to your panel." \
          || warn "Could not add automatically — right-click your panel → Add Widgets → Claude Meter."
    else
        warn "qdbus not found — right-click your panel → Add Widgets → Claude Meter."
    fi
fi

echo
say "Done. If the widget doesn't appear or update, run:  kquitapp6 plasmashell && kstart plasmashell"
say "It reads your live usage from claude.ai using your browser's session cookie (KWallet must be unlocked)."
say "Optional offline fallback via a Claude Code statusline: see extras/statusline-cache.sh"
