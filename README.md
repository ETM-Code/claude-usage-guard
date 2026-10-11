# claude-usage-guard

Stop a Claude Code session at a usage limit you choose, so one long session can't use up your week. Limits are per session: stopping one session leaves your other sessions running.

Claude Pro and Max plans have a weekly and a 5-hour usage limit, and Claude Code shows how much of each you have used. usage-guard watches that number. A couple of points before a session's limit it tells the model to finish what it is doing, commit and write a handoff note. At the limit it tells the model to stop, save state and wait, and refuses new subagents. You can then tell Claude "carry on" or "raise the limit to 70" from anywhere, a phone included, and Claude runs `usage-guard set 70` for you. If you would rather have a hard stop, add `--strict` (see [Soft and strict](#soft-and-strict)).

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/ETM-Code/claude-usage-guard/main/install.sh | bash
usage-guard set 80             # inside a Claude Code session (or tell Claude "stop this session at 80%"): this session only
usage-guard set 80 --global    # from a normal terminal: a default for every session with no limit of its own
```

80 is an example; pick your own number. Needs `bash` and `jq`. Nothing is enforced until a limit is set.

## Or let your agent do it

Paste this into Claude Code:

```
Set up claude-usage-guard by following https://raw.githubusercontent.com/ETM-Code/claude-usage-guard/main/AGENT_SETUP.md
```

It installs the tool, asks whether you want a per-session or a global limit, which window and what percentage, and checks the setup.

## How it works

Claude Code passes usage figures (`rate_limits`) to the status line command but not to hooks. `usage-guard install` wraps your status line so each render saves the latest reading to `~/.claude/usage-guard/usage.json` and appends a short segment such as `week 34%/80`. Your own status line still runs, and uninstall puts it back. It also adds `SessionStart`, `UserPromptSubmit` and `PreToolUse` hooks that compare the reading with the limit of the session the hook fires in. Each hook gets that session's `session_id`, and each Bash command in a session has the same value in `CLAUDE_CODE_SESSION_ID`, which is how `usage-guard set` knows which session you mean. A session's limit lives in `~/.claude/usage-guard/sessions/<session_id>.json`. The limit a hook uses is the session's own, else the global one, else none (the hook does nothing):

| Usage | What happens |
| --- | --- |
| below the wind-down band | nothing |
| in the wind-down band (default: the 2 points below the limit) | once per whole percent, the model is told to finish the current work, commit or save state and write a handoff note; new `Agent` and `Workflow` calls are refused |
| at or above the limit | soft (default): the model is told to stop, save state and wait; new `Agent` and `Workflow` calls are refused; nothing else is blocked. Strict: tool calls are stopped (`continue: false`) and new prompts are blocked |

### Soft and strict

Each limit has a mode, stored with it (per session or global). `usage-guard set 60` makes a soft limit; `usage-guard set 60 --strict` makes a hard one; `--soft` switches back. A later `set` without a flag keeps the mode, and a session without its own mode uses the global one.

- **Soft** (the normal choice) never blocks or stops anything except new subagent and workflow calls. At the limit the model gets "USAGE GUARD (limit reached)" on every prompt and on session start, and on tool calls once, then again every 10 tool calls and at each further whole percent. The text tells it to stop, commit or save state, write a handoff note, tell you the limit is reached and wait, and to continue only if you say so or ask for a new limit. Subagents are told to save state, write a status note and finish. It relies on the model obeying, so it needs the [CLAUDE.md snippet](#tell-claude-about-it).
- **Strict** is the hard stop: at the limit every tool call is stopped and every new prompt blocked, whatever the model does. Lifting it needs a shell you can reach yourself: `usage-guard set <higher>` or `usage-guard off` from a terminal, since Claude's own tool calls are blocked.

If the reading is more than 15 minutes old, the guard enforces nothing and tells the session once that it is blind.

## Commands

| Command | What it does |
| --- | --- |
| `usage-guard set <pct>` | limit the current session and turn its guard on. Outside a session it fails unless you add `--session <id>` or `--global` |
| `usage-guard set <pct> --window 5h` | watch the 5-hour window instead of the weekly one (a session without `--window` uses the global window, weekly by default) |
| `usage-guard set <pct> --wind-down <n>` | start the wind-down `n` points before the limit (default 2) |
| `usage-guard set <pct> --strict` | hard stop at the limit instead of the default soft mode (`--soft` goes back) |
| `usage-guard set <pct> --global` | default limit for every session that has none of its own. There is none out of the box |
| `usage-guard off` / `on` | pause or resume the guard for the current session (or `--global`) |
| `usage-guard clear` | remove the current session's limit, so it follows the global one again |
| `usage-guard status` | in a session: its effective limit, mode and whether it comes from the session or the global setting. Outside one: the global setting and the sessions that have a limit (id prefix, limit, last seen) |
| `usage-guard doctor` | check the setup |
| `usage-guard install` / `uninstall` | add to or remove from `settings.json` (a backup is made first) |

`--session <id>` works on another session, and a unique prefix of a session shown by `status` is enough. To carry on after the limit, run `usage-guard set <higher>` or `usage-guard off` in that session, or ask Claude to (that overrides a global limit too).

Session limits not seen for 7 days are deleted when `set` or `status` runs or a hook prints a notice.

## Upgrading from 0.1

A limit set with 0.1 sits in `~/.claude/usage-guard/config.json`. 0.2 keeps honouring it as the global limit for every session without its own limit, and `usage-guard status` calls it the global limit. It has no mode, so it is now soft (0.1 stopped hard); run `usage-guard set <pct> --global --strict` to get the old behaviour back. A session can override it with `usage-guard set <pct>`, or opt out with `usage-guard off`. Use `usage-guard set <pct> --global` to change it, or `usage-guard off --global` to pause it.

## Sessions, resume and subagents

- `claude --resume` and `claude --continue` reopen the same session and append to its transcript (`<session_id>.jsonl`), so it should keep its `session_id` and its limit. Claude Code's docs say forks (`--fork-session`, `/branch`) "get their own session IDs", and `/clear` starts a new conversation, so those begin with no limit of their own and follow the global one; run `usage-guard set` there again. The docs do not spell out the resume case, and it has not been tested against a live resume.
- A subagent's tool calls fire `PreToolUse` with an `agent_id` added to the parent's input. usage-guard looks up the limit by `session_id` only, so a subagent is held to its parent session's limit. Claude Code's docs show the subagent hook input carrying the parent's `session_id` but do not state it outright; if a subagent ever reports another id, it would fall back to the global limit.

## Uninstall

```bash
usage-guard uninstall --purge     # restore settings.json and delete ~/.claude/usage-guard
rm "$(command -v usage-guard)"
```

Without `--purge`, your limit is kept for a later reinstall.

## Limitations

- The usage figure is account-wide, so every session reads the same percentage. A session limit decides when *that session* stops, not how much it uses.
- A session limit that is not touched for 7 days is deleted; resuming that session later needs a new `usage-guard set`.
- Subscribers only. Claude Code sends usage figures to the status line only on Pro and Max plans.
- A reading exists only after the status line has rendered in an interactive session.
- `claude -p` never renders the status line, so it records no reading. It uses the last one if that is under 15 minutes old.
- Readings refresh about every 60 seconds, so the stop can land a little past the limit. A tool call that is already running is not interrupted.

## Tell Claude about it

The agent setup adds this to `~/.claude/CLAUDE.md`. If you installed by hand, you can add it yourself:

```markdown
<!-- usage-guard -->
## Usage guard
A usage guard may stop this session when account usage reaches its limit. When you see a "USAGE GUARD (wind-down)" message, finish the current unit of work, commit or save state, write a short handoff note (done / next), start no new subagents or long-running work, and stop. When you see "USAGE GUARD (limit reached)", obey it: stop working, save state, tell the user the limit is reached and wait. Carry on only if the user explicitly says to, or asks you to change the limit; then run `usage-guard set <new>` (or `usage-guard off`) as they ask, which is fine. If the guard blocks a tool call or a prompt, do not work around it; tell the user and wait. When the user says "stop this session at N%", run `usage-guard set N` in this session (add `--window 5h` for the 5-hour window, `--strict` to block instead of ask); `usage-guard clear` removes it. Do not run `usage-guard off`, `set` or `clear` on your own initiative.
```

`CLAUDE_CONFIG_DIR` is respected in place of `~/.claude`.

## License

MIT
