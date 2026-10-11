# Changelog

## 0.2.0

Limits are now per session. `usage-guard set <pct>` inside a Claude Code session limits that session only (stored in `~/.claude/usage-guard/sessions/<session_id>.json`); `--global` sets a default for sessions with no limit of their own, `--session <id>` targets another session, and outside a session `set`, `on`, `off` and `clear` need one of the two. New `usage-guard clear`. `status` shows the effective limit and where it comes from, and lists session limits when run outside a session. Hooks use the session's limit, else the global one; subagents share their parent's. Session limits not seen for 7 days are pruned. A 0.1 `config.json` limit keeps working as the global limit. The status line segment shows the session's limit.

Each limit has a `mode`: `soft` (default) never blocks anything at the limit except new `Agent`, `Task` and `Workflow` calls, and instead injects a "USAGE GUARD (limit reached)" instruction (on every prompt; on tool calls once, then every 10 calls and at each further whole percent), so the user can tell Claude "carry on" or "raise the limit to 70" from a phone and Claude runs `usage-guard set 70`. `--strict` keeps the 0.1 hard stop (`continue: false`, prompts blocked); `--soft` goes back. `status` shows the mode. A 0.1 limit has no mode, so it becomes soft; `usage-guard set <pct> --global --strict` restores the hard stop.

## 0.1.0

First release: the status line tap, wind-down band and hard stop hooks, the `usage-guard` command and the installer.
