#!/usr/bin/env bash
# Claude Meter — installer for the SwiftBar plugin. Bash 3.2 compatible (stock macOS /bin/bash).
set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/claude-meter.sh"
instance="claudemeter"

say()  { printf '==> %s\n' "$*"; }
warn() { printf '!  %s\n' "$*"; }

# ---- 1. locate the SwiftBar plugin directory -------------------------------
plugin_dir="$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)"
[ -n "$plugin_dir" ] || plugin_dir="$HOME/SwiftBarPlugins"
mkdir -p "$plugin_dir"
say "SwiftBar plugin directory: $plugin_dir"

# ---- 2. remove stale per-account plugins from the old single-account design ----
for stale in "$plugin_dir/personal.1m.sh" "$plugin_dir/siku.1m.sh"; do
    if [ -f "$stale" ]; then
        rm -f "$stale"
        say "Removed stale plugin: $stale"
    fi
done

# ---- 3. install the single multi-account plugin -----------------------------
dest="$plugin_dir/$instance.1m.sh"
# symlink, not copy: a git pull in this clone updates the live plugin
chmod +x "$SRC"
ln -sf "$SRC" "$dest"
say "Linked plugin: $dest -> $SRC"

# ---- 4. seed accounts.conf (never overwrite an existing one) ---------------
cfg_dir="$HOME/.config/claude-meter"
mkdir -p "$cfg_dir"
accounts_conf="$cfg_dir/accounts.conf"
if [ -f "$accounts_conf" ]; then
    say "accounts.conf already exists, leaving it alone: $accounts_conf"
else
    {
        echo "# claude-meter accounts config. Env vars override this file."
        echo "# Always quote values: paths routinely contain spaces."
        echo
        echo "# Space-separated instance names, one \"<name>.conf\" per account"
        echo "CLAUDE_METER_ACCOUNTS=\"claudemeter\""
        echo
        echo "# Menu bar icon: an SF Symbol name, or \"emoji:<char>\" as an escape hatch"
        echo "#CLAUDE_METER_ICON=\"gauge.with.needle\""
    } > "$accounts_conf"
    say "Wrote accounts config template: $accounts_conf"
fi

# ---- 5. seed a per-account config file for each configured account ---------
# shellcheck disable=SC1090
. "$accounts_conf"
for acct in ${CLAUDE_METER_ACCOUNTS:-$instance}; do
    conf="$cfg_dir/$acct.conf"
    if [ -f "$conf" ]; then
        say "Config already exists, leaving it alone: $conf"
        continue
    fi
    {
        echo "# claude-meter config for instance \"$acct\". Env vars override this file."
        echo "# Always quote values: paths routinely contain spaces."
        echo
        echo "# Label shown in the dropdown for this account (default: Claude)"
        echo "#CLAUDE_METER_LABEL=\"Claude\""
        echo
        echo "# SSH host to fall back to when local live/cache both fail"
        echo "#CLAUDE_METER_REMOTE=\"your-linux-host\""
        echo
        echo "# Override the remote plasmoid script path (default shown)"
        echo "#CLAUDE_METER_REMOTE_SCRIPT=\"~/Documents/claude-meter/plasmoid/org.mat.claudemeter/contents/scripts/claude-meter.sh\""
        echo
        echo "# Env vars passed to the remote script's own source ladder"
        echo "#CLAUDE_METER_REMOTE_COOKIES=\"/home/youruser/.config/google-chrome/Default/Cookies\""
        echo "#CLAUDE_METER_REMOTE_USAGE_DIR=\"/home/youruser/.claude/usage\""
        echo
        echo "# Local Chromium-family cookie DB to read (see --list-profiles for choices)"
        echo "#CLAUDE_CHROME_COOKIES=\"/Users/youruser/Library/Application Support/Google/Chrome/Default/Cookies\""
        echo
        echo "# Local statusline cache snapshot directory (default ~/.claude/usage)"
        echo "#CLAUDE_USAGE_DIR=\"/Users/youruser/.claude/usage\""
        echo
        echo "# claude.ai organization UUID (else auto-detected and cached)"
        echo "#CLAUDE_ORG_ID=\"\""
    } > "$conf"
    say "Wrote config template: $conf"
done

say "Done. Refresh SwiftBar (or restart it) to see the meter."
