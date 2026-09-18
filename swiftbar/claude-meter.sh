#!/usr/bin/env bash
# claude-meter (SwiftBar) — macOS port of the KDE Plasma claude-meter widget.
#
# Source ladder (per account): live (local keychain + claude.ai usage API) -> remote (SSH to a
#   configured host running the plasmoid script) -> cache (local statusline snapshot)
#   -> stale (this script's own last-good reading). First success wins.
#
# Output contract (per account): {"ok":true,"source":"live"|"remote"|"cache"|"stale","age":N,
#   "five":{"pct":P,"reset_in":S},"seven":{...},"model":{"name":...,"pct":P,"reset_in":S}|null}
#   or {"ok":false,"reason":"..."}
#
# Menu bar: one icon, colored by the worst reading across every configured account.
# Dropdown: one section per account, rendered as graphical capsule bars (PNG).
#
# Flags: --json (print single-instance reading only), --selftest (offline render check),
#   --list-profiles (enumerate local Chromium-family cookie DBs),
#   --set-icon <value> (persist CLAUDE_METER_ICON in accounts.conf), no flag = SwiftBar render.

set -f
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

cfg_dir="${XDG_CONFIG_HOME:-$HOME/.config}/claude-meter"
accounts_conf="$cfg_dir/accounts.conf"
now=$(date +%s)

log() { [ -n "$CLAUDE_METER_DEBUG" ] && printf 'claude-meter: %s\n' "$*" >&2; }

# ---------- derive the fallback single instance name from this file's basename ----------
derive_self_instance() {
    local self inst
    self="$(basename "${BASH_SOURCE[0]}")"
    inst="${CLAUDE_METER_INSTANCE:-}"
    if [ -z "$inst" ]; then
        inst="${self%%.*}"
        inst="${inst%%-*}"
    fi
    printf '%s' "$inst"
}

# ---------- load config file without letting it clobber already-set env vars ----------
load_config() {
    [ -f "$conf_file" ] || return 0
    local keys="CLAUDE_METER_LABEL CLAUDE_METER_REMOTE CLAUDE_METER_REMOTE_SCRIPT CLAUDE_METER_REMOTE_COOKIES CLAUDE_METER_REMOTE_USAGE_DIR CLAUDE_CHROME_COOKIES CLAUDE_USAGE_DIR CLAUDE_ORG_ID"
    local k
    # snapshot pre-existing env values so the conf file can only fill gaps
    for k in $keys; do
        eval "if [ -n \"\${$k+x}\" ]; then had_$k=1; val_$k=\"\$$k\"; else had_$k=0; fi"
    done
    # shellcheck disable=SC1090
    . "$conf_file"
    for k in $keys; do
        eval "[ \"\$had_$k\" = 1 ] && export $k=\"\$val_$k\""
    done
}

# ---------- --list-profiles: [{"path":<Cookies db>,"label":"Chrome · Name (email)"}] ----------
list_profiles() {
    local roots=(
        "Chrome|$HOME/Library/Application Support/Google/Chrome"
        "Chromium|$HOME/Library/Application Support/Chromium"
        "Brave|$HOME/Library/Application Support/BraveSoftware/Brave-Browser"
        "Vivaldi|$HOME/Library/Application Support/Vivaldi"
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

# ---------- --set-icon <value>: persist CLAUDE_METER_ICON in accounts.conf, no rendering ----------
if [ "${1:-}" = "--set-icon" ]; then
    icon_value="${2:-}"
    mkdir -p "$cfg_dir" 2>/dev/null
    if [ -f "$accounts_conf" ]; then
        tmp_ac="$accounts_conf.tmp.$$"
        awk -v val="$icon_value" '
            BEGIN{done=0}
            /^CLAUDE_METER_ICON=/{print "CLAUDE_METER_ICON=\"" val "\""; done=1; next}
            {print}
            END{if(!done) print "CLAUDE_METER_ICON=\"" val "\""}
        ' "$accounts_conf" > "$tmp_ac" && mv -f "$tmp_ac" "$accounts_conf"
    else
        printf 'CLAUDE_METER_ICON="%s"\n' "$icon_value" > "$accounts_conf"
    fi
    exit 0
fi

# ---------- browser "Safe Storage" key: macOS Keychain ----------
# args: service  account
safe_storage_key() {
    local cache="claude-meter: $1" k
    security find-generic-password -w -s "$cache" -a "$2" 2>/dev/null && return 0
    # /usr/bin/security is not in the browser item's ACL, so this read prompts: bootstrap by hand only
    [ "${CLAUDE_METER_KEYCHAIN:-0}" = 1 ] || return 1
    k=$(security find-generic-password -w -s "$1" -a "$2" 2>/dev/null) && [ -n "$k" ] || return 1
    security add-generic-password -U -s "$cache" -a "$2" -w "$k" -T /usr/bin/security 2>/dev/null
    printf '%s' "$k"
}

# ---------- decrypt the claude.ai sessionKey cookie from a browser cookie DB ----------
# args: cookies_db  keychain_service  keychain_account   -> echoes cookie or returns 1
decrypt_cookie() {
    local db="$1" key hexkey tmpd hexall cookie
    tmpd=$(mktemp -d "${TMPDIR:-/tmp}/.cm.XXXXXX") || return 1
    trap 'rm -rf "$tmpd"' RETURN
    cp -f "$db" "$tmpd/c.db" 2>/dev/null || return 1
    # cookie row first: reading the keychain with nothing to decrypt pops a needless auth prompt
    hexall=$(sqlite3 "$tmpd/c.db" \
        "SELECT hex(encrypted_value) FROM cookies WHERE name='sessionKey' AND host_key LIKE '%claude.ai%' ORDER BY length(encrypted_value) DESC LIMIT 1;" 2>/dev/null)
    [ -n "$hexall" ] || return 1
    key=$(safe_storage_key "$2" "$3") || return 1
    [ -n "$key" ] || return 1
    hexkey=$(printf '%s' "$key" | python3 -c \
        "import hashlib,sys;print(hashlib.pbkdf2_hmac('sha1',sys.stdin.buffer.read(),b'saltysalt',1003,16).hex())" 2>/dev/null)
    [ -n "$hexkey" ] || return 1
    python3 -c "import sys,binascii;open(sys.argv[2],'wb').write(binascii.unhexlify(sys.argv[1][6:]))" \
        "$hexall" "$tmpd/ct" 2>/dev/null || return 1
    # macOS Chromium v10 cookie: AES-128-CBC, IV = 16 spaces, key = PBKDF2-HMAC-SHA1(safe_storage_key,
    # 'saltysalt', 1003). A 32-byte SHA256 domain-hash prefixes the plaintext.
    cookie=$(openssl enc -aes-128-cbc -d -K "$hexkey" -iv 20202020202020202020202020202020 -nopad -in "$tmpd/ct" 2>/dev/null \
        | python3 -c "import re,sys;d=sys.stdin.buffer.read();m=re.match(rb'[\x20-\x7e]+',d[32:]);sys.stdout.write(m.group().decode() if m else '')" 2>/dev/null)
    case "$cookie" in sk-ant-sid0*) printf '%s' "$cookie"; return 0 ;; esac
    return 1
}

# ---------- find a browser cookie DB and decrypt its sessionKey ----------
get_session_cookie() {
    local entries e c
    # path | keychain_service | keychain_account
    entries=(
        "${CLAUDE_CHROME_COOKIES:-}|Chrome Safe Storage|Chrome"
        "$HOME/Library/Application Support/Google/Chrome/Default/Cookies|Chrome Safe Storage|Chrome"
        "$HOME/Library/Application Support/Chromium/Default/Cookies|Chromium Safe Storage|Chromium"
        "$HOME/Library/Application Support/BraveSoftware/Brave-Browser/Default/Cookies|Brave Safe Storage|Brave"
        "$HOME/Library/Application Support/Vivaldi/Default/Cookies|Vivaldi Safe Storage|Vivaldi"
    )
    local IFS='|'
    for e in "${entries[@]}"; do
        set -- $e
        [ -n "$1" ] && [ -f "$1" ] || continue
        c=$(decrypt_cookie "$1" "$2" "$3") && { printf '%s' "$c"; return 0; }
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
        -H "anthropic-client-platform: web_claude_ai" -H "User-Agent: Mozilla/5.0" 2>/dev/null \
        | jq -r 'map(select(.capabilities | index("chat")))[0].uuid // empty' 2>/dev/null)
    [ -n "$o" ] || return 1
    mkdir -p "$cfg_dir" 2>/dev/null && printf '%s\n' "$o" > "$org_cache" 2>/dev/null
    printf '%s' "$o"
}

# ---------- primary: live claude.ai usage. echoes normalized JSON or returns 1 ----------
try_live() {
    command -v openssl >/dev/null 2>&1 && command -v sqlite3 >/dev/null 2>&1 \
        && command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 \
        && command -v python3 >/dev/null 2>&1 && command -v security >/dev/null 2>&1 \
        || { log "missing a dependency"; return 1; }

    local cookie org resp
    cookie=$(get_session_cookie) || { log "no session cookie"; return 1; }
    org=$(resolve_org "$cookie")  || { log "could not resolve org id"; return 1; }

    resp=$(printf 'cookie = "sessionKey=%s"\n' "$cookie" | timeout 8 curl -sS --fail --max-time 8 -K - \
        "https://claude.ai/api/organizations/${org}/usage" \
        -H "content-type: application/json" -H "anthropic-client-platform: web_claude_ai" -H "User-Agent: Mozilla/5.0" 2>/dev/null)
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

# ---------- remote: SSH to a configured host and run the plasmoid script there ----------
try_remote() {
    [ -n "$CLAUDE_METER_REMOTE" ] || return 1
    command -v ssh >/dev/null 2>&1 || return 1
    local script="${CLAUDE_METER_REMOTE_SCRIPT:-~/Documents/claude-meter/plasmoid/org.mat.claudemeter/contents/scripts/claude-meter.sh}"
    # remote values are single-quoted: cookie paths routinely contain spaces
    local envs=""
    [ -n "$CLAUDE_METER_REMOTE_COOKIES" ] && envs="CLAUDE_CHROME_COOKIES='$CLAUDE_METER_REMOTE_COOKIES'"
    [ -n "$CLAUDE_METER_REMOTE_USAGE_DIR" ] && envs="$envs CLAUDE_USAGE_DIR='$CLAUDE_METER_REMOTE_USAGE_DIR'"
    local resp
    resp=$(ssh -o BatchMode=yes -o ConnectTimeout=6 "$CLAUDE_METER_REMOTE" "$envs bash $script" 2>/dev/null)
    [ -n "$resp" ] || return 1
    printf '%s' "$resp" | jq -e -c --argjson now "$now" '
      if .ok != true then error("remote not ok") else . end
      | { ok: true, source: "remote", age: 0, five: .five, seven: .seven, model: .model }
    ' 2>/dev/null || return 1
}

# ---------- fallback: normalize the optional statusline snapshot (applies reset-time zeroing) ----------
emit_cache() {
    [ -s "$cache" ] || { printf '{"ok":false,"reason":"no-data"}\n'; return 1; }
    local out
    out=$(jq -c --argjson now "$now" '
      def win(w; dur):
        (w.resets_at) as $r | (w.pct // 0) as $p
        | (if $r == null then null else ($r - $now) end) as $ri
        | { pct:      (if ($r != null and $r <= $now) then 0 else $p end),
            reset_in: (if $ri == null then null elif $ri < 0 then 0 else $ri end) };
      { ok: true, source: "cache", age: ($now - (.ts // $now)),
        five: win(.five; 18000), seven: win(.seven; 604800), model: null }
    ' "$cache" 2>/dev/null)
    [ -n "$out" ] || { printf '{"ok":false,"reason":"parse-error"}\n'; return 1; }
    printf '%s\n' "$out"
}

# ---------- stale: this script's own last-good reading ----------
emit_stale() {
    [ -s "$last_file" ] || { printf '{"ok":false,"reason":"no-data"}\n'; return 1; }
    local out
    out=$(jq -c --argjson now "$now" '
      { ok: true, source: "stale", age: ($now - (.ts // $now)),
        five: .five, seven: .seven, model: .model }
    ' "$last_file" 2>/dev/null)
    [ -n "$out" ] || { printf '{"ok":false,"reason":"parse-error"}\n'; return 1; }
    printf '%s\n' "$out"
}

save_last() {
    mkdir -p "$cfg_dir" 2>/dev/null || return 0
    printf '%s' "$1" | jq -c --argjson now "$now" '. + {ts: $now}' > "$last_file.tmp" 2>/dev/null \
        && mv -f "$last_file.tmp" "$last_file" 2>/dev/null
}

# ---------- humanize seconds as Nd NHh / NHh NMm / NMm ----------
humanize() {
    local s="$1" d h m
    [ -z "$s" ] && { printf 'n/a'; return; }
    [ "$s" -lt 0 ] 2>/dev/null && s=0
    d=$((s / 86400)); h=$(((s % 86400) / 3600)); m=$(((s % 3600) / 60))
    if [ "$d" -gt 0 ]; then printf '%dd %dh' "$d" "$h"
    elif [ "$h" -gt 0 ]; then printf '%dh %dm' "$h" "$m"
    else printf '%dm' "$m"; fi
}

# ---------- bar: 8-cell block glyph bar for a pct — PNG-generation fallback only ----------
bar() {
    local pct="${1:-0}" cells filled i out=""
    cells=8
    filled=$(awk -v p="$pct" -v c="$cells" 'BEGIN{n=int(p/100*c+0.5); if(n<0)n=0; if(n>c)n=c; print n}')
    for i in $(seq 1 "$cells"); do
        if [ "$i" -le "$filled" ]; then out="${out}█"; else out="${out}░"; fi
    done
    printf '%s' "$out"
}

color_for() {
    local pct="${1:-0}"
    awk -v p="$pct" 'BEGIN{
        if (p < 50) print "#3fb950";
        else if (p < 75) print "#d29922";
        else if (p < 90) print "#db6d28";
        else print "#f85149";
    }'
}

# ---------- HSL (h in degrees, s/l 0..1) -> lowercase #rrggbb ----------
hsl_to_hex() {
    local h="$1" s="$2" l="$3"
    awk -v h="$h" -v s="$s" -v l="$l" 'BEGIN{
        h = h - 360.0 * int(h / 360.0); if (h < 0) h += 360.0
        c = (1 - (l * 2 - 1 < 0 ? -(l * 2 - 1) : (l * 2 - 1))) * s
        hp = h / 60.0
        x = c * (1 - (hp - 2 * int(hp / 2) - 1 < 0 ? -(hp - 2 * int(hp / 2) - 1) : (hp - 2 * int(hp / 2) - 1)))
        if (hp < 1)      { r1=c; g1=x; b1=0 }
        else if (hp < 2) { r1=x; g1=c; b1=0 }
        else if (hp < 3) { r1=0; g1=c; b1=x }
        else if (hp < 4) { r1=0; g1=x; b1=c }
        else if (hp < 5) { r1=x; g1=0; b1=c }
        else             { r1=c; g1=0; b1=x }
        m = l - c / 2.0
        r = (r1 + m) * 255; g = (g1 + m) * 255; b = (b1 + m) * 255
        if (r < 0) r = 0; if (r > 255) r = 255
        if (g < 0) g = 0; if (g > 255) g = 255
        if (b < 0) b = 0; if (b > 255) b = 255
        printf "#%02x%02x%02x", int(r+0.5), int(g+0.5), int(b+0.5)
    }'
}

# ---------- QML barColor() ported: continuous green->red on absolute usage, no pace reference ----------
bar_color_abs() {
    local pct="${1:-0}"
    awk -v p="$pct" 'BEGIN{
        t = p; if (t < 0) t = 0; if (t > 100) t = 100; t = t / 100.0
        print (1 - t) * 140.0
        print 0.66 + t * 0.16
    }' | { read -r hue; read -r sat; hsl_to_hex "$hue" "$sat" 0.55; }
}

# ---------- QML paceColor() ported: colour by margin = usage% - time%, falls back to bar_color_abs ----------
pace_color() {
    local pct="${1:-0}" time_pct="$2"
    case "$time_pct" in
        ''|*[!0-9.-]*) bar_color_abs "$pct"; return ;;
    esac
    local hue
    hue=$(awk -v p="$pct" -v tp="$time_pct" 'BEGIN{
        m = p - tp
        if (m <= -8)      hue = 140
        else if (m < 0)   hue = 55 + (-m / 8) * 85
        else if (m < 8)   hue = 55 * (1 - m / 8)
        else              hue = 0
        print hue
    }')
    hsl_to_hex "$hue" 0.72 0.55
}

# ---------- set up the globals one account's ladder run needs, then load its config ----------
setup_instance() {
    instance="$1"
    conf_file="$cfg_dir/$instance.conf"
    last_file="$cfg_dir/$instance.last.json"
    load_config
    label="${CLAUDE_METER_LABEL:-Claude}"
    usage_dir="${CLAUDE_USAGE_DIR:-$HOME/.claude/usage}"
    cache="$usage_dir/.ratelimit.json"
    org_cache="$cfg_dir/org_id.$instance"
}

# ---------- run the source ladder for the currently set-up instance ----------
run_ladder() {
    local out
    if out=$(try_live) && [ -n "$out" ]; then
        save_last "$out"
        printf '%s' "$out"
        return 0
    fi
    if out=$(try_remote) && [ -n "$out" ]; then
        save_last "$out"
        printf '%s' "$out"
        return 0
    fi
    if out=$(emit_cache) && [ -n "$out" ]; then
        local ok; ok=$(printf '%s' "$out" | jq -r '.ok' 2>/dev/null)
        if [ "$ok" = "true" ]; then
            save_last "$out"
            printf '%s' "$out"
            return 0
        fi
    fi
    if out=$(emit_stale) && [ -n "$out" ]; then
        local ok; ok=$(printf '%s' "$out" | jq -r '.ok' 2>/dev/null)
        if [ "$ok" = "true" ]; then
            printf '%s' "$out"
            return 0
        fi
    fi
    printf '{"ok":false,"reason":"no-source"}\n'
    return 1
}

# ---------- elapsed-time position in the window as a pct, empty when there's no tick to draw ----------
# args: reset_in  dur(seconds)
compute_time_pct() {
    local reset_in="$1" dur="$2"
    [ -n "$reset_in" ] || { printf ''; return; }
    awk -v r="$reset_in" -v d="$dur" 'BEGIN {
        if (d <= 0 || r <= 0) { exit }
        rc = r; if (rc > d) rc = d
        t = (d - rc) / d * 100
        if (t < 0) t = 0
        if (t > 100) t = 100
        if (t <= 0 || t >= 100) { exit }
        printf "%.4f", t
    }'
}

# ---------- render a 260x24 (2x retina) capsule PNG as base64, empty on any failure ----------
# args: pct  fill_color_hex  time_pct(optional, empty/none for no tick)
capsule_png() {
    python3 - "$1" "$2" "$3" <<'PY' 2>/dev/null
import sys, struct, zlib, base64

def clampf(v, a, b):
    return a if v < a else (b if v > b else v)

def hex_to_rgb(h):
    h = h.lstrip('#')
    return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16))

def lighten(rgb, f):
    r, g, b = rgb
    return (int(clampf(r + (255 - r) * f, 0, 255)),
            int(clampf(g + (255 - g) * f, 0, 255)),
            int(clampf(b + (255 - b) * f, 0, 255)))

def darken(rgb, f):
    r, g, b = rgb
    return (int(clampf(r * (1 - f), 0, 255)),
            int(clampf(g * (1 - f), 0, 255)),
            int(clampf(b * (1 - f), 0, 255)))

def lerp3(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

def sdf_rounded_box(px, py, w, h, r):
    cx = px - w / 2.0
    cy = py - h / 2.0
    bx = w / 2.0 - r
    by = h / 2.0 - r
    qx = abs(cx) - bx
    qy = abs(cy) - by
    ax = qx if qx > 0.0 else 0.0
    ay = qy if qy > 0.0 else 0.0
    outside = (ax * ax + ay * ay) ** 0.5
    inside = min(max(qx, qy), 0.0)
    return outside + inside - r

W, H = 260, 24
R = H / 2.0

pct = clampf(float(sys.argv[1]), 0.0, 100.0)
fill_rgb = hex_to_rgb(sys.argv[2])
track_rgb = (0x30, 0x36, 0x3d)
fill_w = W * pct / 100.0

tick_center = None
if len(sys.argv) > 3 and sys.argv[3] not in ('', 'none', 'None'):
    t = clampf(float(sys.argv[3]), 0.0, 100.0)
    if 0 < t < 100:
        tc = W * t / 100.0
        if tc <= W - 1:
            tick_center = tc

rows = []
for y in range(H):
    row = bytearray()
    py = y + 0.5
    t = y / float(H - 1)
    top_c = lighten(fill_rgb, 0.18)
    bot_c = darken(fill_rgb, 0.12)
    grad = lerp3(top_c, bot_c, t)
    if y in (2, 3):
        hl = lighten(grad, 0.35)
        grad = lerp3(grad, hl, 0.5)
    for x in range(W):
        px = x + 0.5
        a_track = clampf(0.5 - sdf_rounded_box(px, py, W, H, R), 0.0, 1.0)
        if a_track <= 0.0:
            row += bytes((0, 0, 0, 0))
            continue
        fa = 0.0 if fill_w <= 0.0 else clampf(0.5 - sdf_rounded_box(px, py, fill_w, H, R), 0.0, 1.0)
        color = lerp3(track_rgb, grad, fa)
        if tick_center is not None:
            coverage = clampf(min(x + 1.0, tick_center + 1.0) - max(x, tick_center - 1.0), 0.0, 1.0)
            tick_alpha = 0.85 * coverage * a_track
            color = lerp3(color, (255, 255, 255), tick_alpha)
        row += bytes((color[0], color[1], color[2], int(a_track * 255)))
    rows.append(bytes([0]) + bytes(row))

raw = b"".join(rows)

def chunk(tag, data):
    c = tag + data
    return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xffffffff)

sig = b"\x89PNG\r\n\x1a\n"
ihdr = struct.pack(">IIBBBBB", W, H, 8, 6, 0, 0, 0)
idat = zlib.compress(raw, 9)
png = sig + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b"")
sys.stdout.write(base64.b64encode(png).decode("ascii"))
PY
}

# ---------- one dropdown row: percent bar as a PNG, or block glyphs if PNG generation failed ----------
render_row() {
    local rlabel="$1" pct="$2" reset_in="$3" dur="$4" color img text shown time_pct
    # percentages are rounded and width-padded so the Menlo columns actually line up
    shown=$(awk -v p="$pct" 'BEGIN{printf "%d", (p<0?0:p)+0.5}')
    text=$(printf '%-7s%4s%% · %s' "$rlabel" "$shown" "$(humanize "$reset_in")")
    time_pct=$(compute_time_pct "$reset_in" "$dur")
    color=$(pace_color "$pct" "$time_pct")
    img=$(capsule_png "$pct" "$color" "$time_pct")
    if [ -n "$img" ]; then
        printf '%s | image=%s width=130 height=12 font=Menlo size=12\n' "$text" "$img"
    else
        printf '%s %s | font=Menlo size=12\n' "$text" "$(bar "$pct")"
    fi
}

# ---------- one menu bar icon line: sfimage= for an SF Symbol, literal text for "emoji:X" ----------
menu_line() {
    local icon="$1" color="$2"
    case "$icon" in
        emoji:*) printf '%s | color=%s\n' "${icon#emoji:}" "$color" ;;
        *)       printf ' | sfimage=%s color=%s\n' "$icon" "$color" ;;
    esac
}

# ---------- one account's dropdown section: header + 5-hour/7-day/model rows + separator ----------
account_block() {
    local blabel="$1" json="$2" ok
    ok=$(printf '%s' "$json" | jq -r '.ok // false' 2>/dev/null)
    if [ "$ok" != "true" ]; then
        printf '%s  unavailable | color=#f85149\n' "$blabel"
        printf -- '---\n'
        return
    fi

    local source age warn=""
    source=$(printf '%s' "$json" | jq -r '.source')
    age=$(printf '%s' "$json" | jq -r '.age // 0')
    case "$source" in cache|stale) warn=" ⚠︎ (age $(humanize "$age"))" ;; esac
    printf '%s%s | size=14 color=#8b949e\n' "$blabel" "$warn"

    local five_pct seven_pct five_reset seven_reset
    five_pct=$(printf '%s' "$json" | jq -r '.five.pct // 0')
    seven_pct=$(printf '%s' "$json" | jq -r '.seven.pct // 0')
    five_reset=$(printf '%s' "$json" | jq -r '.five.reset_in // empty')
    seven_reset=$(printf '%s' "$json" | jq -r '.seven.reset_in // empty')
    render_row "5-hour" "$five_pct" "$five_reset" 18000
    render_row "7-day" "$seven_pct" "$seven_reset" 604800

    local model_name model_pct model_reset
    model_name=$(printf '%s' "$json" | jq -r '.model.name // empty')
    if [ -n "$model_name" ]; then
        model_pct=$(printf '%s' "$json" | jq -r '.model.pct // 0')
        model_reset=$(printf '%s' "$json" | jq -r '.model.reset_in // empty')
        render_row "$model_name" "$model_pct" "$model_reset" 604800
    fi
    printf -- '---\n'
}

# ---------- --selftest: offline render check, no network/keychain calls ----------
selftest() {
    local live_json cache_json fail_json out

    live_json='{"ok":true,"source":"live","age":0,"five":{"pct":42,"reset_in":3600},"seven":{"pct":17,"reset_in":259200},"model":{"name":"Fable","pct":5,"reset_in":86400}}'
    cache_json='{"ok":true,"source":"cache","age":300,"five":{"pct":80,"reset_in":1200},"seven":{"pct":60,"reset_in":100000},"model":null}'
    fail_json='{"ok":false,"reason":"no-data"}'

    printf '%s' "$live_json" | jq -e . >/dev/null 2>&1 || { echo "FAIL: live json invalid"; exit 1; }
    printf '%s' "$cache_json" | jq -e . >/dev/null 2>&1 || { echo "FAIL: cache json invalid"; exit 1; }
    printf '%s' "$fail_json" | jq -e . >/dev/null 2>&1 || { echo "FAIL: fail json invalid"; exit 1; }

    # menu bar line: sfimage=, no percent text
    out=$(menu_line "gauge.with.needle" "#3fb950")
    printf '%s' "$out" | grep -q 'sfimage=' || { echo "FAIL: menu line missing sfimage="; exit 1; }
    printf '%s' "$out" | grep -q '%' && { echo "FAIL: menu line contains a percent sign"; exit 1; }

    # menu bar line: emoji escape hatch, no sfimage=
    out=$(menu_line "emoji:🤖" "#3fb950")
    printf '%s' "$out" | grep -q '🤖' || { echo "FAIL: emoji menu line missing emoji"; exit 1; }
    printf '%s' "$out" | grep -q 'sfimage=' && { echo "FAIL: emoji menu line should not carry sfimage="; exit 1; }

    # dropdown: one labelled section per account, two-account synthetic fixture
    out="$(account_block "Acct1" "$live_json")
$(account_block "Acct2" "$cache_json")"
    printf '%s\n' "$out" | grep -q '^Acct1' || { echo "FAIL: dropdown missing Acct1 section"; exit 1; }
    printf '%s\n' "$out" | grep -q '^Acct2' || { echo "FAIL: dropdown missing Acct2 section"; exit 1; }
    [ "$(printf '%s\n' "$out" | grep -cx -- '---')" -eq 2 ] || { echo "FAIL: dropdown expected 2 section separators"; exit 1; }
    printf '%s\n' "$out" | grep -q 'Acct2 ⚠︎' || { echo "FAIL: cache-source account missing ⚠︎ warning"; exit 1; }

    # fail-json account renders a one-line unavailable row
    out=$(account_block "Acct3" "$fail_json")
    printf '%s' "$out" | grep -q 'unavailable' || { echo "FAIL: failed account missing unavailable text"; exit 1; }

    # generated PNG decodes as a valid 260x24 PNG
    out=$(capsule_png "42" "#3fb950" "")
    [ -n "$out" ] || { echo "FAIL: capsule_png produced no output"; exit 1; }
    decode_check() {
        printf '%s' "$1" | python3 -c "
import sys, base64, struct
data = base64.b64decode(sys.stdin.read())
if data[:8] != b'\x89PNG\r\n\x1a\n':
    sys.exit(1)
w, h = struct.unpack('>II', data[16:24])
sys.exit(0 if (w == 260 and h == 24) else 1)
"
    }
    decode_check "$out" || { echo "FAIL: capsule PNG is not a valid 260x24 PNG"; exit 1; }

    # pace tick: a tick left of the fill and one on top of the fill must both change the pixels
    out_notick=$(capsule_png "20" "#3fb950" "")
    out_tick_left=$(capsule_png "80" "#3fb950" "20")
    [ "$out_tick_left" != "$(capsule_png "80" "#3fb950" "")" ] || { echo "FAIL: tick left of fill did not change the PNG"; exit 1; }
    out_tick_on_fill=$(capsule_png "20" "#3fb950" "80")
    [ "$out_tick_on_fill" != "$out_notick" ] || { echo "FAIL: tick on top of fill did not change the PNG"; exit 1; }
    time_pct_empty=$(compute_time_pct "" "604800")
    [ -z "$time_pct_empty" ] || { echo "FAIL: compute_time_pct should be empty when reset_in is empty"; exit 1; }
    out_time_pct_empty=$(capsule_png "20" "#3fb950" "$time_pct_empty")
    [ "$out_time_pct_empty" = "$out_notick" ] || { echo "FAIL: compute_time_pct empty result should render identically to no-tick"; exit 1; }
    decode_check "$out_tick_left" || { echo "FAIL: tick-left PNG is not a valid 260x24 PNG"; exit 1; }
    decode_check "$out_tick_on_fill" || { echo "FAIL: tick-on-fill PNG is not a valid 260x24 PNG"; exit 1; }
    decode_check "$out_time_pct_empty" || { echo "FAIL: empty-time-pct PNG is not a valid 260x24 PNG"; exit 1; }

    # glyph fallback: with python3 unreachable, render_row must still produce a non-empty row
    local fakebin
    fakebin=$(mktemp -d "${TMPDIR:-/tmp}/.cm-fake.XXXXXX")
    printf '#!/bin/sh\nexit 1\n' > "$fakebin/python3"
    chmod +x "$fakebin/python3"
    out=$( (PATH="$fakebin:$PATH"; render_row "5-hour" "42" "3600") )
    rm -rf "$fakebin"
    [ -n "$out" ] || { echo "FAIL: glyph fallback row is empty"; exit 1; }
    printf '%s' "$out" | grep -qE '█|░' || { echo "FAIL: glyph fallback row missing bar glyphs"; exit 1; }

    # hsl_to_hex spot checks
    [ "$(hsl_to_hex 140 0.72 0.55)" = "#3adf71" ] || { echo "FAIL: hsl_to_hex 140 0.72 0.55"; exit 1; }
    [ "$(hsl_to_hex 0 0.72 0.55)" = "#df3a3a" ] || { echo "FAIL: hsl_to_hex 0 0.72 0.55"; exit 1; }
    [ "$(hsl_to_hex 55 0.72 0.55)" = "#dfd13a" ] || { echo "FAIL: hsl_to_hex 55 0.72 0.55"; exit 1; }

    # pace_color margin bands
    [ "$(pace_color 10 50)" = "$(hsl_to_hex 140 0.72 0.55)" ] || { echo "FAIL: pace_color 10 50"; exit 1; }
    [ "$(pace_color 58 50)" = "$(hsl_to_hex 0 0.72 0.55)" ] || { echo "FAIL: pace_color 58 50"; exit 1; }
    [ "$(pace_color 30 "")" = "$(bar_color_abs 30)" ] || { echo "FAIL: pace_color fallback to bar_color_abs"; exit 1; }

    echo "SELFTEST OK"
    exit 0
}

[ "${1:-}" = "--selftest" ] && selftest

# ---------- --json: single-instance reading (accounts.conf is not consulted) ----------
if [ "${1:-}" = "--json" ]; then
    setup_instance "$(derive_self_instance)"
    reading=$(run_ladder)
    printf '%s\n' "$reading"
    ok=$(printf '%s' "$reading" | jq -r '.ok' 2>/dev/null)
    [ "$ok" = "true" ] && exit 0 || exit 1
fi

# ---------- default: multi-account SwiftBar render ----------
# load CLAUDE_METER_ACCOUNTS / CLAUDE_METER_ICON from accounts.conf, env still wins
had_accounts=0; had_icon=0
[ -n "${CLAUDE_METER_ACCOUNTS+x}" ] && { had_accounts=1; val_accounts="$CLAUDE_METER_ACCOUNTS"; }
[ -n "${CLAUDE_METER_ICON+x}" ] && { had_icon=1; val_icon="$CLAUDE_METER_ICON"; }
if [ -f "$accounts_conf" ]; then
    # shellcheck disable=SC1090
    . "$accounts_conf"
fi
[ "$had_accounts" = 1 ] && CLAUDE_METER_ACCOUNTS="$val_accounts"
[ "$had_icon" = 1 ] && CLAUDE_METER_ICON="$val_icon"

if [ -n "${CLAUDE_METER_ACCOUNTS:-}" ]; then
    account_list="$CLAUDE_METER_ACCOUNTS"
else
    account_list="$(derive_self_instance)"
fi
icon="${CLAUDE_METER_ICON:-gauge.with.needle}"

# run every account's ladder in parallel — two SSH round-trips must not serialize
tmpd=$(mktemp -d "${TMPDIR:-/tmp}/.cm-multi.XXXXXX" 2>/dev/null)
acc_names=()
count=0
for acct in $account_list; do
    count=$((count + 1))
    acc_names[$count]="$acct"
    if [ -n "$tmpd" ]; then
        ( setup_instance "$acct"
          printf '%s' "$label" > "$tmpd/$count.label"
          run_ladder > "$tmpd/$count.json"
        ) &
    fi
done
wait

acc_labels=()
acc_jsons=()
idx=1
while [ "$idx" -le "$count" ]; do
    if [ -n "$tmpd" ] && [ -f "$tmpd/$idx.label" ]; then
        acc_labels[$idx]=$(cat "$tmpd/$idx.label")
    else
        acc_labels[$idx]="${acc_names[$idx]}"
    fi
    if [ -n "$tmpd" ] && [ -f "$tmpd/$idx.json" ]; then
        acc_jsons[$idx]=$(cat "$tmpd/$idx.json")
    else
        acc_jsons[$idx]='{"ok":false,"reason":"no-data"}'
    fi
    idx=$((idx + 1))
done
[ -n "$tmpd" ] && rm -rf "$tmpd"

# aggregate: worst pct across every account (icon color), distinct sources used (footer)
worst=-1
sources=""
any_ok=0
idx=1
while [ "$idx" -le "$count" ]; do
    j="${acc_jsons[$idx]}"
    ok=$(printf '%s' "$j" | jq -r '.ok // false' 2>/dev/null)
    if [ "$ok" = "true" ]; then
        any_ok=1
        m=$(printf '%s' "$j" | jq -r '[.five.pct, .seven.pct, (.model.pct // 0)] | max' 2>/dev/null)
        worst=$(awk -v w="$worst" -v m="${m:-0}" 'BEGIN{print (m>w)?m:w}')
        src=$(printf '%s' "$j" | jq -r '.source // empty' 2>/dev/null)
        case " $sources " in *" $src "*) ;; *) sources="$sources $src" ;; esac
    fi
    idx=$((idx + 1))
done
sources="${sources# }"

if [ "$any_ok" = 1 ]; then
    menu_line "$icon" "$(color_for "$worst")"
else
    menu_line "exclamationmark.triangle" "#f85149"
fi
printf -- '---\n'

idx=1
while [ "$idx" -le "$count" ]; do
    account_block "${acc_labels[$idx]}" "${acc_jsons[$idx]}"
    idx=$((idx + 1))
done

src_display="$(printf '%s' "$sources" | tr ' ' ',' | sed 's/,/, /g')"
[ -z "$src_display" ] && src_display="unavailable"
plugin_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

printf 'Source: %s · Fable-aware | size=11 color=#8b949e\n' "$src_display"
printf 'Refresh | refresh=true\n'
printf 'Open claude.ai | href=https://claude.ai/settings/usage\n'
printf 'Icon | size=11\n'
printf -- '--Gauge | bash="%s" param1=--set-icon param2=gauge.with.needle terminal=false refresh=true\n' "$plugin_path"
printf -- '--Robot | bash="%s" param1=--set-icon param2=emoji:🤖 terminal=false refresh=true\n' "$plugin_path"
printf -- '--Sparkle | bash="%s" param1=--set-icon param2=sparkles terminal=false refresh=true\n' "$plugin_path"
printf -- '--Brain | bash="%s" param1=--set-icon param2=brain terminal=false refresh=true\n' "$plugin_path"
