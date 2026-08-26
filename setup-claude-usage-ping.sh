#!/usr/bin/env bash
#
# setup-claude-usage-ping.sh
#
# Installs a cron job that keeps a Claude Code 5-hour usage block warm:
# it checks the current active block via ccusage and, only if that block
# shows zero tokens, sends a minimal prompt to start the window.
#
# The whole point of this installer is that it DETECTS the environment
# instead of assuming it. Every path it bakes into the generated script
# is discovered on this machine, then verified under a stripped
# environment (env -i) that mimics cron.
#
# Usage:
#   ./setup-claude-usage-ping.sh                 # install (interactive-safe)
#   ./setup-claude-usage-ping.sh --dry-run       # show what would happen
#   ./setup-claude-usage-ping.sh --uninstall     # remove cron entry + script
#   ./setup-claude-usage-ping.sh --help
#
set -euo pipefail

VERSION="1.0.0"
MARKER="# === claude-usage-ping (managed by setup-claude-usage-ping.sh) ==="

# ---------------------------------------------------------------- defaults ---
SCHEDULE="0 */5 * * *"
MODEL="haiku"
PROMPT="Hi"
SCRIPT_PATH=""
TARGET_USER="$(id -un)"
DRY_RUN=0
DO_CRON=1
DO_SMOKE=1
UNINSTALL=0
ASSUME_YES=0

# ------------------------------------------------------------------ output ---
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'
  C_DIM=$'\033[2m';  C_B=$'\033[1m';    C_0=$'\033[0m'
else
  C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""; C_B=""; C_0=""
fi

step()  { printf '\n%s==>%s %s%s%s\n' "$C_B" "$C_0" "$C_B" "$*" "$C_0"; }
ok()    { printf '  %s+%s %s\n'  "$C_OK"   "$C_0" "$*"; }
warn()  { printf '  %s!%s %s\n'  "$C_WARN" "$C_0" "$*"; }
info()  { printf '  %s-%s %s\n'  "$C_DIM"  "$C_0" "$*"; }
die()   { printf '\n  %sFATAL%s %s\n\n' "$C_ERR" "$C_0" "$*" >&2; exit 1; }

usage() {
  cat <<USAGE
setup-claude-usage-ping.sh v$VERSION

Installs a cron job that pings Claude Code only when the current 5-hour
usage block is idle.

OPTIONS
  -u, --user USER       Install for USER (default: current user, $TARGET_USER).
                        Must be the user that ran 'claude' to authenticate.
  -s, --schedule CRON   Cron schedule (default: "$SCHEDULE")
  -m, --model MODEL     Model for the ping (default: $MODEL)
  -p, --prompt TEXT     Ping prompt (default: "$PROMPT")
      --path FILE       Where to write the script
                        (default: <home>/claude-usage-ping.sh)
      --no-cron         Generate and test the script, but don't touch crontab
      --no-smoke-test   Skip the live end-to-end run (skips a real API call)
      --dry-run         Print planned actions; change nothing
      --uninstall       Remove the cron entry and the generated script
  -y, --yes             Don't prompt for confirmation
  -h, --help            This message

NOTES
  Claude Code must already be authenticated for the target user. Run
  'claude' once interactively first -- cron cannot complete a login flow.
USAGE
}

# -------------------------------------------------------------- arg parsing ---
while [ $# -gt 0 ]; do
  case "$1" in
    -u|--user)      TARGET_USER="${2:?--user needs a value}"; shift 2 ;;
    -s|--schedule)  SCHEDULE="${2:?--schedule needs a value}"; shift 2 ;;
    -m|--model)     MODEL="${2:?--model needs a value}"; shift 2 ;;
    -p|--prompt)    PROMPT="${2:?--prompt needs a value}"; shift 2 ;;
    --path)         SCRIPT_PATH="${2:?--path needs a value}"; shift 2 ;;
    --no-cron)      DO_CRON=0; shift ;;
    --no-smoke-test) DO_SMOKE=0; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    --uninstall)    UNINSTALL=1; shift ;;
    -y|--yes)       ASSUME_YES=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *)              die "Unknown option: $1 (try --help)" ;;
  esac
done

run() {  # run CMD... unless --dry-run
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  %s[dry-run]%s %s\n' "$C_DIM" "$C_0" "$*"
  else
    "$@"
  fi
}

# ------------------------------------------------------- user + home lookup ---
step "Resolving target user"

id -u "$TARGET_USER" >/dev/null 2>&1 || die "No such user: $TARGET_USER"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[ -n "$TARGET_HOME" ] && [ -d "$TARGET_HOME" ] \
  || die "Cannot resolve a home directory for $TARGET_USER"

ok "User: $TARGET_USER"
ok "Home: $TARGET_HOME"

[ -z "$SCRIPT_PATH" ] && SCRIPT_PATH="$TARGET_HOME/claude-usage-ping.sh"
LOG_FILE="$TARGET_HOME/.claude/usage-ping.log"

AS_TARGET=()
if [ "$TARGET_USER" != "$(id -un)" ]; then
  [ "$(id -u)" -eq 0 ] || die "Installing for another user requires root."
  AS_TARGET=(sudo -u "$TARGET_USER" -H)
  info "Commands for $TARGET_USER will run via sudo -u"
fi

SUDO=()
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then SUDO=(sudo); fi
fi

# ------------------------------------------------------------- uninstall ------
if [ "$UNINSTALL" -eq 1 ]; then
  step "Uninstalling"
  if CURRENT="$("${AS_TARGET[@]}" crontab -l 2>/dev/null)"; then
    CLEANED="$(printf '%s\n' "$CURRENT" | grep -vF "$MARKER" | grep -vF "$SCRIPT_PATH" || true)"
    if [ "$DRY_RUN" -eq 1 ]; then
      info "[dry-run] would rewrite crontab without the managed entry"
    else
      printf '%s\n' "$CLEANED" | "${AS_TARGET[@]}" crontab -
      ok "Cron entry removed"
    fi
  else
    info "No crontab for $TARGET_USER"
  fi
  if [ -f "$SCRIPT_PATH" ]; then
    run rm -f "$SCRIPT_PATH"; ok "Removed $SCRIPT_PATH"
  fi
  info "Log left in place: $LOG_FILE"
  echo; exit 0
fi

# ----------------------------------------------------------- binary lookup ---
# Search order: the target user's login PATH first (so we honour whatever
# they actually use), then a list of well-known install locations. This is
# the step that the original script got wrong -- it assumed /usr/local/bin.
step "Detecting binaries"

CANDIDATE_DIRS=()
add_dir() { [ -d "$1" ] && CANDIDATE_DIRS+=("$1"); return 0; }

add_dir "$TARGET_HOME/.local/bin"          # Claude native installer
add_dir "$TARGET_HOME/bin"
add_dir "$TARGET_HOME/.npm-global/bin"     # npm prefix override
add_dir "/opt/nodejs/bin"
add_dir "/usr/local/bin"
add_dir "/usr/bin"
add_dir "/bin"
add_dir "/snap/bin"

# nvm / fnm / volta: newest version first
for d in $(ls -1dr "$TARGET_HOME"/.nvm/versions/node/*/bin 2>/dev/null || true); do
  add_dir "$d"
done
for d in $(ls -1dr "$TARGET_HOME"/.fnm/node-versions/*/installation/bin 2>/dev/null || true); do
  add_dir "$d"
done
add_dir "$TARGET_HOME/.volta/bin"

# npm's own global prefix, if npm is reachable at all
if NPM_PREFIX="$(command -v npm >/dev/null 2>&1 && npm prefix -g 2>/dev/null)"; then
  add_dir "$NPM_PREFIX/bin"
fi

find_bin() {  # find_bin NAME -> absolute path on stdout, or empty
  local name="$1" p
  p="$(command -v "$name" 2>/dev/null || true)"
  if [ -n "$p" ] && [ -x "$p" ]; then printf '%s\n' "$p"; return 0; fi
  for d in "${CANDIDATE_DIRS[@]}"; do
    if [ -x "$d/$name" ]; then printf '%s\n' "$d/$name"; return 0; fi
  done
  return 0
}

NODE_BIN="$(find_bin node)"
NPM_BIN="$(find_bin npm)"
CLAUDE_BIN="$(find_bin claude)"
JQ_BIN="$(find_bin jq)"
CCUSAGE_BIN="$(find_bin ccusage)"

[ -n "$NODE_BIN" ] && ok "node:    $NODE_BIN" || warn "node:    not found"
[ -n "$CLAUDE_BIN" ] && ok "claude:  $CLAUDE_BIN" || warn "claude:  not found"

[ -n "$CLAUDE_BIN" ] || die "claude CLI not found. Install it, then re-run.
        Checked: ${CANDIDATE_DIRS[*]}"

# ------------------------------------------------------------- install jq ----
if [ -z "$JQ_BIN" ]; then
  warn "jq: not found -- attempting install"
  if command -v apt-get >/dev/null 2>&1; then
    run "${SUDO[@]}" apt-get update -qq
    run "${SUDO[@]}" apt-get install -y jq
  elif command -v dnf >/dev/null 2>&1; then run "${SUDO[@]}" dnf install -y jq
  elif command -v yum >/dev/null 2>&1; then run "${SUDO[@]}" yum install -y jq
  elif command -v apk >/dev/null 2>&1; then run "${SUDO[@]}" apk add --no-cache jq
  else die "No supported package manager. Install jq manually."
  fi
  JQ_BIN="$(find_bin jq)"
  [ "$DRY_RUN" -eq 1 ] && JQ_BIN="${JQ_BIN:-/usr/bin/jq}"
  [ -n "$JQ_BIN" ] || die "jq install appeared to succeed but jq is still not on PATH."
fi
ok "jq:      $JQ_BIN"

# -------------------------------------------------------- install ccusage ----
# Deliberately NOT 'npx --yes ccusage@latest': under cron that hits the
# network and re-resolves the package on every single run.
if [ -z "$CCUSAGE_BIN" ]; then
  warn "ccusage: not found -- installing globally via npm"
  [ -n "$NPM_BIN" ] || die "npm not found; cannot install ccusage."
  run "${SUDO[@]}" "$NPM_BIN" install -g ccusage
  CCUSAGE_BIN="$(find_bin ccusage)"
  [ "$DRY_RUN" -eq 1 ] && CCUSAGE_BIN="${CCUSAGE_BIN:-/usr/local/bin/ccusage}"
  [ -n "$CCUSAGE_BIN" ] || die "ccusage installed but not found on PATH."
fi
ok "ccusage: $CCUSAGE_BIN"

# ------------------------------------------------------------ PATH assembly ---
# Build the exact PATH the generated script will pin. Note: no ':$PATH'
# suffix -- inheriting the caller's PATH is what made the original script
# behave differently in a terminal than under cron.
PIN_DIRS=()
for b in "$CLAUDE_BIN" "$CCUSAGE_BIN" "$JQ_BIN" "$NODE_BIN"; do
  [ -n "$b" ] || continue
  d="$(dirname "$b")"
  case ":$(IFS=:; echo "${PIN_DIRS[*]:-}"):" in
    *":$d:"*) ;;
    *) PIN_DIRS+=("$d") ;;
  esac
done
for d in /usr/local/bin /usr/bin /bin; do
  case ":$(IFS=:; echo "${PIN_DIRS[*]:-}"):" in
    *":$d:"*) ;;
    *) PIN_DIRS+=("$d") ;;
  esac
done
PINNED_PATH="$(IFS=:; echo "${PIN_DIRS[*]}")"
ok "PATH:    $PINNED_PATH"

# ---------------------------------------------------------------- auth check ---
step "Checking Claude Code authentication"

AUTH_HINT=0
if [ -f "$TARGET_HOME/.claude/.credentials.json" ]; then
  ok "Credentials found in $TARGET_HOME/.claude/"
elif [ -d "$TARGET_HOME/.claude" ]; then
  warn "$TARGET_HOME/.claude exists but no .credentials.json"
  info "You may be authenticating via an API key env var instead."
  AUTH_HINT=1
else
  warn "No $TARGET_HOME/.claude directory at all"
  AUTH_HINT=1
fi

if [ "$AUTH_HINT" -eq 1 ]; then
  warn "Cron cannot complete an interactive login."
  info "If the smoke test below fails with an auth error, run 'claude'"
  info "once as $TARGET_USER, finish the login, then re-run this installer."
fi

# ------------------------------------------------------------ schema probe ----
# The second bug this installer exists to prevent: ccusage's JSON shape has
# changed between versions ({"data":[...]} -> {"blocks":[...]}). Rather than
# hardcoding a guess, probe it now and report what we see. The expression
# baked into the script tolerates both, plus a nested tokenCounts layout.
step "Probing ccusage JSON schema"

TOKEN_EXPR='[ (.blocks // .data // [])[]? | (.totalTokens // .tokenCounts.totalTokens // ((.tokenCounts.inputTokens // 0) + (.tokenCounts.outputTokens // 0))) ] | add // 0'

if [ "$DRY_RUN" -eq 1 ]; then
  info "[dry-run] would run: $CCUSAGE_BIN blocks --active --json"
else
  PROBE="$("${AS_TARGET[@]}" "$CCUSAGE_BIN" blocks --active --json 2>/dev/null || true)"
  if [ -z "$PROBE" ]; then
    warn "ccusage returned nothing -- cannot verify schema now."
    info "The generated script tolerates both known layouts anyway."
  else
    TOPKEYS="$(printf '%s' "$PROBE" | "$JQ_BIN" -r 'keys | join(", ")' 2>/dev/null || echo "?")"
    ok "Top-level keys: $TOPKEYS"
    case "$TOPKEYS" in
      *blocks*) ok "Using .blocks (current schema)" ;;
      *data*)   warn "Legacy .data schema detected -- handled by fallback" ;;
      *)        warn "Unrecognised schema; falling back to 0 (script will ping)" ;;
    esac
    PROBE_TOKENS="$(printf '%s' "$PROBE" | "$JQ_BIN" -r "$TOKEN_EXPR" 2>/dev/null || echo "?")"
    ok "Parsed token count right now: $PROBE_TOKENS"
    if [ "$PROBE_TOKENS" = "0" ]; then
      info "Zero means either no active block, or an idle one. Both are fine."
    fi
  fi
fi

# --------------------------------------------------------- write the script ---
step "Writing $SCRIPT_PATH"

TMP_SCRIPT="$(mktemp)"
trap 'rm -f "$TMP_SCRIPT"' EXIT

# Config block: expanded now, so real paths get baked in.
cat > "$TMP_SCRIPT" <<CONFIG
#!/usr/bin/env bash
#
# claude-usage-ping.sh -- generated by setup-claude-usage-ping.sh v$VERSION
# Generated $(date '+%Y-%m-%d %H:%M:%S') for user $TARGET_USER
#
# Checks the active Claude Code 5-hour block and sends a minimal prompt
# only if that block is idle. Every path below was detected at install
# time; re-run the installer if you move or upgrade any of these tools.
#
set -euo pipefail

export HOME="\${HOME:-$TARGET_HOME}"
export PATH="$PINNED_PATH"

CLAUDE_BIN="$CLAUDE_BIN"
CCUSAGE_BIN="$CCUSAGE_BIN"
JQ_BIN="$JQ_BIN"

MODEL="$MODEL"
PROMPT="$PROMPT"
LOG_FILE="\$HOME/.claude/usage-ping.log"
MAX_LOG_BYTES=1048576

TOKEN_EXPR='$TOKEN_EXPR'
CONFIG

# Body: quoted heredoc so nothing expands at generation time.
cat >> "$TMP_SCRIPT" <<'BODY'

mkdir -p "$(dirname "$LOG_FILE")"

# Keep the log from growing without bound on a long-lived box.
if [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE")" -gt "$MAX_LOG_BYTES" ]; then
  mv -f "$LOG_FILE" "$LOG_FILE.1"
fi

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"; }

# Without this, 'set -e' turns any failure into a silent exit with an
# empty log -- which is exactly how the original version hid its bugs.
trap 'log "ERROR: line $LINENO exited with status $?"' ERR

# Never let two runs overlap (a slow ping plus a tight schedule).
LOCK_FILE="$HOME/.claude/usage-ping.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "Another run holds the lock - exiting"
  exit 0
fi

# Preflight: fail loudly on run #1 rather than silently on run #12.
for _bin in "$CCUSAGE_BIN" "$CLAUDE_BIN" "$JQ_BIN"; do
  if [ ! -x "$_bin" ]; then
    log "FATAL: $_bin missing or not executable - re-run the installer"
    exit 1
  fi
done

USAGE_JSON="$("$CCUSAGE_BIN" blocks --active --json 2>>"$LOG_FILE" || echo '{}')"

TOKENS_USED="$(printf '%s' "$USAGE_JSON" | "$JQ_BIN" -r "$TOKEN_EXPR" 2>>"$LOG_FILE" || echo 0)"

# jq can emit '', 'null', or a float. Any of those would make the numeric
# test below throw and, under 'set -e', kill the script without a word.
TOKENS_USED="${TOKENS_USED%%.*}"
case "$TOKENS_USED" in
  ''|null|*[!0-9]*)
    log "WARN: non-numeric token count '$TOKENS_USED' - treating as 0"
    TOKENS_USED=0
    ;;
esac

log "Active-block tokens: $TOKENS_USED"

if [ "$TOKENS_USED" -eq 0 ]; then
  log "Block idle - sending ping"
  if PING_OUTPUT="$("$CLAUDE_BIN" -p "$PROMPT" --model "$MODEL" --output-format json 2>>"$LOG_FILE")"; then
    SESSION="$(printf '%s' "$PING_OUTPUT" | "$JQ_BIN" -r '.session_id // "unknown"' 2>/dev/null || echo unknown)"
    log "Ping OK (session: $SESSION)"
  else
    log "Ping FAILED: $PING_OUTPUT"
    exit 1
  fi
else
  log "Already active ($TOKENS_USED tokens) - skipping ping"
fi
BODY

if [ "$DRY_RUN" -eq 1 ]; then
  info "[dry-run] would write $SCRIPT_PATH ($(wc -l < "$TMP_SCRIPT") lines)"
else
  bash -n "$TMP_SCRIPT" || die "Generated script failed syntax check (bug in installer)."
  install -m 700 -o "$TARGET_USER" "$TMP_SCRIPT" "$SCRIPT_PATH" 2>/dev/null \
    || { cp "$TMP_SCRIPT" "$SCRIPT_PATH"; chmod 700 "$SCRIPT_PATH"; }
  ok "Written and syntax-checked ($(wc -l < "$SCRIPT_PATH") lines)"
fi

# --------------------------------------------------------------- smoke test ---
# The decisive test: env -i strips the environment, so this reproduces
# cron's conditions exactly. Passing here means passing under cron.
step "Smoke test under a stripped environment (simulates cron)"

if [ "$DRY_RUN" -eq 1 ]; then
  info "[dry-run] would run: env -i HOME=$TARGET_HOME /bin/bash $SCRIPT_PATH"
elif [ "$DO_SMOKE" -eq 0 ]; then
  info "Skipped (--no-smoke-test)"
else
  info "Running: env -i HOME=$TARGET_HOME /bin/bash $SCRIPT_PATH"
  if "${AS_TARGET[@]}" env -i HOME="$TARGET_HOME" /bin/bash "$SCRIPT_PATH"; then
    ok "Exited cleanly"
  else
    warn "Non-zero exit -- see the log below"
  fi
  echo
  info "Last log lines:"
  tail -n 5 "$LOG_FILE" 2>/dev/null | sed 's/^/      /' || info "(log empty)"
  echo
  if tail -n 5 "$LOG_FILE" 2>/dev/null | grep -qE 'command not found|FATAL|Ping FAILED'; then
    die "Smoke test surfaced a real failure. Fix it before trusting cron;
        cron's environment is no richer than the one just used."
  fi
fi

# -------------------------------------------------------------- cron install ---
if [ "$DO_CRON" -eq 0 ]; then
  step "Cron"
  info "Skipped (--no-cron). Entry you would add:"
  printf '      %s %s\n' "$SCHEDULE" "$SCRIPT_PATH"
else
  step "Installing cron entry for $TARGET_USER"

  if [ "$ASSUME_YES" -eq 0 ] && [ "$DRY_RUN" -eq 0 ] && [ -t 0 ]; then
    printf '  Add "%s %s" to %s'"'"'s crontab? [Y/n] ' \
      "$SCHEDULE" "$SCRIPT_PATH" "$TARGET_USER"
    read -r reply
    case "$reply" in [nN]*) DO_CRON=0; warn "Skipped by user" ;; esac
  fi

  if [ "$DO_CRON" -eq 1 ]; then
    CURRENT="$("${AS_TARGET[@]}" crontab -l 2>/dev/null || true)"
    # Idempotent: strip any previous managed block before re-adding.
    CLEANED="$(printf '%s\n' "$CURRENT" \
      | grep -vF "$MARKER" \
      | grep -vF "$SCRIPT_PATH" \
      | sed '/^PATH=.*claude-usage-ping-managed$/d' || true)"

    NEW_CRON="$(printf '%s\n%s\n%s %s\n' \
      "$CLEANED" "$MARKER" "$SCHEDULE" "$SCRIPT_PATH" \
      | sed -e '/./,$!d' -e '/^$/{ x; /./d; x; }')"

    if [ "$DRY_RUN" -eq 1 ]; then
      info "[dry-run] resulting crontab would be:"
      printf '%s\n' "$NEW_CRON" | sed 's/^/      /'
    else
      printf '%s\n' "$NEW_CRON" | "${AS_TARGET[@]}" crontab -
      ok "Installed: $SCHEDULE $SCRIPT_PATH"
    fi
  fi
fi

# ------------------------------------------------------------------ summary ---
step "Done"
cat <<SUMMARY
  Script    $SCRIPT_PATH
  Log       $LOG_FILE
  Schedule  $SCHEDULE
  User      $TARGET_USER
  PATH      $PINNED_PATH

  Verify the next scheduled run:
    tail -f $LOG_FILE
    crontab -l -u $TARGET_USER
    grep CRON /var/log/syslog | tail -5      # or: journalctl -u cron -n 20

  Re-run this installer after upgrading node, ccusage, or the claude CLI --
  the absolute paths baked into the script will not follow a version bump.

  Remove everything:
    $0 --user $TARGET_USER --uninstall
SUMMARY
echo