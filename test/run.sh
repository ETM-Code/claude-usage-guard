#!/usr/bin/env bash
# shellcheck disable=SC2016
# Plain-bash test harness. Runs entirely in a temp HOME; never touches the real ~/.claude.
cd "$(dirname "$0")/.." || exit 1
UG=$PWD/bin/usage-guard
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
export USAGE_GUARD_NOW=1791735295
NOW=$USAGE_GUARD_NOW
RESET=$((NOW + 3600))
pass=0 failn=0

reset_env() {
  rm -rf "${ROOT:?}/home"
  export HOME=$ROOT/home CLAUDE_CONFIG_DIR=$ROOT/home/.claude
  GD=$CLAUDE_CONFIG_DIR/usage-guard
  mkdir -p "$CLAUDE_CONFIG_DIR"
}
ok() { pass=$((pass + 1)); }
ensure() { local n=$1; shift; if "$@"; then ok; else bad "$n"; fi; } # ensure <name> <cmd...>
backups() { ls "$CLAUDE_CONFIG_DIR"/settings.json.usage-guard-backup-* 2>/dev/null; }
bad() { failn=$((failn + 1)); printf 'FAIL: %s\n' "$1"; [ -z "${2:-}" ] || printf '      %s\n' "$2"; }
check() { # check <name> <jq -e filter> <json>
  if printf '%s' "$3" | jq -e "$2" >/dev/null 2>&1; then ok; else bad "$1" "$3"; fi
}
is_empty() { if [ -z "$2" ]; then ok; else bad "$1" "expected no output, got: $2"; fi; }
eq() { if [ "$2" = "$3" ]; then ok; else bad "$1" "expected [$3] got [$2]"; fi; }
has() { case $2 in *"$3"*) ok ;; *) bad "$1" "missing [$3] in: $2" ;; esac; }

reading() { # reading <pct> [window] [age_s] [resets_at]
  local w=${2:-seven_day} age=${3:-60} r=${4:-$RESET}
  mkdir -p "$GD"
  printf '{"captured_at":%s,"%s":{"used_percentage":%s,"resets_at":%s}}' $((NOW - age)) "$w" "$1" "$r" >"$GD/usage.json"
}
hook() { printf '%s' "${3:-{\}}" | "$UG" hook "$1" 2>&1; } # hook <event> unused <json>
pre() { hook PreToolUse x "{\"session_id\":\"${2:-s1}\",\"tool_name\":\"${1:-Bash}\"${3:-}}"; }
ups() { hook UserPromptSubmit x "{\"session_id\":\"${1:-s1}\",\"prompt\":\"hi\"}"; }

# ---------------------------------------------------------------- bands
reset_env
reading 95
is_empty "no config: pre silent" "$(pre)"
is_empty "no config: prompt silent" "$(ups)"
"$UG" set 60 >/dev/null
check "set writes config" '.limit==60 and .enabled==true and .wind_down==2 and .window=="seven_day"' "$(cat "$GD/config.json")"
ensure "set without a number must fail" bash -c '! "$0" set >/dev/null 2>&1' "$UG"

reading 40
is_empty "below band: pre silent" "$(pre)"
is_empty "below band: prompt silent" "$(ups)"
reading 57.9
is_empty "57.9 is below the 58 band start" "$(pre)"

reading 58.4
out=$(pre)
check "wind-down: valid JSON with additionalContext" '.hookSpecificOutput.hookEventName=="PreToolUse" and (.hookSpecificOutput.additionalContext|type=="string")' "$out"
for w in "58.4%" "60%" "finish the current unit of work" "commit or save state" "handoff note" "no new long-running work" "new subagents"; do
  has "wind-down text mentions: $w" "$out" "$w"
done
is_empty "once per session: second call silent" "$(pre)"
reading 59.1
has "re-injects at the next whole percent" "$(pre)" "59.1%"
is_empty "same whole percent again is silent" "$(pre)"
has "new session injects again" "$(pre Bash s2)" "59.1%"
has "subagent (agent_id) has its own state" "$(pre Bash s2 ',"agent_id":"a1"')" "59.1%"
is_empty "subagent second call silent" "$(pre Bash s2 ',"agent_id":"a1"')"
has "prompt hook injects in wind-down" "$(ups s3)" '"hookEventName":"UserPromptSubmit"'
has "session start injects in wind-down" "$(hook SessionStart x '{"session_id":"s4","source":"startup"}')" '"hookEventName":"SessionStart"'

for t in Agent Task Workflow; do
  out=$(pre "$t" s5)
  check "wind-down denies $t" '.hookSpecificOutput.permissionDecision=="deny" and (.hookSpecificOutput.permissionDecisionReason|length>20)' "$out"
done
check "wind-down allows other tools (no deny)" '.hookSpecificOutput.permissionDecision==null' "$(pre Edit s6)"

reading 60
out=$(pre Bash s7)
check "limit: continue false + stopReason" '.continue==false and (.stopReason|test("60"))' "$out"
has "limit: stopReason says how to lift (set)" "$out" 'usage-guard set <higher>'
has "limit: stopReason says how to lift (off)" "$out" 'usage-guard off'
check "limit: tool call denied too" '.hookSpecificOutput.permissionDecision=="deny"' "$out"
check "limit: subagent call stopped" '.continue==false' "$(pre Bash s7 ',"agent_id":"a9"')"
check "limit: prompt blocked" '.decision=="block" and (.reason|test("usage-guard off"))' "$(ups s7)"
is_empty "Stop hook never blocks" "$(hook Stop x '{"session_id":"s7","stop_hook_active":false}')"
is_empty "unknown event is a no-op" "$(hook PostToolUse x '{"session_id":"s7"}')"

"$UG" off >/dev/null
is_empty "off: pre silent at limit" "$(pre Bash s8)"
"$UG" on >/dev/null
check "on: enforcing again" '.continue==false' "$(pre Bash s8)"

reading 59 five_hour
"$UG" set 60 --window 5h --wind-down 5 >/dev/null
check "set --window 5h --wind-down" '.window=="five_hour" and .wind_down==5' "$(cat "$GD/config.json")"
has "five_hour window is read" "$(pre Bash s9)" "5-hour"
"$UG" set 60 --window weekly >/dev/null

# ---------------------------------------------------------------- stale / reset / missing
reading 95 seven_day 1200
out=$(pre Bash t1)
has "stale: blind notice, not a stop" "$out" "blind"
check "stale: no stop" '.continue==null and .hookSpecificOutput.permissionDecision==null' "$out"
is_empty "stale: notice once per session" "$(pre Bash t1)"
is_empty "stale: notice once per session (prompt too)" "$(ups t1)"
has "stale: status says so" "$("$UG" status)" "STALE"
reading 95 seven_day 60 $((NOW - 10))
is_empty "reading past resets_at counts as 0" "$(pre Bash t2)"
has "reset: status says so" "$("$UG" status)" "already reset"
rm "$GD/usage.json"
has "missing reading: blind notice" "$(pre Bash t3)" "blind"
has "missing reading: status says so" "$("$UG" status)" "none yet"
printf 'not json' >"$GD/usage.json"
check "garbage reading: blind notice, never a stop" '.continue==null and (.hookSpecificOutput.additionalContext|test("blind"))' "$(pre Bash t4)"

# prune of old state files
reading 58.5
touch -t 202001010000 "$GD/state/old.last" 2>/dev/null || { mkdir -p "$GD/state"; touch -t 202001010000 "$GD/state/old.last"; }
pre Bash p1 >/dev/null
ensure "old state pruned" test ! -e "$GD/state/old.last"

# hot-path speed (generous bound so CI noise does not flake; typical is well under 100 ms per call)
reading 10
start=$(date +%s)
for _ in 1 2 3 4 5 6 7 8 9 10; do pre Bash sp >/dev/null; done
elapsed=$(($(date +%s) - start))
ensure "10 silent hook calls took ${elapsed}s" test "$elapsed" -le 5

# ---------------------------------------------------------------- statusLine tap
reset_env
"$UG" set 60 >/dev/null
sl() { printf '%s' "$1" | "$UG" statusline; }
in1="{\"model\":{\"display_name\":\"M\"},\"rate_limits\":{\"five_hour\":{\"used_percentage\":8,\"resets_at\":$((NOW + 100))},\"seven_day\":{\"used_percentage\":34,\"resets_at\":$RESET}}}"
out=$(sl "$in1")
eq "statusline segment" "$out" "week 34%/60"
check "statusline records reading" ".captured_at==$NOW and .seven_day.used_percentage==34 and .five_hour.used_percentage==8" "$(cat "$GD/usage.json")"
sl "{\"rate_limits\":{\"seven_day\":{\"used_percentage\":30,\"resets_at\":$RESET}}}" >/dev/null
check "older/lower reading never overwrites a newer one" '.seven_day.used_percentage==34' "$(cat "$GD/usage.json")"
sl "{\"rate_limits\":{\"seven_day\":{\"used_percentage\":35,\"resets_at\":$RESET}}}" >/dev/null
check "higher reading wins" '.seven_day.used_percentage==35' "$(cat "$GD/usage.json")"
sl "{\"rate_limits\":{\"seven_day\":{\"used_percentage\":3,\"resets_at\":$((RESET + 600000))}}}" >/dev/null
check "new window (later resets_at) replaces" '.seven_day.used_percentage==3' "$(cat "$GD/usage.json")"
before=$(cat "$GD/usage.json")
out=$(sl '{"model":{"display_name":"M"}}')
eq "no rate_limits: file untouched" "$(cat "$GD/usage.json")" "$before"
eq "no rate_limits: no output" "$out" ""
in2="{\"rate_limits\":{\"seven_day\":{\"used_percentage\":59,\"resets_at\":$((RESET + 600001))}}}"
out=$(sl "$in2")
has "segment flags wind-down" "$out" "wind-down"
printf 'not json' >"$GD/usage.json"
sl "$in2" >/dev/null
check "a garbage reading file is replaced" '.seven_day.used_percentage==59' "$(cat "$GD/usage.json")"

# ---------------------------------------------------------------- install / uninstall
reset_env
SET=$CLAUDE_CONFIG_DIR/settings.json
cat >"$ROOT/orig.json" <<'EOF'
{
  "model": "opus",
  "permissions": { "allow": ["Bash(ls:*)"] },
  "hooks": {
    "PreToolUse": [{ "matcher": "Bash", "hooks": [{ "type": "command", "command": "echo pre", "timeout": 3 }] }],
    "Stop": [{ "hooks": [{ "type": "command", "command": "echo stop" }] }]
  },
  "statusLine": { "type": "command", "command": "echo orig:$(cat | jq -r .model.display_name)", "padding": 1 },
  "env": { "A": "1" }
}
EOF
jq . "$ROOT/orig.json" >"$SET"
cp "$SET" "$ROOT/before.json"
"$UG" install >/dev/null || bad "install exits 0"
check "install: our 3 hooks + statusLine" '[.hooks.SessionStart[].hooks[].command, .hooks.UserPromptSubmit[].hooks[].command, .hooks.PreToolUse[].hooks[].command, .statusLine.command] | map(select(test("usage-guard.? (hook|statusline)"))) | length==4' "$(cat "$SET")"
check "install: existing hooks and settings kept" '.model=="opus" and .env.A=="1" and .hooks.Stop[0].hooks[0].command=="echo stop" and .hooks.PreToolUse[0].hooks[0].command=="echo pre" and (.hooks.PreToolUse|length)==2' "$(cat "$SET")"
check "install: original statusLine recorded in config" '.original_statusline.command|test("echo orig")' "$(cat "$GD/config.json")"
check "install: statusLine keeps padding, adds refreshInterval" '.statusLine.padding==1 and .statusLine.refreshInterval==60' "$(cat "$SET")"
eq "install state" "$("$UG" status | sed -n 's/^install *//p')" "installed"
ensure "install made a timestamped backup" test -n "$(backups)"
ensure "backup equals the original" cmp -s "$(backups | head -1)" "$ROOT/before.json"

cp "$SET" "$ROOT/after1.json"
out=$("$UG" install)
ensure "second install is a no-op" cmp -s "$SET" "$ROOT/after1.json"
has "second install says so" "$out" "already installed"
eq "only one backup" "$(backups | wc -l | tr -d ' ')" "1"

# statusLine chaining: run the command exactly as settings.json has it
"$UG" set 60 >/dev/null
cmd=$(jq -r .statusLine.command "$SET")
out=$(printf '%s' "$in1" | sh -c "$cmd")
eq "chained statusLine: original output + segment" "$out" "orig:M · week 34%/60"
check "chained statusLine still records" '.seven_day.used_percentage==34' "$(cat "$GD/usage.json")"
ensure "doctor passes after install + reading" "$UG" doctor >"$ROOT/doctor.txt"
cp "$SET" "$ROOT/good.json"
jq '(.hooks.PreToolUse[].hooks[] | select(.command|test("usage-guard"))).command = "/nonexistent/usage-guard hook PreToolUse"' "$ROOT/good.json" >"$SET"
ensure "doctor fails when the hooks point at a missing program" bash -c '! "$0" doctor >/dev/null' "$UG"
cp "$ROOT/good.json" "$SET"

"$UG" uninstall >/dev/null
ensure "uninstall restores settings.json byte for byte" cmp -s "$SET" "$ROOT/before.json"
eq "uninstall: status" "$("$UG" status | sed -n 's/^install *//p')" "not installed"
"$UG" uninstall >/dev/null
ensure "second uninstall is a no-op" cmp -s "$SET" "$ROOT/before.json"

# fresh settings (no file), no original statusLine
rm -f "$SET"
"$UG" install >/dev/null
check "install into empty config dir" '.statusLine.command|test("statusline")' "$(cat "$SET")"
out=$(printf '%s' "$in1" | sh -c "$(jq -r .statusLine.command "$SET")")
eq "unchained statusLine prints only the segment" "$out" "week 34%/60"
"$UG" uninstall >/dev/null
eq "uninstall leaves an empty object when there was nothing before" "$(jq -c . "$SET")" "{}"
"$UG" uninstall --purge >/dev/null
ensure "--purge deletes the guard dir" test ! -d "$GD"
ensure "--purge leaves the binary alone" test -x "$UG"

# HOME fallback when CLAUDE_CONFIG_DIR is unset
reset_env
unset CLAUDE_CONFIG_DIR
mkdir -p "$HOME/.claude"
"$UG" install >/dev/null
ensure "falls back to HOME/.claude" test -f "$HOME/.claude/usage-guard/config.json"

# ---------------------------------------------------------------- AGENT_SETUP snippet append is idempotent
reset_env
MD=$CLAUDE_CONFIG_DIR/CLAUDE.md
cmd=$(sed -n '/append-snippet-start/,/append-snippet-end/p' AGENT_SETUP.md | sed -n '/^```bash/,/^```/p' | sed '1d;$d')
if [ -z "$cmd" ]; then bad "AGENT_SETUP.md has an append-snippet bash block"; else
  mkdir -p "$CLAUDE_CONFIG_DIR"
  printf 'existing line\n' >"$MD"
  bash -c "$cmd" >/dev/null 2>&1
  bash -c "$cmd" >/dev/null 2>&1
  eq "snippet marker appears once after two runs" "$(grep -c '<!-- usage-guard -->' "$MD")" "1"
  eq "existing CLAUDE.md content kept" "$(head -1 "$MD")" "existing line"
  rm -f "$MD"
  bash -c "$cmd" >/dev/null 2>&1
  eq "snippet creates CLAUDE.md when absent" "$(grep -c '<!-- usage-guard -->' "$MD")" "1"
fi

printf '\n%s passed, %s failed\n' "$pass" "$failn"
[ "$failn" -eq 0 ]
