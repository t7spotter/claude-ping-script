#!/usr/bin/env bash
#
# setup-claude-usage-ping.sh
#
# Installs a cron job that keeps a Claude Code 5-hour usage block warm: it
# checks the current active block via ccusage and, only if that block shows
# zero tokens, sends a minimal prompt to start the window.
#
# The point of this installer is that it DETECTS the environment instead of
# assuming it. Every path baked into the generated script is discovered on
# the target machine, then verified under a stripped environment (env -i)
# that reproduces cron's conditions.
#
# Install:
#   curl -fsSL https://raw.githubusercontent.com/USER/REPO/v1.0.1/setup-claude-usage-ping.sh | bash
#
# Or, preferably, download and read it first:
#   curl -fsSL -o setup.sh https://raw.githubusercontent.com/USER/REPO/v1.0.1/setup-claude-usage-ping.sh
#   less setup.sh && bash setup.sh --dry-run && bash setup.sh
#
# Requires: bash 4+, cron, node/npm, and an already-authenticated claude CLI.
#
# The entire body lives inside main(), invoked on the final line. That makes
# `curl | bash` safe against truncation: a partial download cannot execute
# anything, because the call to main() is the last thing to arrive.
#
set -euo pipefail

VERSION="1.0.1"
MARKER="# === claude-usage-ping (managed by setup-claude-usage-ping.sh) ==="

# Under `curl | bash`, $0 is "bash" (or a /dev/fd path). Fall back to the
# canonical name so the uninstall hint we print is actually runnable.
SELF="$0"
case "$SELF" in
  bash|sh|-bash|-sh|/dev/fd/*|/proc/self/fd/*|/dev/stdin)
    SELF="setup-claude-usage-ping.sh" ;;
esac

# ------------------------------------------------------------------ defaults ---
SCHEDULE="0 0,5,9,14,19 * * *"
MODEL="haiku"
PROMPT="Hi"
SCRIPT_PATH=""
TARGET_USER="$(id -un)"
DRY_RUN=0
DO_CRON=1
DO_SMOKE=1
UNINSTALL=0
ASSUME_YES=0

# -------------------------------------------------------------------- output ---
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'
  C_DIM=$'\033[2m';  C_B=$'\033[1m';    C_0=$'\033[0m'
else
  C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""; C_B=""; C_0=""
fi

step() { printf '\n%s==>%s %s%s%s\n' "$C_B" "$C_0" "$C_B" "$*" "$C_0"; }
ok()   { printf '  %s+%s %s\n' "$C_OK"   "$C_0" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_WARN" "$C_0" "$*"; }
info() { printf '  %s-%s %s\n' "$C_DIM"  "$C_0" "$*"; }
die()  { printf '\n  %sFATAL%s %s\n\n' "$C_ERR" "$C_0" "$*" >&2; exit 1; }

run() {  # execute, unless --dry-run
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  %s[dry-run]%s %s\n' "$C_DIM" "$C_0" "$*"
  else
    "$@"
  fi
}

usage() {
  cat <<USAGE
setup-claude-usage-ping.sh v$VERSION

Installs a cron job that pings Claude Code only when the current 5-hour
usage block is idle.

OPTIONS
  -u, --user USER       Install for USER (default: current user).
                        Must be the user that authenticated the claude CLI.
  -s, --schedule CRON   Cron schedule (default: "$SCHEDULE")
  -m, --model MODEL     Model used for the ping (default: $MODEL)
  -p, --prompt TEXT     Ping prompt (default: "$PROMPT")
      --path FILE       Where to write the generated script
                        (default: <home>/claude-usage-ping.sh)
      --no-cron         Generate and test the script, but leave crontab alone
      --no-smoke-test   Skip the live end-to-end run (avoids one API call)
      --dry-run         Print planned actions; change nothing
      --uninstall       Remove the cron entry and the generated script
  -y, --yes             Never prompt for confirmation
  -h, --help            Show this message

PREREQUISITE
  Claude Code must already be authenticated for the target user. Run
  'claude' once interactively first -- cron cannot complete a login flow.

NOTE
  This installs a job that sends a real prompt on a schedule and therefore
  consumes quota. Run with --dry-run first if that matters to you.

  Piped installs (curl | bash) are non-interactive: stdin is the pipe, so
  the confirmation prompt is skipped and the cron entry is installed.
USAGE
}

need_val() {  # need_val FLAG VALUE... -- die if the flag has no value
  [ $# -ge 2 ] && [ -n "${2:-}" ] || die "Option $1 requires a value (try --help)"
  case "$2" in -*) die "Option $1 requires a value, got: $2" ;; esac
  return 0
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -u|--user)       need_val "$@"; TARGET_USER="$2"; shift 2 ;;
      -s|--schedule)   need_val "$@"; SCHEDULE="$2"; shift 2 ;;
      -m|--model)      need_val "$@"; MODEL="$2"; shift 2 ;;
      -p|--prompt)     need_val "$@"; PROMPT="$2"; shift 2 ;;
      --path)          need_val "$@"; SCRIPT_PATH="$2"; shift 2 ;;
      --no-cron)       DO_CRON=0; shift ;;
      --no-smoke-test) DO_SMOKE=0; shift ;;
      --dry-run)       DRY_RUN=1; shift ;;
      --uninstall)     UNINSTALL=1; shift ;;
      -y|--yes)        ASSUME_YES=1; shift ;;
      -h|--help)       usage; exit 0 ;;
      *)               die "Unknown option: $1 (try --help)" ;;
    esac
  done
}

# ------------------------------------------------------------ binary lookup ---
CANDIDATE_DIRS=()
add_dir() { [ -d "$1" ] && CANDIDATE_DIRS+=("$1"); return 0; }

build_candidates() {
  add_dir "$TARGET_HOME/.local/bin"        # claude native installer
  add_dir "$TARGET_HOME/bin"
  add_dir "$TARGET_HOME/.npm-global/bin"   # custom npm prefix
  add_dir "/opt/nodejs/bin"
  add_dir "/usr/local/bin"
  add_dir "/usr/bin"
  add_dir "/bin"
  add_dir "/snap/bin"
  add_dir "/opt/homebrew/bin"

  # Version managers, newest first.
  local d
  for d in $(ls -1dr "$TARGET_HOME"/.nvm/versions/node/*/bin 2>/dev/null || true); do
    add_dir "$d"
  done
  for d in $(ls -1dr "$TARGET_HOME"/.fnm/node-versions/*/installation/bin 2>/dev/null || true); do
    add_dir "$d"
  done
  add_dir "$TARGET_HOME/.volta/bin"
  add_dir "$TARGET_HOME/.bun/bin"

  if command -v npm >/dev/null 2>&1; then
    local prefix
    prefix="$(npm prefix -g 2>/dev/null || true)"
    [ -n "$prefix" ] && add_dir "$prefix/bin"
  fi
  return 0
}

find_bin() {  # find_bin NAME -> absolute path on stdout, empty if absent
  local name="$1" p d
  p="$(command -v "$name" 2>/dev/null || true)"
  if [ -n "$p" ] && [ -x "$p" ]; then printf '%s\n' "$p"; return 0; fi
  for d in "${CANDIDATE_DIRS[@]}"; do
    if [ -x "$d/$name" ]; then printf '%s\n' "$d/$name"; return 0; fi
  done
  return 0
}

path_add() {  # append $1 to PIN_DIRS if not already present
  local d="$1" existing
  existing=":$(IFS=:; echo "${PIN_DIRS[*]:-}"):"
  case "$existing" in
    *":$d:"*) ;;
    *) PIN_DIRS+=("$d") ;;
  esac
  return 0
}

# ----------------------------------------------------------------- uninstall ---
do_uninstall() {
  step "Uninstalling"
  local current cleaned
  if current="$("${AS_TARGET[@]}" crontab -l 2>/dev/null)"; then
    cleaned="$(printf '%s\n' "$current" \
      | grep -vF "$MARKER" \
      | grep -vF "$SCRIPT_PATH" || true)"
    if [ "$DRY_RUN" -eq 1 ]; then
      info "[dry-run] would rewrite crontab without the managed entry"
    else
      printf '%s\n' "$cleaned" | "${AS_TARGET[@]}" crontab -
      ok "Cron entry removed"
    fi
  else
    info "No crontab for $TARGET_USER"
  fi

  if [ -f "$SCRIPT_PATH" ]; then
    run rm -f "$SCRIPT_PATH"
    ok "Removed $SCRIPT_PATH"
  else
    info "No script at $SCRIPT_PATH"
  fi

  info "Log left in place: $LOG_FILE"
  echo
}

# ------------------------------------------------------- script generation ----
write_script() {
  step "Writing $SCRIPT_PATH"

  TMP_SCRIPT="$(mktemp)"
  trap 'rm -f "${TMP_SCRIPT:-}"' EXIT

  # Config block: expanded now, so detected paths are baked in literally.
  cat > "$TMP_SCRIPT" <<CONFIG
#!/usr/bin/env bash
#
# claude-usage-ping.sh
# Generated by setup-claude-usage-ping.sh v$VERSION
# on $(date '+%Y-%m-%d %H:%M:%S') for user $TARGET_USER
#
# Checks the active Claude Code 5-hour block and sends a minimal prompt only
# if that block is idle. Every path below was detected at install time --
# re-run the installer after upgrading node, ccusage, or the claude CLI.
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

  # Body: quoted heredoc, so nothing expands at generation time.
  cat >> "$TMP_SCRIPT" <<'BODY'

mkdir -p "$(dirname "$LOG_FILE")"

# Keep the log bounded on a long-lived box.
if [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE")" -gt "$MAX_LOG_BYTES" ]; then
  mv -f "$LOG_FILE" "$LOG_FILE.1"
fi

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"; }

# Without this, 'set -e' turns any failure into a silent exit and an empty
# log -- which is precisely how a missing binary can hide for days.
trap 'log "ERROR: line $LINENO exited with status $?"' ERR

# Never let two runs overlap (slow ping + tight schedule).
LOCK_FILE="$HOME/.claude/usage-ping.lock"
exec 9>"$LOCK_FILE"
if command -v flock >/dev/null 2>&1; then
  if ! flock -n 9; then
    log "Another run holds the lock - exiting"
    exit 0
  fi
fi

# Preflight: fail loudly on run #1 instead of silently on run #12.
for _bin in "$CCUSAGE_BIN" "$CLAUDE_BIN" "$JQ_BIN"; do
  if [ ! -x "$_bin" ]; then
    log "FATAL: $_bin missing or not executable - re-run the installer"
    exit 1
  fi
done

USAGE_JSON="$("$CCUSAGE_BIN" blocks --active --json 2>>"$LOG_FILE" || echo '{}')"

TOKENS_USED="$(printf '%s' "$USAGE_JSON" \
  | "$JQ_BIN" -r "$TOKEN_EXPR" 2>>"$LOG_FILE" || echo 0)"

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
    SESSION="$(printf '%s' "$PING_OUTPUT" \
      | "$JQ_BIN" -r '.session_id // "unknown"' 2>/dev/null || echo unknown)"
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
    return 0
  fi

  bash -n "$TMP_SCRIPT" || die "Generated script failed its syntax check (installer bug)."
  install -m 700 -o "$TARGET_USER" "$TMP_SCRIPT" "$SCRIPT_PATH" 2>/dev/null \
    || { cp "$TMP_SCRIPT" "$SCRIPT_PATH"; chmod 700 "$SCRIPT_PATH"; }
  ok "Written and syntax-checked ($(wc -l < "$SCRIPT_PATH") lines)"
}

# ---------------------------------------------------------------- smoke test ---
smoke_test() {
  step "Smoke test under a stripped environment (simulates cron)"

  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] would run: env -i HOME=$TARGET_HOME /bin/bash $SCRIPT_PATH"
    return 0
  fi
  if [ "$DO_SMOKE" -eq 0 ]; then
    info "Skipped (--no-smoke-test)"
    return 0
  fi

  info "Running: env -i HOME=$TARGET_HOME /bin/bash $SCRIPT_PATH"
  if "${AS_TARGET[@]}" env -i HOME="$TARGET_HOME" /bin/bash "$SCRIPT_PATH"; then
    ok "Exited cleanly"
  else
    warn "Non-zero exit -- see log below"
  fi

  echo
  info "Last log lines:"
  tail -n 5 "$LOG_FILE" 2>/dev/null | sed 's/^/      /' || info "(log empty)"
  echo

  if tail -n 5 "$LOG_FILE" 2>/dev/null \
     | grep -qE 'command not found|FATAL|Ping FAILED'; then
    die "Smoke test surfaced a real failure. Fix it before trusting cron --
        cron's environment is no richer than the one just used."
  fi
}

# -------------------------------------------------------------- cron install ---
install_cron() {
  if [ "$DO_CRON" -eq 0 ]; then
    step "Cron"
    info "Skipped (--no-cron). Entry you would add:"
    printf '      %s %s\n' "$SCHEDULE" "$SCRIPT_PATH"
    return 0
  fi

  step "Installing cron entry for $TARGET_USER"

  if ! command -v crontab >/dev/null 2>&1; then
    warn "crontab not found -- skipping. Add this manually:"
    printf '      %s %s\n' "$SCHEDULE" "$SCRIPT_PATH"
    return 0
  fi

  if [ "$ASSUME_YES" -eq 0 ] && [ "$DRY_RUN" -eq 0 ] && [ -t 0 ]; then
    local reply
    printf '  Add "%s %s" to %s crontab? [Y/n] ' \
      "$SCHEDULE" "$SCRIPT_PATH" "$TARGET_USER"
    read -r reply
    case "$reply" in
      [nN]*) warn "Skipped by user"; return 0 ;;
    esac
  fi

  local current cleaned new_cron
  current="$("${AS_TARGET[@]}" crontab -l 2>/dev/null || true)"

  # Idempotent: strip any previous managed entry before re-adding.
  cleaned="$(printf '%s\n' "$current" \
    | grep -vF "$MARKER" \
    | grep -vF "$SCRIPT_PATH" || true)"

  # Collapse leading and duplicate blank lines.
  new_cron="$(printf '%s\n%s\n%s %s\n' \
    "$cleaned" "$MARKER" "$SCHEDULE" "$SCRIPT_PATH" \
    | sed -e '/./,$!d' -e '/^$/{ x; /./d; x; }')"

  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] resulting crontab would be:"
    printf '%s\n' "$new_cron" | sed 's/^/      /'
  else
    printf '%s\n' "$new_cron" | "${AS_TARGET[@]}" crontab -
    ok "Installed: $SCHEDULE $SCRIPT_PATH"
  fi
}

# ---------------------------------------------------------------------- main ---
main() {
  parse_args "$@"

  # -- target user and home -------------------------------------------------
  step "Resolving target user"

  id -u "$TARGET_USER" >/dev/null 2>&1 || die "No such user: $TARGET_USER"

  TARGET_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6 || true)"
  if [ -z "$TARGET_HOME" ] && [ "$TARGET_USER" = "$(id -un)" ]; then
    TARGET_HOME="${HOME:-}"     # getent is absent on macOS
  fi
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
  if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
    SUDO=(sudo)
  fi

  if [ "$UNINSTALL" -eq 1 ]; then
    do_uninstall
    exit 0
  fi

  # -- detect binaries ------------------------------------------------------
  # This is the step the hand-written version got wrong: it hardcoded
  # /usr/local/bin, which cron then could not resolve.
  step "Detecting binaries"
  build_candidates

  NODE_BIN="$(find_bin node)"
  NPM_BIN="$(find_bin npm)"
  CLAUDE_BIN="$(find_bin claude)"
  JQ_BIN="$(find_bin jq)"
  CCUSAGE_BIN="$(find_bin ccusage)"

  [ -n "$NODE_BIN" ]   && ok   "node:    $NODE_BIN"   || warn "node:    not found"
  [ -n "$CLAUDE_BIN" ] && ok   "claude:  $CLAUDE_BIN" || warn "claude:  not found"

  [ -n "$CLAUDE_BIN" ] || die "claude CLI not found. Install it, then re-run.
        Searched: ${CANDIDATE_DIRS[*]}"

  # -- jq -------------------------------------------------------------------
  if [ -z "$JQ_BIN" ]; then
    warn "jq: not found -- installing"
    if   command -v apt-get >/dev/null 2>&1; then
      run "${SUDO[@]}" apt-get update -qq
      run "${SUDO[@]}" apt-get install -y jq
    elif command -v dnf >/dev/null 2>&1; then run "${SUDO[@]}" dnf install -y jq
    elif command -v yum >/dev/null 2>&1; then run "${SUDO[@]}" yum install -y jq
    elif command -v apk >/dev/null 2>&1; then run "${SUDO[@]}" apk add --no-cache jq
    elif command -v brew >/dev/null 2>&1; then run brew install jq
    else die "No supported package manager found. Install jq manually, then re-run."
    fi
    JQ_BIN="$(find_bin jq)"
    [ "$DRY_RUN" -eq 1 ] && JQ_BIN="${JQ_BIN:-/usr/bin/jq}"
    [ -n "$JQ_BIN" ] || die "jq install reported success but jq is still not found."
  fi
  ok "jq:      $JQ_BIN"

  # -- ccusage --------------------------------------------------------------
  # Deliberately not 'npx --yes ccusage@latest': under cron that means a
  # network round-trip and a package re-resolution on every single run.
  if [ -z "$CCUSAGE_BIN" ]; then
    warn "ccusage: not found -- installing globally via npm"
    [ -n "$NPM_BIN" ] || die "npm not found; cannot install ccusage."
    run "${SUDO[@]}" "$NPM_BIN" install -g ccusage
    CCUSAGE_BIN="$(find_bin ccusage)"
    [ "$DRY_RUN" -eq 1 ] && CCUSAGE_BIN="${CCUSAGE_BIN:-/usr/local/bin/ccusage}"
    [ -n "$CCUSAGE_BIN" ] || die "ccusage installed but not found on PATH."
  fi
  ok "ccusage: $CCUSAGE_BIN"

  # -- assemble the pinned PATH --------------------------------------------
  # No ':$PATH' suffix. Inheriting the caller's PATH is exactly what makes a
  # script behave one way in a terminal and another way under cron.
  PIN_DIRS=()
  local b d
  for b in "$CLAUDE_BIN" "$CCUSAGE_BIN" "$JQ_BIN" "$NODE_BIN"; do
    [ -n "$b" ] || continue
    path_add "$(dirname "$b")"
  done
  for d in /usr/local/bin /usr/bin /bin; do
    path_add "$d"
  done
  PINNED_PATH="$(IFS=:; echo "${PIN_DIRS[*]}")"
  ok "PATH:    $PINNED_PATH"

  # -- authentication -------------------------------------------------------
  step "Checking Claude Code authentication"

  local auth_hint=0
  if [ -f "$TARGET_HOME/.claude/.credentials.json" ]; then
    ok "Credentials found in $TARGET_HOME/.claude/"
  elif [ -d "$TARGET_HOME/.claude" ]; then
    warn "$TARGET_HOME/.claude exists but holds no .credentials.json"
    info "You may be authenticating via an API key environment variable."
    auth_hint=1
  else
    warn "No $TARGET_HOME/.claude directory"
    auth_hint=1
  fi

  if [ "$auth_hint" -eq 1 ]; then
    warn "Cron cannot complete an interactive login."
    info "If the smoke test fails on auth, run 'claude' once as $TARGET_USER,"
    info "finish the login, then re-run this installer."
  fi

  # -- probe the ccusage schema --------------------------------------------
  # The second bug worth designing against: ccusage's JSON shape changed
  # between versions ({"data":[...]} became {"blocks":[...]}). A hardcoded
  # key silently yields 0 forever, so probe it and report what we find.
  step "Probing ccusage JSON schema"

  TOKEN_EXPR='[ (.blocks // .data // [])[]? | (.totalTokens // .tokenCounts.totalTokens // ((.tokenCounts.inputTokens // 0) + (.tokenCounts.outputTokens // 0))) ] | add // 0'

  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] would run: $CCUSAGE_BIN blocks --active --json"
  else
    local probe topkeys probe_tokens
    probe="$("${AS_TARGET[@]}" "$CCUSAGE_BIN" blocks --active --json 2>/dev/null || true)"
    if [ -z "$probe" ]; then
      warn "ccusage returned nothing -- cannot verify the schema right now."
      info "The generated script tolerates both known layouts regardless."
    else
      topkeys="$(printf '%s' "$probe" | "$JQ_BIN" -r 'keys | join(", ")' 2>/dev/null || echo '?')"
      ok "Top-level keys: $topkeys"
      case "$topkeys" in
        *blocks*) ok   "Using .blocks (current schema)" ;;
        *data*)   warn "Legacy .data schema -- handled by the fallback" ;;
        *)        warn "Unrecognised schema; will fall back to 0 (script pings)" ;;
      esac
      probe_tokens="$(printf '%s' "$probe" | "$JQ_BIN" -r "$TOKEN_EXPR" 2>/dev/null || echo '?')"
      ok "Parsed token count right now: $probe_tokens"
      [ "$probe_tokens" = "0" ] && \
        info "Zero means either no active block or an idle one. Both are fine."
    fi
  fi

  write_script
  smoke_test
  install_cron

  # -- summary --------------------------------------------------------------
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

  Re-run this installer after upgrading node, ccusage, or the claude CLI.
  The absolute paths baked into the script will not follow a version bump.

  Remove everything:
    $SELF --user $TARGET_USER --uninstall
SUMMARY
  echo
}

main "$@"