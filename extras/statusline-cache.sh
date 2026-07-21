#!/usr/bin/env bash
# OPTIONAL offline fallback for Claude Meter.
#
# The widget's primary data source is the live claude.ai endpoint, which needs no setup. This snippet
# is only useful if you ALSO run Claude Code with a custom statusline: Claude Code passes a JSON blob to
# the statusline command on stdin, and that blob contains your rate-limit windows. Caching it here gives
# the widget a last-known snapshot to fall back on when the live fetch can't run (browser logged out,
# KWallet locked, offline). When the widget shows that snapshot it dims and displays its age.
#
# How to use — feed this script the same JSON Claude Code gives your statusline. If your statusline is a
# shell script that reads stdin into "$input", add one line near the top:
#
#     printf '%s' "$input" | /path/to/claude-meter/extras/statusline-cache.sh
#
# It writes nothing unless rate_limits are present (i.e. a Claude subscription session).

set -f
usage_dir="${CLAUDE_USAGE_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/usage}"
input=$(cat)
[ -z "$input" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

now=$(date +%s)
read -r f5 r5 s7 r7 < <(printf '%s' "$input" | jq -r '
  [ (.rate_limits.five_hour.used_percentage // "null"),
    (.rate_limits.five_hour.resets_at        // "null"),
    (.rate_limits.seven_day.used_percentage  // "null"),
    (.rate_limits.seven_day.resets_at        // "null") ] | @tsv' 2>/dev/null)

# Nothing to cache unless at least one window is present.
[ "${f5:-null}" = "null" ] && [ "${s7:-null}" = "null" ] && exit 0

mkdir -p "$usage_dir"
printf '{"ts":%s,"five":{"pct":%s,"resets_at":%s},"seven":{"pct":%s,"resets_at":%s}}\n' \
    "$now" "${f5:-null}" "${r5:-null}" "${s7:-null}" "${r7:-null}" \
    > "$usage_dir/.ratelimit.json.tmp" 2>/dev/null \
    && mv -f "$usage_dir/.ratelimit.json.tmp" "$usage_dir/.ratelimit.json" 2>/dev/null
