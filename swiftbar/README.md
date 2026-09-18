# Claude Meter — SwiftBar plugin

A macOS port of the KDE Plasma Claude Meter widget: one compact icon in the
menu bar, with every configured Claude.ai account's 5-hour, 7-day, and (where
applicable) per-model usage shown as graphical capsule bars in the dropdown,
via [SwiftBar](https://swiftbar.app).

## Requirements

- [SwiftBar](https://swiftbar.app) (not bundled — install it separately)
- `jq`, `sqlite3`, `openssl`, `curl`, `python3`, `security` — all present on
  stock macOS, nothing extra to install
- For the **live** source, an OpenSSL-backed curl (`brew install curl`).
  Cloudflare challenges Apple's LibreSSL curl on its TLS fingerprint, so with
  only the stock binary the meter falls back to `--remote` or the statusline
  snapshot — and the snapshot carries no per-model window. Point
  `CLAUDE_METER_CURL` at another binary to override the search.

## Install

```
./install.sh
```

Copies `claude-meter.sh` into your SwiftBar plugin directory as
`claudemeter.1m.sh` (refreshes every minute), removes any stale
`personal.1m.sh` / `siku.1m.sh` plugins from the old single-account design,
and seeds `~/.config/claude-meter/accounts.conf` plus a per-account config
template if they don't already exist. Safe to re-run — it never clobbers an
existing config.

## Multi-account design

The menu bar shows a single icon, colored by the worst percentage across
every configured account — no text, no bars, no clutter. Click it to open a
dropdown with one section per account, each showing its 5-hour, 7-day, and
model-specific windows as real capsule-bar images. A thin white tick on
each bar marks the current elapsed-time position in the window; fill left
of it is under pace, fill right of it is burning fast.

Bars are colored by **pace, not raw usage** — the same rule as the Plasma
widget: **green** = comfortably under the clock, **yellow** = right on it,
**red** = ahead of it. So 90% used with 95% of the window elapsed still reads
calm, while 40% used at hour one reads hot. The menu bar icon is the one
exception: it stays colored by the worst raw percentage across your accounts,
so a single early burst doesn't turn it red all week.

Configure which accounts to show in `~/.config/claude-meter/accounts.conf`:

```
CLAUDE_METER_ACCOUNTS="personal siku"
```

Each name in that list is a separate account, configured by its own
`~/.config/claude-meter/<name>.conf` (same keys as before — see below). All
accounts' source ladders run in parallel, so two SSH-backed accounts cost one
round-trip's worth of wall time, not two.

## Config

### `accounts.conf`

| Key | Purpose |
|-----|---------|
| `CLAUDE_METER_ACCOUNTS` | Space-separated instance names to show, e.g. `"personal siku"` |
| `CLAUDE_METER_ICON` | Menu bar icon: an SF Symbol name (default `gauge.with.needle`), or `emoji:<char>` (e.g. `emoji:🤖`) as an escape hatch if a symbol name doesn't exist on your macOS version |

Pick the icon from the dropdown's **Icon** submenu instead of editing the
file by hand — each entry calls `claude-meter.sh --set-icon <value>` and
refreshes.

If `accounts.conf` is absent, the plugin falls back to a single instance
derived from its own filename, exactly as the single-account design did.

### `<name>.conf`

Edit `~/.config/claude-meter/<name>.conf` per account. Recognised keys (env
vars of the same name always take precedence over the file):

| Key | Purpose |
|-----|---------|
| `CLAUDE_METER_LABEL` | Label shown in the dropdown for this account (default `Claude`) |
| `CLAUDE_METER_REMOTE` | SSH host to fall back to, e.g. `your-linux-host` |
| `CLAUDE_METER_REMOTE_SCRIPT` | Path to the plasmoid script on that host |
| `CLAUDE_METER_REMOTE_COOKIES` | `CLAUDE_CHROME_COOKIES` to set on the remote |
| `CLAUDE_METER_REMOTE_USAGE_DIR` | `CLAUDE_USAGE_DIR` to set on the remote |
| `CLAUDE_CHROME_COOKIES` | Local Chromium-family `Cookies` DB to read |
| `CLAUDE_USAGE_DIR` | Local statusline cache dir (default `~/.claude/usage`) |
| `CLAUDE_CREDENTIALS` | Path to a `.credentials.json` with `.claudeAiOauth.accessToken`, for the token rung (default: alongside `CLAUDE_USAGE_DIR`'s parent) |
| `CLAUDE_ORG_ID` | claude.ai org UUID (else auto-detected and cached) |
| `CLAUDE_METER_FETCH` | Arbitrary command line to fill this account instead of the built-in claude.ai sources; see below |

### `CLAUDE_METER_FETCH`

Set this to a shell command line that prints one JSON line shaped like the
plugin's own `--json` output: `{"ok":true,"five":{"pct":P,"reset_in":S},"seven":{...}}`,
with an optional `model`. When it is set for an account, that account's
ladder becomes **fetch → stale** — the built-in claude.ai sources (live,
remote, cache/statusline snapshot) are skipped for it entirely, since they
read this machine's own browser cookie and usage cache, which belong to a
different account.

This is how one menu bar icon can cover an unrelated provider: point
`CLAUDE_METER_FETCH` at a script from the sibling
[codex-meter](https://github.com/matpb/codex-meter) project, run over SSH,
to add an OpenAI Codex section next to your Claude accounts (the command line is
`eval`ed locally, so spell the remote path out — a `~` would expand on this
machine):

```
CLAUDE_METER_FETCH="ssh -o BatchMode=yes -o ConnectTimeout=6 my-desktop bash /home/me/codex-meter/plasmoid/org.mat.codexmeter/contents/scripts/codex-meter.sh"
```

## Source ladder

Each account, on every refresh, tries the following in order and stops at
the first success:

1. **token** — reads the OAuth access token Claude Code stores at
   `~/.claude/.credentials.json` (or `CLAUDE_CREDENTIALS`) and hits
   `api.anthropic.com/api/oauth/usage` directly — no browser, no Safe Storage
   prompt. A missing or expired token falls through silently. Claude Code on
   macOS keeps its credentials in the Keychain rather than that file, so this
   rung is normally only reached on this Mac if you point
   `CLAUDE_CREDENTIALS` at a file yourself; it is what the **remote** rung
   uses on the Linux side.
2. **live** — decrypts your browser's claude.ai session cookie from the local
   Keychain and hits the claude.ai usage API directly.
   macOS prompts on every read of the browser's `Safe Storage` key, so the
   plugin never reads it on a refresh. Run it once by hand with
   `CLAUDE_METER_KEYCHAIN=1 bash ~/SwiftBarPlugins/claudemeter.1m.sh` and
   click **Allow**: it caches the key in a `claude-meter: <browser> Safe Storage`
   Keychain item that later refreshes read silently.
3. **remote** — if `CLAUDE_METER_REMOTE` is set, SSHes to that host and runs
   the plasmoid script there (useful when your browser session lives on a
   machine other than this Mac).
4. **cache** — a snapshot a Claude Code statusline can write locally to
   `$CLAUDE_USAGE_DIR/.ratelimit.json`.
5. **stale** — the last reading this plugin itself successfully produced for
   that account, saved to `~/.config/claude-meter/<name>.last.json`.

An account on a `cache` or `stale` reading gets a `⚠︎` next to its label in
the dropdown, with the reading's age shown — check there when the menu bar
icon looks off.

## Flags

- `--json` — print the normalized JSON reading for the single filename-derived
  instance and exit (0 if `ok:true`, 1 otherwise); ignores `accounts.conf`
- `--selftest` — offline check of the rendering logic; prints `SELFTEST OK`
- `--list-profiles` — list local Chromium-family cookie DBs as JSON, for
  picking a `CLAUDE_CHROME_COOKIES` value
- `--set-icon <value>` — write `CLAUDE_METER_ICON` into `accounts.conf` and
  exit; this is what the dropdown's Icon submenu calls
