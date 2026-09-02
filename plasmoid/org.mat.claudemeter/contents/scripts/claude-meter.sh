#!/usr/bin/env bash
# claude-meter — emit current Claude subscription usage as one JSON line for the Claude Meter plasmoid.
#
# PRIMARY source: the claude.ai usage endpoint. Always fresh, account-wide (counts phone / web / other
#   machines) and costs ZERO tokens (it is a read endpoint). Auth is your claude.ai *web session cookie*,
#   which is decrypted on the fly from your browser's cookie store using the browser "Safe Storage" key
#   held in KWallet (or the Secret Service / gnome-keyring). The cookie is used in memory only — it is
#   never written to disk, never logged, and only ever sent to claude.ai over HTTPS.
# FALLBACK: an optional snapshot a Claude Code statusline can cache at ~/.claude/usage/.ratelimit.json
#   (see extras/statusline-cache.sh in the repo). Used when the live fetch can't run (browser logged
#   out, wallet locked, offline). When falling back, `age` reflects how old that snapshot is.
#
# Output: {"ok":true,"source":"live"|"cache","age":N,"five":{"pct":P,"reset_in":S},"seven":{...},
#          "model":{"name":"Fable","pct":P,"reset_in":S}|null}   or {"ok":false,"reason":"..."}
#   "model" = the per-model weekly window (limits[].kind == "weekly_scoped", currently Fable); null in fallback.
#
# Optional environment overrides (none are required — everything auto-detects):
#   CLAUDE_ORG_ID          your claude.ai organization UUID (else auto-detected by "chat" capability)
#   CLAUDE_CHROME_COOKIES  path to a Chromium "Cookies" SQLite DB (else common Chrome/Chromium/Brave paths)
#   CLAUDE_USAGE_DIR       dir holding the statusline fallback snapshot (default ~/.claude/usage)
#   CLAUDE_METER_DEBUG=1   print diagnostics to stderr

set -f
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH:/home/linuxbrew/.linuxbrew/bin"

cfg_dir="${XDG_CONFIG_HOME:-$HOME/.config}/claude-meter"
usage_dir="${CLAUDE_USAGE_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/usage}"
cache="$usage_dir/.ratelimit.json"
org_cache="$cfg_dir/org_id"
# One widget per account: an explicit cookie DB gets its own org cache so two instances never share one.
if [ -n "$CLAUDE_CHROME_COOKIES" ]; then
    org_cache="$cfg_dir/org_id.$(printf '%s' "$CLAUDE_CHROME_COOKIES" | sha256sum | cut -c1-12)"
fi
now=$(date +%s)
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36"

log() { [ -n "$CLAUDE_METER_DEBUG" ] && printf 'claude-meter: %s\n' "$*" >&2; }

# ---------- --list-profiles: [{"path":<Cookies db>,"label":"Chrome · Name (email)"}] for the config page ----------
list_profiles() {
    local roots=(
        "Chrome|$HOME/.config/google-chrome"
        "Chromium|$HOME/.config/chromium"
        "Brave|$HOME/.config/BraveSoftware/Brave-Browser"
        "Vivaldi|$HOME/.config/vivaldi"
        "Chrome (flatpak)|$HOME/.var/app/com.google.Chrome/config/google-chrome"
        "Chromium (flatpak)|$HOME/.var/app/org.chromium.Chromium/config/chromium"
        "Brave (flatpak)|$HOME/.var/app/com.brave.Browser/config/BraveSoftware/Brave-Browser"
    )
    local r browser dir
    for r in "${roots[@]}"; do
        browser="${r%%|*}"; dir="${r#*|}"
        [ -f "$dir/Local State" ] || continue
        python3 - "$browser" "$dir" <<'PY'
import json, os, sys
browser, root = sys.argv[1], sys.argv[2]
try:
    info = json.load(open(os.path.join(root, "Local State"))).get("profile", {}).get("info_cache", {})
except Exception:
    info = {}
for d in sorted(os.listdir(root)):
    db = os.path.join(root, d, "Cookies")
    if not os.path.isfile(db): continue
    meta = info.get(d, {})
    name, mail = meta.get("name") or d, meta.get("user_name") or ""
    label = f"{browser} · {name}" + (f" ({mail})" if mail else "")
    print(json.dumps({"path": db, "label": label}))
PY
    done | jq -sc '.'
}
[ "${1:-}" = "--list-profiles" ] && { list_profiles; exit 0; }

# ---------- fallback: normalize the optional statusline snapshot (applies reset-time zeroing) ----------
emit_cache() {
    [ -s "$cache" ] || { printf '{"ok":false,"reason":"no-data"}\n'; return; }
    jq -c --argjson now "$now" '
      def win(w; dur):
        (w.resets_at) as $r | (w.pct // 0) as $p
        | (if $r == null then null else ($r - $now) end) as $ri
        | { pct:      (if ($r != null and $r <= $now) then 0 else $p end),
            reset_in: (if $ri == null then null elif $ri < 0 then 0 else $ri end) };
      { ok: true, source: "cache", age: ($now - (.ts // $now)),
        five: win(.five; 18000), seven: win(.seven; 604800), model: null }
    ' "$cache" 2>/dev/null || printf '{"ok":false,"reason":"parse-error"}\n'
}

# ---------- browser "Safe Storage" key: KWallet first, then Secret Service (gnome-keyring) ----------
# args: kwallet_folder  kwallet_label  secret_service_app
safe_storage_key() {
    local svc mod h k
    if command -v qdbus-qt6 >/dev/null 2>&1 || command -v qdbus6 >/dev/null 2>&1; then
        local q; q=$(command -v qdbus-qt6 || command -v qdbus6)
        svc=$("$q" 2>/dev/null | grep -om1 'org\.kde\.kwalletd[0-9]')
        if [ -n "$svc" ]; then
            mod="/modules/${svc##*.}"
            h=$(timeout 5 "$q" "$svc" "$mod" org.kde.KWallet.open kdewallet 0 claude-meter 2>/dev/null)
            if [ -n "$h" ] && [ "$h" != "-1" ]; then
                k=$(timeout 5 "$q" "$svc" "$mod" org.kde.KWallet.readPassword "$h" "$1" "$2" claude-meter 2>/dev/null)
                [ -n "$k" ] && { printf '%s' "$k"; return 0; }
            fi
        fi
    fi
    if command -v secret-tool >/dev/null 2>&1; then
        k=$(secret-tool lookup application "$3" 2>/dev/null)
        [ -n "$k" ] && { printf '%s' "$k"; return 0; }
    fi
    return 1
}

# ---------- decrypt the claude.ai sessionKey cookie from a browser cookie DB ----------
# args: cookies_db  kwallet_folder  kwallet_label  secret_service_app   -> echoes cookie or returns 1
decrypt_cookie() {
    local db="$1" key hexkey hexall tmpd cookie
    key=$(safe_storage_key "$2" "$3" "$4") || return 1
    hexkey=$(printf '%s' "$key" | python3 -c \
        "import hashlib,sys;print(hashlib.pbkdf2_hmac('sha1',sys.stdin.buffer.read(),b'saltysalt',1,16).hex())" 2>/dev/null)
    [ -n "$hexkey" ] || return 1
    tmpd=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/.cm.XXXXXX") || return 1
    trap 'rm -rf "$tmpd"' RETURN
    cp -f "$db" "$tmpd/c.db" 2>/dev/null || return 1
    hexall=$(sqlite3 "$tmpd/c.db" \
        "SELECT hex(encrypted_value) FROM cookies WHERE name='sessionKey' AND host_key LIKE '%claude.ai%' ORDER BY length(encrypted_value) DESC LIMIT 1;" 2>/dev/null)
    [ -n "$hexall" ] || return 1
    python3 -c "import sys,binascii;open(sys.argv[2],'wb').write(binascii.unhexlify(sys.argv[1][6:]))" \
        "$hexall" "$tmpd/ct" 2>/dev/null || return 1
    # Chromium v10/v11 cookie: AES-128-CBC, IV = 16 spaces, key = PBKDF2-HMAC-SHA1(safe_storage_key,
    # 'saltysalt', 1). Recent Chromium prepends a 32-byte SHA256 domain-hash to the plaintext.
    cookie=$(openssl enc -aes-128-cbc -d -K "$hexkey" -iv 20202020202020202020202020202020 -nopad -in "$tmpd/ct" 2>/dev/null \
        | python3 -c "import re,sys;d=sys.stdin.buffer.read();m=re.match(rb'[\x20-\x7e]+',d[32:]);sys.stdout.write(m.group().decode() if m else '')" 2>/dev/null)
    case "$cookie" in sk-ant-sid0*) printf '%s' "$cookie"; return 0 ;; esac
    return 1
}

# ---------- find a browser cookie DB and decrypt its sessionKey ----------
get_session_cookie() {
    local entries e c
    # path | kwallet_folder | kwallet_label | secret_service_app
    entries=(
        "${CLAUDE_CHROME_COOKIES:-}|Chrome Keys|Chrome Safe Storage|chrome"
        "$HOME/.config/google-chrome/Default/Cookies|Chrome Keys|Chrome Safe Storage|chrome"
        "$HOME/.config/chromium/Default/Cookies|Chromium Keys|Chromium Safe Storage|chromium"
        "$HOME/.config/BraveSoftware/Brave-Browser/Default/Cookies|Brave Keys|Brave Safe Storage|brave"
        "$HOME/.config/vivaldi/Default/Cookies|Vivaldi Keys|Vivaldi Safe Storage|vivaldi"
        "$HOME/.var/app/com.google.Chrome/config/google-chrome/Default/Cookies|Chrome Keys|Chrome Safe Storage|chrome"
        "$HOME/.var/app/org.chromium.Chromium/config/chromium/Default/Cookies|Chromium Keys|Chromium Safe Storage|chromium"
        "$HOME/.var/app/com.brave.Browser/config/BraveSoftware/Brave-Browser/Default/Cookies|Brave Keys|Brave Safe Storage|brave"
    )
    local IFS='|'
    for e in "${entries[@]}"; do
        set -- $e
        [ -n "$1" ] && [ -f "$1" ] || continue
        c=$(decrypt_cookie "$1" "$2" "$3" "$4") && { printf '%s' "$c"; return 0; }
    done
    return 1
}

# ---------- resolve the claude.ai organization UUID (env -> cache -> auto-detect + cache) ----------
resolve_org() { # arg: cookie
    local o
    [ -n "$CLAUDE_ORG_ID" ] && { printf '%s' "$CLAUDE_ORG_ID"; return 0; }
    if [ -s "$org_cache" ]; then read -r o < "$org_cache"; [ -n "$o" ] && { printf '%s' "$o"; return 0; }; fi
    o=$(printf 'cookie = "sessionKey=%s"\n' "$1" | timeout 8 curl -sS --fail --max-time 8 -K - \
        "https://claude.ai/api/organizations" \
        -H "anthropic-client-platform: web_claude_ai" -H "User-Agent: $UA" 2>/dev/null \
        | jq -r 'map(select(.capabilities | index("chat")))[0].uuid // empty' 2>/dev/null)
    [ -n "$o" ] || return 1
    mkdir -p "$cfg_dir" 2>/dev/null && printf '%s\n' "$o" > "$org_cache" 2>/dev/null
    printf '%s' "$o"
}

# ---------- primary: live claude.ai usage. echoes normalized JSON or returns 1 ----------
try_live() {
    command -v openssl >/dev/null 2>&1 && command -v sqlite3 >/dev/null 2>&1 \
        && command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 \
        || { log "missing a dependency (openssl/sqlite3/curl/jq/python3)"; return 1; }

    local cookie org resp
    cookie=$(get_session_cookie) || { log "no session cookie (browser logged out / wallet locked?)"; return 1; }
    org=$(resolve_org "$cookie")  || { log "could not resolve org id"; return 1; }

    resp=$(printf 'cookie = "sessionKey=%s"\n' "$cookie" | timeout 8 curl -sS --fail --max-time 8 -K - \
        "https://claude.ai/api/organizations/${org}/usage" \
        -H "content-type: application/json" -H "anthropic-client-platform: web_claude_ai" -H "User-Agent: $UA" 2>/dev/null)
    [ -n "$resp" ] || { log "usage endpoint returned nothing"; return 1; }

    printf '%s' "$resp" | jq -e -c --argjson now "$now" '
      def toepoch: (sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601);
      if (.five_hour.utilization == null) then error("no util") else . end
      | { ok: true, source: "live", age: 0,
          five:  { pct: (.five_hour.utilization),
                   reset_in: (if .five_hour.resets_at  == null then null else ((.five_hour.resets_at  | toepoch) - $now) end) },
          seven: { pct: (.seven_day.utilization),
                   reset_in: (if .seven_day.resets_at == null then null else ((.seven_day.resets_at | toepoch) - $now) end) },
          model: ((.limits // []) | map(select(.kind == "weekly_scoped" and .scope.model != null)) | first
                  | if . == null then null else
                    { name: (.scope.model.display_name // "model"), pct: (.percent // 0),
                      reset_in: (if .resets_at == null then null else ((.resets_at | toepoch) - $now) end) } end) }
    ' 2>/dev/null || { log "could not parse usage response"; return 1; }
}

if out=$(try_live) && [ -n "$out" ]; then
    printf '%s\n' "$out"
else
    emit_cache
fi
