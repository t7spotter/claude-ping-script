# claude-ping-script

Keeps a Claude Code 5-hour usage block warm. A cron job checks whether the
current block is idle and, only if it is, sends one minimal prompt to open
the window.

Each ping picks a prompt at random from a configurable pool and sends it to
the **same** conversation, resuming by session id, so the pings accumulate in
one thread instead of scattering a new session across your history every run.

The installer **detects** your environment rather than assuming it. Paths to
`claude`, `ccusage`, `jq`, and `node` are discovered on the target machine
and baked in as absolute paths, then the result is verified under a stripped
environment that reproduces cron's conditions.

---

## Before you install

**1. Claude Code must already be authenticated.** Run it once interactively,
as the same user the cron job will run as:

```bash
claude
```

Cron cannot complete a login flow. If you authenticate as `root` but install
the job for `ali`, it will fail — the credentials live in `~/.claude/`.

**2. This job consumes quota.** It sends a real prompt on a schedule. The
ping uses Haiku and is a few words, so the cost is small, but it is not
zero — and because each run resumes the same session, the conversation
replays its history, so the per-ping cost creeps up over time. See
[Session reuse](#session-reuse). Run `--dry-run` first if that matters to you.

**3. Requirements:** Linux or macOS, `bash` 4+, `cron`, `node`/`npm`. The
installer installs `jq` and `ccusage` if they are missing.

---

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/t7spotter/claude-ping-script/v1.2.0/setup-claude-usage-ping.sh | bash
```

Preview without changing anything:

```bash
curl -fsSL https://raw.githubusercontent.com/t7spotter/claude-ping-script/v1.2.0/setup-claude-usage-ping.sh | bash -s -- --dry-run
```

### Preferred: read it before you run it

Piping a script straight into a shell executes code you have not read. The
installer is wrapped so a truncated download cannot execute anything, but
downloading first is still better practice:

```bash
curl -fsSL -o setup.sh https://raw.githubusercontent.com/t7spotter/claude-ping-script/v1.2.0/setup-claude-usage-ping.sh
less setup.sh
chmod +x setup.sh
./setup.sh --dry-run
./setup.sh
```

Pin to a tag rather than `main` so you always install a known version.

> Piped installs are **non-interactive**: stdin is the pipe, so the
> confirmation prompt is skipped and the cron entry is installed without
> asking. Use `--dry-run` or `--no-cron` if you want to inspect first.

---

## Options

| Flag | Description | Default |
|---|---|---|
| `-u, --user USER` | Install for another user (requires root) | current user |
| `-s, --schedule CRON` | Cron schedule | `0 0,5,9,14,19 * * *` |
| `-m, --model MODEL` | Model used for the ping | `haiku` |
| `-p, --prompt TEXT` | Add TEXT to the prompt pool. **Repeatable**; one is picked at random per run | 8 built-in prompts |
| `--path FILE` | Where to write the generated script | `<home>/claude-usage-ping.sh` |
| `--new-session` | Forget the stored session id; the next ping opens a fresh conversation | — |
| `--defaults` | Ignore the existing install's settings, use built-in defaults | — |
| `--no-cron` | Generate and test, but leave crontab alone | — |
| `--no-smoke-test` | Skip the live run (avoids one API call) | — |
| `--dry-run` | Print planned actions, change nothing | — |
| `--uninstall` | Remove the cron entry, the script, and the stored session id | — |
| `-y, --yes` | Never prompt | — |
| `-h, --help` | Show help | — |

Examples:

```bash
./setup.sh --schedule "0 */4 * * *"              # every 4 hours
./setup.sh --user ali                            # install for another user
./setup.sh --no-cron                             # generate the script only
./setup.sh -p "Yo" -p "Still there?" -p "Ping"   # pin your own prompt pool
./setup.sh --new-session                         # start the conversation over
```

---

## Random prompts

The default pool is eight short greetings: `Hi`, `Hello`, `Hey`, `Ping`,
`Howdy`, `Good day`, `Still there?`, `Checking in`. One is chosen per run.

Pass `-p` one or more times to replace the pool entirely:

```bash
./setup.sh -p "Yo" -p "What's up?"
```

Prompts are shell-quoted with `printf %q` when they are baked into the
generated script, so quotes, spaces, `$`, and backslashes are safe and are
passed to `claude` as a single literal argument.

Keep them short. Every prompt is billed, and it is replayed on every
subsequent resume.

---

## Session reuse

The first ping starts a conversation and its session id is written to
`~/.claude/usage-ping-session` (mode 600). Every later run passes
`--resume <id>`, so all pings land in one ongoing thread.

If the resume fails — a pruned or stale id — the script logs a warning,
retries once without `--resume`, and records the new id. A bad id cannot
wedge the job permanently.

**The trade-off:** a resumed session replays its whole history, so the
per-ping cost grows linearly with the number of pings. At Haiku with a few
short pings a day it stays cheap for months, but it is not flat. Start a
fresh thread occasionally:

```bash
rm -f ~/.claude/usage-ping-session
# or
./setup.sh --new-session --no-cron --no-smoke-test
```

The generated script also runs `cd "$HOME"` before anything else. `claude`
resolves `--resume` ids against the project directory derived from the
working directory, and cron's cwd is not guaranteed to match the one the
installer ran from — without pinning it, every run would silently fork a new
session instead of resuming.

---

## Re-running the installer

Re-running is the supported way to upgrade, and it is safe. It rewrites the
generated script with freshly detected paths and replaces the cron entry
rather than duplicating it; unrelated jobs are left untouched.

Settings are **carried over** from the install it finds, so a bare re-run
does not silently reset your configuration:

| | On a bare re-run |
|---|---|
| Generated script | rewritten with freshly detected paths |
| Schedule | kept (read back from the crontab) |
| Prompt pool | kept (read back from the generated script) |
| Model | kept |
| Session id | untouched — the conversation continues |
| Cron entry | replaced, never duplicated |

Any flag you pass overrides the carried value. `--defaults` discards all of
them and returns to the built-in defaults. Only `--new-session` and
`--uninstall` touch the stored session id.

Upgrading from a pre-1.1.0 install is handled: the old single `PROMPT="Hi"`
is not carried over, since that would defeat the point of the random pool.
Pass `-p` if you want to pin your own prompts instead.

---

## What it installs

Three things:

- `~/claude-usage-ping.sh` — the generated worker script
- `~/.claude/usage-ping-session` — the stored session id (created by the
  first successful ping, not by the installer)
- one crontab entry, marked with a comment so it can be found and replaced

Logs go to `~/.claude/usage-ping.log`, rotated at 1 MB.

A run where the block is already active:

```
2026-09-01 05:00:01 Active-block tokens: 814505
2026-09-01 05:00:01 Already active (814505 tokens) - skipping ping
```

The first idle run, opening the conversation:

```
2026-09-01 10:00:02 Active-block tokens: 0
2026-09-01 10:00:02 Block idle - starting a new session (prompt: Good day)
2026-09-01 10:00:05 Ping OK (session: 8632259d-543b-461a-8ffd-d805e5af72d6)
```

Every idle run after that, resuming it:

```
2026-09-01 15:00:01 Active-block tokens: 0
2026-09-01 15:00:01 Block idle - resuming session 8632259d-543b-461a-8ffd-d805e5af72d6 (prompt: Still there?)
2026-09-01 15:00:04 Ping OK (session: 8632259d-543b-461a-8ffd-d805e5af72d6)
```

---

## Verify

```bash
tail -f ~/.claude/usage-ping.log
crontab -l
cat ~/.claude/usage-ping-session          # the thread being resumed
grep CRON /var/log/syslog | tail -5       # or: journalctl -u cron -n 20
```

To confirm the ping branch actually works — not just the skip branch —
look for a successful ping after an idle period:

```bash
grep "Ping OK" ~/.claude/usage-ping.log
```

To confirm sessions are actually being reused rather than re-created, every
`Ping OK` after the first should carry the same id:

```bash
grep -o 'session: .*' ~/.claude/usage-ping.log | sort | uniq -c
```

---

## Uninstall

```bash
./setup.sh --uninstall
```

Removes the cron entry, the generated script, and the stored session id. The
log is left in place.

---

## Troubleshooting

### `command not found` in the log

Cron runs with a minimal `PATH` — typically just `/usr/bin:/bin`. It does not
read `.bashrc` or `.zshrc`, so anything installed under `~/.local/bin`,
`/opt/nodejs/bin`, or an nvm version directory is invisible to it.

This is why the installer pins absolute paths instead of relying on `PATH`
lookup. If you see this error, a tool has moved — re-run the installer.

Reproduce cron's environment yourself:

```bash
env -i HOME="$HOME" /bin/bash ~/claude-usage-ping.sh
```

If it works there, it will work under cron.

### It pings every time even though I have been using Claude Code

The token count is not being parsed. Check what `ccusage` actually returns:

```bash
ccusage blocks --active --json | jq 'keys'
ccusage blocks --active --json | jq '.blocks[0] | keys'
```

The schema has changed between versions — `{"data": [...]}` became
`{"blocks": [...]}`. A wrong key yields `0` silently, which reads as "idle"
and triggers a ping on every run. The installer probes this at install time
and prints the keys it finds; the generated script tolerates both layouts.

### Every run says "starting a new session"

The session id is not surviving between runs. Check the file exists and is
non-empty:

```bash
ls -l ~/.claude/usage-ping-session
```

If it is missing, no ping has succeeded yet — the block may have been active
every time the job fired. If it exists but the log still shows a new session
each run, look for a `WARN: resume of ... failed` line: the id is being
rejected, and the script is correctly falling back rather than giving up.

### `WARN: resume of <id> failed`

The stored session was pruned or is otherwise unusable. The script recovers
on its own by opening a fresh one and recording the new id — no action
needed. If it happens on every run, clear the file and let it start clean:

```bash
rm -f ~/.claude/usage-ping-session
```

### `FATAL: ... missing or not executable`

A pinned binary has moved. Most often this follows a node upgrade under
nvm, which changes the version directory and relocates globally installed
packages like `ccusage`. Re-run the installer.

### Auth errors

Confirm credentials exist for the user running the job:

```bash
ls -l ~/.claude/.credentials.json
```

If missing, run `claude` interactively as that user, complete the login,
then re-run the installer. A `root` crontab cannot use `ali`'s credentials.

### Cron is not firing at all

```bash
systemctl status cron
grep CRON /var/log/syslog | tail -20
```

Check you edited the right crontab — `crontab -e` as root edits root's, not
your user's. Also check the timezone with `timedatectl`; cron uses system
time, which on a VPS is often UTC.

### The script has CRLF line endings

If it was ever opened in a Windows editor:

```bash
file ~/claude-usage-ping.sh    # look for "CRLF line terminators"
dos2unix ~/claude-usage-ping.sh
```

---

## How it works

1. Resolve the target user and home directory.
2. Read back the settings of any existing install — schedule from the
   crontab, prompt pool and model from the generated script — so a re-run
   upgrades in place instead of resetting configuration.
3. Search for `claude`, `ccusage`, `jq`, and `node` across the login `PATH`
   plus `~/.local/bin`, `/opt/nodejs/bin`, npm's global prefix, and
   nvm/fnm/volta version directories.
4. Install `jq` and `ccusage` if absent. `ccusage` is installed globally
   rather than invoked through `npx --yes ccusage@latest`, which would mean
   a network round-trip and a package re-resolution on every single run.
5. Probe `ccusage blocks --active --json` and report the schema.
6. Write the worker script with absolute paths, a shell-quoted prompt pool,
   and a pinned `PATH` — with no `:$PATH` suffix, so it behaves identically
   in a terminal and under cron.
7. Run it under `env -i` and abort if anything fails.
8. Install the cron entry idempotently.

The generated script also carries an `ERR` trap that logs the failing line
number, a `flock` guard against overlapping runs, a preflight check that
fails loudly on run #1 rather than silently on run #12, a numeric guard so a
`null` from `jq` cannot kill it under `set -e`, and a `--resume` fallback so
a stale session id cannot wedge the job.

---

## License

MIT
