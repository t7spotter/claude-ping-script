#!/usr/bin/env bash
#
# setup-claude-usage-ping.sh
#
# Installs a cron job that keeps a Claude Code 5-hour usage block warm: it
# checks the current active block via ccusage and, only if that block shows
# zero tokens, sends a minimal prompt to start the window.
#
# Each run picks a random prompt from a configurable list and sends it to the
# SAME conversation, resuming by session id so the pings accumulate in one
# thread instead of scattering across a new session every time.
#
# Re-running is the supported way to upgrade: the generated script is rewritten
# with freshly detected paths, while the stored session id, the prompt pool, the
# model and the cron schedule are read back off the existing install and kept.
#
# The point of this installer is that it DETECTS the environment instead of
# assuming it. Every path baked into the generated script is discovered on
# the target machine, then verified under a stripped environment (env -i)
# that reproduces cron's conditions.
#
# Install:
#   curl -fsSL https://raw.githubusercontent.com/USER/REPO/v1.2.0/setup-claude-usage-ping.sh | bash
#
# Or, preferably, download and read it first:
#   curl -fsSL -o setup.sh https://raw.githubusercontent.com/USER/REPO/v1.2.0/setup-claude-usage-ping.sh
#   less setup.sh && bash setup.sh --dry-run && bash setup.sh
#
# Requires: bash 4+, cron, node/npm, and an already-authenticated claude CLI.
#
# The entire body lives inside main(), invoked on the final line. That makes
# `curl | bash` safe against truncation: a partial download cannot execute
# anything, because the call to main() is the last thing to arrive.
#
set -euo pipefail

VERSION="1.2.0"
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

# Whether the user named these explicitly. An existing install only supplies a
# value for the ones they did not, so a flag always beats a carried-over value.
SCHEDULE_SET=0
MODEL_SET=0
IGNORE_EXISTING=0

# One of these is chosen at random on every run. Keep them short: each ping
# is billed, and every resumed run replays the conversation so far.
DEFAULT_PROMPTS=(
  "Hi"
  "Hello"
  "Hey"
  "Ping"
  "Howdy"
  "Good day"
  "Still there?"
  "Checking in"
)
PROMPTS=()          # populated by --prompt; falls back to DEFAULT_PROMPTS

SCRIPT_PATH=""
TARGET_USER="$(id -un)"
DRY_RUN=0
DO_CRON=1
DO_SMOKE=1
UNINSTALL=0
ASSUME_YES=0
NEW_SESSION_FLAG=0

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
usage block is idle. Each ping uses a randomly chosen prompt and resumes
the same conversation.

OPTIONS
  -u, --user USER       Install for USER (default: current user).
                        Must be the user that authenticated the claude CLI.
  -s, --schedule CRON   Cron schedule (default: "$SCHEDULE")
  -m, --model MODEL     Model used for the ping (default: $MODEL)
  -p, --prompt TEXT     Add TEXT to the pool of ping prompts. Repeatable;
                        one is picked at random per run. If omitted, a
                        built-in pool of ${#DEFAULT_PROMPTS[@]} short prompts is used.
      --path FILE       Where to write the generated script
                        (default: <home>/claude-usage-ping.sh)
      --new-session     Forget any stored session id, so the next run opens
                        a fresh conversation.
      --defaults        Ignore the existing install's settings and fall back
                        to this script's built-in defaults.
      --no-cron         Generate and test the script, but leave crontab alone
      --no-smoke-test   Skip the live end-to-end run (avoids one API call)
      --dry-run         Print planned actions; change nothing
      --uninstall       Remove the cron entry, the generated script, and the
                        stored session id
  -y, --yes             Never prompt for confirmation
  -h, --help            Show this message

RE-RUNNING
  Re-run this installer to pick up new binary paths after upgrading node,
  ccusage, or the claude CLI. Settings are carried over from the install it
  finds -- schedule (read from the crontab), prompt pool and model -- so a bare
  re-run is a safe in-place upgrade. Any flag you pass overrides the carried
  value; --defaults discards all of them. The stored session id is never
  touched except by --new-session or --uninstall.

SESSION REUSE
  The first ping starts a conversation; its session id is stored in
  <home>/.claude/usage-ping-session and passed to 'claude --resume' on every
  later run. If the resume fails (session pruned, id stale) the script logs a
  warning, opens a fresh session, and records the new id.

  Because a resumed session replays its whole history, the per-ping cost grows
  slowly over time. Run with --new-session periodically, or delete the session
  file, to start the thread over.

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
      -s|--schedule)   need_val "$@"; SCHEDULE="$2"; SCHEDULE_SET=1; shift 2 ;;
      -m|--model)      need_val "$@"; MODEL="$2"; MODEL_SET=1; shift 2 ;;
      -p|--prompt)     need_val "$@"; PROMPTS+=("$2"); shift 2 ;;
      --path)          need_val "$@"; SCRIPT_PATH="$2"; shift 2 ;;
      --new-session)   NEW_SESSION_FLAG=1; shift ;;
      --defaults)      IGNORE_EXISTING=1; shift ;;
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

# -------------------------------------------------------- settings carry-over ---
# A re-run exists to refresh detected paths, not to silently reset the user's
# configuration. Read back whatever the previous install chose and use it for
# every option the caller did not name explicitly.
carry_over_config() {
  if [ "$IGNORE_EXISTING" -eq 1 ]; then
    step "Reusing settings from the existing install"
    info "Skipped (--defaults): using built-in defaults"
    return 0
  fi
  [ -f "$SCRIPT_PATH" ] || return 0

  step "Reusing settings from the existing install"

  local prev_ver
  prev_ver="$(sed -n 's/^# Generated by setup-claude-usage-ping\.sh v\(.*\)$/\1/p' \
    "$SCRIPT_PATH" 2>/dev/null | head -1 || true)"
  [ -n "$prev_ver" ] && info "Found a script generated by v$prev_ver"

  # -- model ----------------------------------------------------------------
  if [ "$MODEL_SET" -eq 0 ]; then
    local m
    m="$(sed -n 's/^MODEL="\(.*\)"$/\1/p' "$SCRIPT_PATH" 2>/dev/null | head -1 || true)"
    if [ -n "$m" ] && [ "$m" != "$MODEL" ]; then
      MODEL="$m"
      ok "model:    $MODEL (kept)"
    fi
  fi

  # -- prompt pool ----------------------------------------------------------
  if [ "${#PROMPTS[@]}" -eq 0 ]; then
    local block
    block="$(sed -n '/^PROMPTS=(/,/^)/p' "$SCRIPT_PATH" 2>/dev/null || true)"
    if [ -n "$block" ]; then
      # These values were written by printf %q in a previous run of this same
      # installer, so re-reading them with eval round-trips exactly. The file
      # is mode 700 and owned by the target user.
      local -a old_prompts=()
      if eval "old_prompts=( $(printf '%s' "$block" | sed -e '1d' -e '$d') )" 2>/dev/null \
         && [ "${#old_prompts[@]}" -gt 0 ]; then
        PROMPTS=("${old_prompts[@]}")
        ok "prompts:  ${#PROMPTS[@]} kept: ${PROMPTS[*]}"
      else
        warn "Could not parse the existing PROMPTS array -- using defaults"
      fi
    elif grep -q '^PROMPT="' "$SCRIPT_PATH" 2>/dev/null; then
      # Pre-1.1.0 single-prompt layout. Carrying that one string over would
      # defeat the upgrade, so take the pool and say so.
      info "Old single-prompt install -- switching to the random pool"
      info "Pass -p to pin your own prompts instead"
    fi
  fi

  # -- schedule, read from the live crontab ---------------------------------
  if [ "$SCHEDULE_SET" -eq 0 ] && command -v crontab >/dev/null 2>&1; then
    local line sched f1 f2 f3 f4 f5 rest
    line="$("${AS_TARGET[@]}" crontab -l 2>/dev/null \
      | grep -F "$SCRIPT_PATH" | grep -v '^[[:space:]]*#' | head -1 || true)"
    if [ -n "$line" ]; then
      # Split in the shell rather than awk: no nested-quoting hazard, and it
      # handles both the 5-field form and @daily-style nicknames.
      case "$line" in
        @*) sched="${line%%[[:space:]]*}" ;;
        *)  read -r f1 f2 f3 f4 f5 rest <<<"$line"
            sched="$f1 $f2 $f3 $f4 $f5" ;;
      esac
      if [ -n "$sched" ] && [ "$sched" != "$SCHEDULE" ]; then
        SCHEDULE="$sched"
        ok "schedule: $SCHEDULE (kept from crontab)"
      fi
    fi
  fi

  # -- session --------------------------------------------------------------
  if [ -s "$SESSION_FILE" ]; then
    ok "session:  $(cat "$SESSION_FILE") (kept -- the conversation continues)"
  fi
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

  if [ -f "$SESSION_FILE" ]; then
    run rm -f "$SESSION_FILE"
    ok "Removed stored session id ($SESSION_FILE)"
  else
    info "No stored session id at $SESSION_FILE"
  fi

  info "Log left in place: $LOG_FILE"
  echo
}

# ------------------------------------------------------- script generation ----
write_script() {
  step "Writing $SCRIPT_PATH"

  TMP_SCRIPT="$(mktemp)"
  trap 'rm -f "${TMP_SCRIPT:-}"' EXIT

  # Shell-quote every prompt now, so arbitrary text (quotes, spaces, $) lands
  # in the generated array as an inert literal.
  local p quoted_prompts
  quoted_prompts="$(for p in "${PROMPTS[@]}"; do printf '  %q\n' "$p"; done)"

  # Config block: expanded now, so detected paths are baked in literally.
  cat > "$TMP_SCRIPT" <<CONFIG
#!/usr/bin/env bash
#
# claude-usage-ping.sh
# Generated by setup-claude-usage-ping.sh v$VERSION
# on $(date '+%Y-%m-%d %H:%M:%S') for user $TARGET_USER
#
# Checks the active Claude Code 5-hour block and sends a minimal prompt only
# if that block is idle. The prompt is drawn at random from PROMPTS below and
# sent to the session recorded in SESSION_FILE, so every ping lands in one
# ongoing conversation. Every path below was detected at install time --
# re-run the installer after upgrading node, ccusage, or the claude CLI.
#
set -euo pipefail

export HOME="\${HOME:-$TARGET_HOME}"
export PATH="$PINNED_PATH"

CLAUDE_BIN="$CLAUDE_BIN"
CCUSAGE_BIN="$CCUSAGE_BIN"
JQ_BIN="$JQ_BIN"

MODEL="$MODEL"

# One is picked at random per run.
PROMPTS=(
$quoted_prompts
)

LOG_FILE="\$HOME/.claude/usage-ping.log"
SESSION_FILE="\$HOME/.claude/usage-ping-session"
MAX_LOG_BYTES=1048576

TOKEN_EXPR='$TOKEN_EXPR'
CONFIG

  # Body: quoted heredoc, so nothing expands at generation time.
  cat >> "$TMP_SCRIPT" <<'BODY'

# claude resolves --resume ids against the project directory derived from the
# working directory. cron's cwd is not guaranteed, so pin it: a run started
# from elsewhere would fail to find the session and silently fork a new one.
cd "$HOME" || exit 1

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

if [ "${#PROMPTS[@]}" -eq 0 ]; then
  log "FATAL: PROMPTS is empty - re-run the installer"
  exit 1
fi

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

if [ "$TOKENS_USED" -ne 0 ]; then
  log "Already active ($TOKENS_USED tokens) - skipping ping"
  exit 0
fi

# $RANDOM is uniform enough for picking a greeting; it needs no seeding.
PROMPT="${PROMPTS[RANDOM % ${#PROMPTS[@]}]}"

# A stored id from a previous run; empty on the very first one.
SESSION_ID=""
if [ -s "$SESSION_FILE" ]; then
  SESSION_ID="$(tr -d '[:space:]' < "$SESSION_FILE")"
fi

send_ping() {  # send_ping [SESSION_ID] -> response JSON on stdout
  if [ -n "${1:-}" ]; then
    "$CLAUDE_BIN" -p "$PROMPT" --model "$MODEL" --output-format json --resume "$1"
  else
    "$CLAUDE_BIN" -p "$PROMPT" --model "$MODEL" --output-format json
  fi
}

PING_OUTPUT=""

if [ -n "$SESSION_ID" ]; then
  log "Block idle - resuming session $SESSION_ID (prompt: $PROMPT)"
  if ! PING_OUTPUT="$(send_ping "$SESSION_ID" 2>>"$LOG_FILE")"; then
    # A pruned or otherwise stale id must not wedge the job forever.
    log "WARN: resume of $SESSION_ID failed - falling back to a new session"
    SESSION_ID=""
  fi
else
  log "Block idle - starting a new session (prompt: $PROMPT)"
fi

if [ -z "$SESSION_ID" ]; then
  if ! PING_OUTPUT="$(send_ping "" 2>>"$LOG_FILE")"; then
    log "Ping FAILED: $PING_OUTPUT"
    exit 1
  fi
fi

RETURNED_SESSION="$(printf '%s' "$PING_OUTPUT" \
  | "$JQ_BIN" -r '.session_id // empty' 2>/dev/null || true)"

if [ -n "$RETURNED_SESSION" ]; then
  # Write back unconditionally: some versions hand out a new id on resume.
  printf '%s\n' "$RETURNED_SESSION" > "$SESSION_FILE"
  chmod 600 "$SESSION_FILE" 2>/dev/null || true
  log "Ping OK (session: $RETURNED_SESSION)"
else
  log "WARN: ping OK but no session_id in the response - next run starts fresh"
fi
BODY

  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] would write $SCRIPT_PATH ($(wc -l < "$TMP_SCRIPT") lines)"
    info "[dry-run] prompt pool (${#PROMPTS[@]}): ${PROMPTS[*]}"
    return 0
  fi

  bash -n "$TMP_SCRIPT" || die "Generated script failed its syntax check (installer bug)."
  install -m 700 -o "$TARGET_USER" "$TMP_SCRIPT" "$SCRIPT_PATH" 2>/dev/null \
    || { cp "$TMP_SCRIPT" "$SCRIPT_PATH"; chmod 700 "$SCRIPT_PATH"; }
  ok "Written and syntax-checked ($(wc -l < "$SCRIPT_PATH") lines)"
  ok "Prompt pool (${#PROMPTS[@]}): ${PROMPTS[*]}"
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

  if [ -s "$SESSION_FILE" ]; then
    ok "Session id recorded: $(cat "$SESSION_FILE")"
  else
    info "No session id recorded yet (block was already active, or the ping was skipped)"
  fi

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
  SESSION_FILE="$TARGET_HOME/.claude/usage-ping-session"

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

  # Reinstalling should not silently inherit an old thread if asked otherwise.
  if [ "$NEW_SESSION_FLAG" -eq 1 ]; then
    step "Resetting session"
    if [ -f "$SESSION_FILE" ]; then
      run rm -f "$SESSION_FILE"
      ok "Cleared $SESSION_FILE -- the next ping opens a fresh conversation"
    else
      info "No session id stored; the next ping starts fresh anyway"
    fi
  fi

  carry_over_config

  # Anything still unset falls back to the built-in pool.
  if [ "${#PROMPTS[@]}" -eq 0 ]; then
    PROMPTS=("${DEFAULT_PROMPTS[@]}")
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
  Session   $SESSION_FILE
  Schedule  $SCHEDULE
  User      $TARGET_USER
  Prompts   ${#PROMPTS[@]} (random pick per run): ${PROMPTS[*]}
  PATH      $PINNED_PATH

  Verify the next scheduled run:
    tail -f $LOG_FILE
    crontab -l -u $TARGET_USER
    grep CRON /var/log/syslog | tail -5      # or: journalctl -u cron -n 20

  Every ping resumes the session id in $SESSION_FILE. To start a fresh
  conversation (worth doing occasionally -- a resumed session replays its
  whole history, so the per-ping cost creeps up):
    rm -f $SESSION_FILE
    # or: $SELF --new-session --no-cron --no-smoke-test

  Re-run this installer after upgrading node, ccusage, or the claude CLI.
  The absolute paths baked into the script will not follow a version bump.
  A bare re-run keeps the schedule, prompts, model and session above;
  pass --defaults to discard them.

  Remove everything:
    $SELF --user $TARGET_USER --uninstall
SUMMARY
  echo
}

main "$@"
