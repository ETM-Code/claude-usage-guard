# Set up claude-usage-guard

Instructions for a coding agent. `usage-guard` stops Claude Code when the user's account usage reaches a limit they choose. Do these steps in order. Every step is safe to re-run. Do not edit `settings.json` by hand.

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

1. Which window should the guard watch: weekly or 5-hour?
2. At what percentage of that window should work stop?
3. How many points before the limit should the wind-down start? (The model is told to finish up, and new subagents are refused. The default is 2.)

Do not suggest, assume or fill in a number for question 2. If the user does not give one, ask again. If they skip question 3, leave out `--wind-down`.

## 4. Set the limit

```bash
usage-guard set <LIMIT> --window <weekly|5h> [--wind-down <N>]
```

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
A usage guard may stop this session when account usage reaches a limit. When you see a "USAGE GUARD (wind-down)" message, finish the current unit of work, commit or save state, write a short handoff note (done / next), start no new subagents or long-running work, and stop. If the guard stops a tool call or a prompt, do not work around it; tell the user and wait. Do not run `usage-guard off` or `usage-guard set` unless the user asks.
SNIPPET
```
<!-- append-snippet-end -->

## 7. Tell the user

Show the output of `usage-guard status`, then tell the user:

- the limit, window and wind-down that are now set
- that it starts working once an interactive `claude` session has rendered its status line, so they should start or restart one (readings exist only on Pro and Max plans, and never in `claude -p`)
- that `usage-guard off` / `on` pauses and resumes it, `usage-guard set <higher>` lifts a stop, and `usage-guard uninstall` removes it and restores their previous status line
