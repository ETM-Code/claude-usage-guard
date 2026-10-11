# Set up claude-usage-guard

Instructions for a coding agent. `usage-guard` stops a Claude Code session when the user's account usage reaches a limit they choose. Limits are per session by default, so one session's limit does not stop the user's other sessions. Do these steps in order. Every step is safe to re-run. Do not edit `settings.json` by hand.

## 1. Prerequisites

Run `command -v jq`. If it prints nothing, install jq and check again:

- macOS: `brew install jq`
- Debian/Ubuntu: `sudo apt install jq`
- Fedora: `sudo dnf install jq`
- Other: https://jqlang.github.io/jq/download/

## 2. Install

```bash
curl -fsSL https://raw.githubusercontent.com/ETM-Code/claude-usage-guard/main/install.sh | bash
```

This puts `usage-guard` in `~/.local/bin` and adds its status line and hooks to `settings.json`, keeping a backup. If it says `~/.local/bin` is not on PATH, use `~/.local/bin/usage-guard` in the steps below and tell the user to add that directory to PATH.

## 3. Ask the user

Ask these and wait for the answers:

1. Should the limit apply to this session only (the normal case), or be a global default for every session that has no limit of its own? Per-session is the normal case; global is for someone who wants a ceiling everywhere.
2. Which window should the guard watch: weekly or 5-hour?
3. At what percentage of that window should work stop?
4. How many points before the limit should the wind-down start? (The model is told to finish up, and new subagents are refused. The default is 2.)
5. Soft or strict? Soft is the normal choice: at the limit Claude is told to stop and wait, and the user can say "carry on" or "raise the limit to 70" and Claude changes it, which works from a phone. Strict hard-blocks every tool call and prompt at the limit, so lifting it needs a shell.

Do not suggest, assume or fill in a number for question 3. If the user does not give one, ask again. If they skip question 4, leave out `--wind-down`. If they skip question 5, use soft (no flag).

## 4. Set the limit

You are running inside a Claude Code session, so a plain `set` limits this session:

```bash
usage-guard set <LIMIT> --window <weekly|5h> [--wind-down <N>] [--strict]
```

For a global default (every session without its own limit), add `--global`. Do not set both unless the user asked for both.

## 5. Check

Run `usage-guard doctor`. Fix anything marked `FAIL` and run it again until there are none.

A `warn` saying there is no reading yet is expected right after install. The first reading is recorded when an interactive `claude` session renders its status line.

## 6. Add the guidance to CLAUDE.md

Run this exactly. It adds the snippet only if it is not there already:

<!-- append-snippet-start -->
```bash
f="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/CLAUDE.md"
mkdir -p "$(dirname "$f")"
grep -qs '<!-- usage-guard -->' "$f" || cat >>"$f" <<'SNIPPET'

<!-- usage-guard -->
## Usage guard
A usage guard may stop this session when account usage reaches its limit. When you see a "USAGE GUARD (wind-down)" message, finish the current unit of work, commit or save state, write a short handoff note (done / next), start no new subagents or long-running work, and stop. When you see "USAGE GUARD (limit reached)", obey it: stop working, save state, tell the user the limit is reached and wait. Carry on only if the user explicitly says to, or asks you to change the limit; then run `usage-guard set <new>` (or `usage-guard off`) as they ask, which is fine. If the guard blocks a tool call or a prompt, do not work around it; tell the user and wait. When the user says "stop this session at N%", run `usage-guard set N` in this session (add `--window 5h` for the 5-hour window, `--strict` to block instead of ask); `usage-guard clear` removes it. Do not run `usage-guard off`, `set` or `clear` on your own initiative.
SNIPPET
```
<!-- append-snippet-end -->

## 7. Tell the user

Show the output of `usage-guard status`, then tell the user:

- the limit, window and wind-down that are now set, and whether it applies to this session only or globally, and whether it is soft or strict
- that it starts working once an interactive `claude` session has rendered its status line, so they should start or restart one (readings exist only on Pro and Max plans, and never in `claude -p`)
- that at a soft limit they can just tell you "carry on" or "raise the limit to <N>" and you will run `usage-guard set <N>`; that the same `usage-guard set <pct>` works in any other session to limit that one, `usage-guard off` / `on` pauses and resumes the current session, `usage-guard clear` removes its limit, `usage-guard set <higher>` lifts a stop, and `usage-guard uninstall` removes everything and restores their previous status line
