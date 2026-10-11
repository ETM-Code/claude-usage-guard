# claude-usage-guard

Stop Claude Code at a usage limit you choose, so one long session can't use up your week.

Claude Pro and Max plans have a weekly and a 5-hour usage limit, and Claude Code shows how much of each you have used. usage-guard watches that number. A couple of points before your limit it tells the model to finish what it is doing, commit and write a handoff note. At the limit it stops tool calls and new prompts, subagents included, until you raise the limit or turn the guard off.

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/ETM-Code/claude-usage-guard/main/install.sh | bash
usage-guard set 80    # example: stop at 80% of the weekly limit. Pick your own number.
```

Needs `bash` and `jq`. Nothing is enforced until you set a limit.

## Or let your agent do it

Paste this into Claude Code:

```
Set up claude-usage-guard by following https://raw.githubusercontent.com/ETM-Code/claude-usage-guard/main/AGENT_SETUP.md
```

It installs the tool, asks you which window and limit you want, and checks the setup.

## How it works

Claude Code passes usage figures (`rate_limits`) to the status line command but not to hooks. `usage-guard install` wraps your status line so each render saves the latest reading to `~/.claude/usage-guard/usage.json` and appends a short segment such as `week 34%/80`. Your own status line still runs, and uninstall puts it back. It also adds `SessionStart`, `UserPromptSubmit` and `PreToolUse` hooks that compare the reading with your limit:

| Usage | What happens |
| --- | --- |
| below the wind-down band | nothing |
| in the wind-down band (default: the 2 points below the limit) | once per whole percent, the model is told to finish the current work, commit or save state and write a handoff note; new `Agent` and `Workflow` calls are refused |
| at or above the limit | tool calls are stopped (`continue: false`) and new prompts are blocked |

If the reading is more than 15 minutes old, the guard enforces nothing and tells the session once that it is blind.

## Commands

| Command | What it does |
| --- | --- |
| `usage-guard set <pct>` | set the limit and turn the guard on |
| `usage-guard set <pct> --window 5h` | watch the 5-hour window instead of the weekly one |
| `usage-guard set <pct> --wind-down <n>` | start the wind-down `n` points before the limit (default 2) |
| `usage-guard off` / `on` | pause or resume the guard |
| `usage-guard status` | show the limit, the latest reading and the current band |
| `usage-guard doctor` | check the setup |
| `usage-guard install` / `uninstall` | add to or remove from `settings.json` (a backup is made first) |

To carry on after a stop, run `usage-guard set <higher>` or `usage-guard off`.

## Uninstall

```bash
usage-guard uninstall --purge     # restore settings.json and delete ~/.claude/usage-guard
rm "$(command -v usage-guard)"
```

Without `--purge`, your limit is kept for a later reinstall.

## Limitations

- Subscribers only. Claude Code sends usage figures to the status line only on Pro and Max plans.
- A reading exists only after the status line has rendered in an interactive session.
- `claude -p` never renders the status line, so it records no reading. It uses the last one if that is under 15 minutes old.
- Readings refresh about every 60 seconds, so the stop can land a little past the limit. A tool call that is already running is not interrupted.

## Tell Claude about it

The agent setup adds this to `~/.claude/CLAUDE.md`. If you installed by hand, you can add it yourself:

```markdown
<!-- usage-guard -->
## Usage guard
A usage guard may stop this session when account usage reaches a limit. When you see a "USAGE GUARD (wind-down)" message, finish the current unit of work, commit or save state, write a short handoff note (done / next), start no new subagents or long-running work, and stop. If the guard stops a tool call or a prompt, do not work around it; tell the user and wait. Do not run `usage-guard off` or `usage-guard set` unless the user asks.
```

`CLAUDE_CONFIG_DIR` is respected in place of `~/.claude`.

## License

MIT
