# claude-ping-script

Keeps a Claude Code 5-hour usage block warm. A cron job checks whether the
current block is idle and, only if it is, sends one minimal prompt to open
the window.

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
ping uses Haiku and is a single word, so the cost is small, but it is not
zero. Run `--dry-run` first if that matters to you.

**3. Requirements:** Linux or macOS, `bash` 4+, `cron`, `node`/`npm`. The
installer installs `jq` and `ccusage` if they are missing.

---

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/t7spotter/claude-ping-script/v1.0.1/setup-claude-usage-ping.sh | bash
```

Preview without changing anything:

```bash
curl -fsSL https://raw.githubusercontent.com/t7spotter/claude-ping-script/v1.0.1/setup-claude-usage-ping.sh | bash -s -- --dry-run
```

### Preferred: read it before you run it

Piping a script straight into a shell executes code you have not read. The
installer is wrapped so a truncated download cannot execute anything, but
downloading first is still better practice:

```bash
curl -fsSL -o setup.sh https://raw.githubusercontent.com/t7spotter/claude-ping-script/v1.0.1/setup-claude-usage-ping.sh
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
| `-s, --schedule CRON` | Cron schedule | `0 */5 * * *` |
| `-m, --model MODEL` | Model used for the ping | `haiku` |
| `-p, --prompt TEXT` | Ping prompt | `Hi` |
| `--path FILE` | Where to write the generated script | `<home>/claude-usage-ping.sh` |
| `--no-cron` | Generate and test, but leave crontab alone | — |
| `--no-smoke-test` | Skip the live run (avoids one API call) | — |
| `--dry-run` | Print planned actions, change nothing | — |
| `--uninstall` | Remove the cron entry and the script | — |
| `-y, --yes` | Never prompt | — |
| `-h, --help` | Show help | — |

Examples:

```bash
./setup.sh --schedule "0 */4 * * *"        # every 4 hours
./setup.sh --user ali                      # install for another user
./setup.sh --no-cron                       # generate the script only
```

Re-running is safe. The cron entry is replaced, not duplicated, and
unrelated jobs are left untouched.

---

## What it installs

Two things:

- `~/claude-usage-ping.sh` — the generated worker script
- one crontab entry, marked with a comment so it can be found and replaced

Logs go to `~/.claude/usage-ping.log`, rotated at 1 MB.

A run looks like this:

```
2026-08-26 13:40:45 Active-block tokens: 27076
2026-08-26 13:40:45 Already active (27076 tokens) - skipping ping
```

or, when the block is idle:

```
2026-08-26 15:00:01 Active-block tokens: 0
2026-08-26 15:00:01 Block idle - sending ping
2026-08-26 15:00:04 Ping OK (session: ae691df3-8b2d-49cc-8b5c-3cea52207073)
```

---

## Verify

```bash
tail -f ~/.claude/usage-ping.log
crontab -l
grep CRON /var/log/syslog | tail -5      # or: journalctl -u cron -n 20
```

To confirm the ping branch actually works — not just the skip branch —
look for a successful ping after an idle period:

```bash
grep "Ping OK" ~/.claude/usage-ping.log
```

---

## Uninstall

```bash
./setup.sh --uninstall
```

Removes the cron entry and the generated script. The log is left in place.

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
2. Search for `claude`, `ccusage`, `jq`, and `node` across the login `PATH`
   plus `~/.local/bin`, `/opt/nodejs/bin`, npm's global prefix, and
   nvm/fnm/volta version directories.
3. Install `jq` and `ccusage` if absent. `ccusage` is installed globally
   rather than invoked through `npx --yes ccusage@latest`, which would mean
   a network round-trip and a package re-resolution on every single run.
4. Probe `ccusage blocks --active --json` and report the schema.
5. Write the worker script with absolute paths and a pinned `PATH` — with no
   `:$PATH` suffix, so it behaves identically in a terminal and under cron.
6. Run it under `env -i` and abort if anything fails.
7. Install the cron entry idempotently.

The generated script also carries an `ERR` trap that logs the failing line
number, a `flock` guard against overlapping runs, a preflight check that
fails loudly on run #1 rather than silently on run #12, and a numeric guard
so a `null` from `jq` cannot kill it under `set -e`.

---

## License

MIT