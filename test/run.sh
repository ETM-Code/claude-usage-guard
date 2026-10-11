#!/usr/bin/env bash
# shellcheck disable=SC2016
# Plain-bash test harness. Runs entirely in a temp HOME; never touches the real ~/.claude.
cd "$(dirname "$0")/.." || exit 1
UG=$PWD/bin/usage-guard
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
export USAGE_GUARD_NOW=1791735295
unset CLAUDE_CODE_SESSION_ID # these tests may themselves run inside a Claude Code session
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
"$UG" set 60 --global --strict >/dev/null
check "set writes config" '.limit==60 and .enabled==true and .wind_down==2 and .window=="seven_day"' "$(cat "$GD/config.json")"
ensure "set without a number must fail" bash -c '! "$0" set --global >/dev/null 2>&1' "$UG"

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

"$UG" off --global >/dev/null
is_empty "off: pre silent at limit" "$(pre Bash s8)"
"$UG" on --global >/dev/null
check "on: enforcing again" '.continue==false' "$(pre Bash s8)"

reading 59 five_hour
"$UG" set 60 --window 5h --wind-down 5 --global --strict >/dev/null
check "set --window 5h --wind-down" '.window=="five_hour" and .wind_down==5' "$(cat "$GD/config.json")"
has "five_hour window is read" "$(pre Bash s9)" "5-hour"
"$UG" set 60 --window weekly --global --strict >/dev/null

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
"$UG" set 60 --global --strict >/dev/null
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

# ---------------------------------------------------------------- per-session limits
sid_a=aaaaaaaa-1111-2222-3333-444444444444
sid_b=bbbbbbbb-1111-2222-3333-444444444444
sid_c=cccccccc-1111-2222-3333-444444444444
sid_d=dddddddd-1111-2222-3333-444444444444
SD() { echo "$GD/sessions/$1.json"; }
inside() { CLAUDE_CODE_SESSION_ID=$1 "$UG" "${@:2}"; } # inside <session id> <usage-guard args>

reset_env
reading 62
if out=$("$UG" set 60 2>&1); then bad "set outside a session must fail"; else ok; fi
has "set outside a session says what to pass" "$out" "--session <id>, or --global"
ensure "set outside a session writes nothing" test ! -e "$GD/config.json" -a ! -d "$GD/sessions"
ensure "clear outside a session fails" bash -c '! "$0" clear >/dev/null 2>&1' "$UG"
ensure "off outside a session fails" bash -c '! "$0" off >/dev/null 2>&1' "$UG"
ensure "--global and --session together fail" bash -c '! "$0" set 60 --global --session x >/dev/null 2>&1' "$UG"
is_empty "no limit anywhere: pre silent even at 62%" "$(pre Bash "$sid_a")"

# set / status / clear inside a session
out=$(inside "$sid_a" set 60 --strict 2>&1)
has "set in a session says other sessions are unaffected" "$out" "other sessions are unaffected"
has "set in a session: summary says session limit" "$out" "this session's limit"
check "session file holds only the session's limit" '.limit==60 and .enabled==true and (has("original_statusline")|not)' "$(cat "$(SD $sid_a)")"
ensure "set in a session leaves config.json alone" test ! -e "$GD/config.json"
out=$(inside "$sid_a" status)
has "status in a session: prefix" "$out" "aaaaaaaa"
has "status in a session: source" "$out" "(this session's limit)"
has "status in a session: limit" "$out" "60% of the weekly window"
check "session limit applies to its own hooks" '.continue==false and (.stopReason|test("this session"))' "$(pre Bash $sid_a)"
inside "$sid_a" set 55 --window 5h --wind-down 4 --strict >/dev/null
check "set again updates the session file" '.limit==55 and .window=="five_hour" and .wind_down==4' "$(cat "$(SD $sid_a)")"
inside "$sid_a" set 60 --window weekly --strict >/dev/null
inside "$sid_a" off >/dev/null
check "off in a session pauses only that session" '.enabled==false and .limit==60' "$(cat "$(SD $sid_a)")"
is_empty "session off: hooks silent" "$(pre Bash $sid_a)"
has "session off: status says so" "$(inside "$sid_a" status)" "off for this session"
inside "$sid_a" on >/dev/null
check "on resumes the session" '.continue==false' "$(pre Bash $sid_a)"
out=$(inside "$sid_a" clear)
has "clear says what it did" "$out" "cleared"
ensure "clear removes the session file" test ! -e "$(SD $sid_a)"
is_empty "after clear: hooks silent" "$(pre Bash $sid_a)"
has "after clear: status shows no limit" "$(inside "$sid_a" status)" "not configured"
inside "$sid_a" on >/dev/null
ensure "on without a session file creates none" test ! -e "$(SD $sid_a)"
ensure "bad --window in a session fails" bash -c '! CLAUDE_CODE_SESSION_ID=x "$0" set 60 --window monthly >/dev/null 2>&1' "$UG"
inside "../weird/id" set 60 >/dev/null
ensure "a session id cannot escape the sessions dir" test -f "$GD/sessions/.._weird_id.json"
rm -f "$GD/sessions/.._weird_id.json"

# --session from outside, with a prefix
"$UG" set 60 --session "$sid_b" --strict >/dev/null
ensure "--session sets another session's limit" test -f "$(SD $sid_b)"
out=$("$UG" status)
has "status outside a session lists session limits (prefix)" "$out" "bbbbbbbb"
has "status outside a session lists the limit" "$out" "60% of the weekly window"
has "status outside a session lists last seen" "$out" "last seen"
has "status outside a session: global is none" "$out" "none"
"$UG" off --session bbbbbbbb >/dev/null
check "--session takes a unique prefix" '.enabled==false' "$(cat "$(SD $sid_b)")"
has "list marks an off session" "$("$UG" status)" ", off,"
"$UG" clear --session bbbbbbbb >/dev/null
ensure "clear --session by prefix" test ! -e "$(SD $sid_b)"
has "no sessions: status says so" "$("$UG" status)" "none has a limit of its own"

# two sessions with different limits do not affect each other
reading 58.5
inside "$sid_a" set 60 --strict >/dev/null
inside "$sid_b" set 90 --strict >/dev/null
has "A in its wind-down band" "$(pre Bash "$sid_a")" "58.5%"
is_empty "B below its band: silent" "$(pre Bash "$sid_b")"
reading 61
check "A at its limit is stopped" '.continue==false' "$(pre Bash "$sid_a")"
is_empty "B is unaffected by A's limit" "$(pre Bash "$sid_b")"
is_empty "B's prompts are unaffected" "$(ups "$sid_b")"
check "A's prompts are blocked" '.decision=="block"' "$(ups "$sid_a")"
is_empty "a session with no limit of its own is unaffected" "$(pre Bash "$sid_c")"
reading 91
check "B stops at its own limit" '.continue==false and (.stopReason|test("90"))' "$(pre Bash "$sid_b")"
inside "$sid_a" off >/dev/null
is_empty "A off: silent" "$(pre Bash "$sid_a")"
check "A off does not turn B off" '.continue==false' "$(pre Bash "$sid_b")"
inside "$sid_a" on >/dev/null

# global fallback
"$UG" set 70 --global --strict >/dev/null
has "status outside: global limit labelled" "$("$UG" status)" "global limit: applies to every session without its own"
check "global limit stops a session with no limit of its own" '.continue==false and (.stopReason|test("the global 70"))' "$(pre Bash "$sid_c")"
check "session limit wins over the global one (A: 60)" '.stopReason|test("this session")' "$(pre Bash "$sid_a")"
reading 65
check "session limit stricter than global: A stops, C does not" '.continue==false' "$(pre Bash "$sid_a")"
is_empty "C below the global limit: silent" "$(pre Bash "$sid_c")"
reading 72
out=$(inside "$sid_c" status)
has "status in a session without a limit: shows global" "$out" "global limit"
has "status in a session without a limit: no session line of its own" "$out" "cccccccc"
inside "$sid_c" off >/dev/null
is_empty "session off beats the global limit" "$(pre Bash "$sid_c")"
check "a different session still follows the global limit" '.continue==false' "$(pre Bash "$sid_d")"
inside "$sid_c" clear >/dev/null
check "clear returns a session to the global limit" '.continue==false' "$(pre Bash "$sid_c")"
inside "$sid_a" set 99 --strict >/dev/null
is_empty "a session may raise its limit above the global one" "$(pre Bash "$sid_a")"
"$UG" off --global >/dev/null
reading 91
check "global off leaves a session's own limit enforcing (B: 90)" '.continue==false' "$(pre Bash "$sid_b")"
is_empty "global off: a session with no limit is silent" "$(pre Bash "$sid_c")"
"$UG" on --global >/dev/null
has "status --global inside a session shows the sessions list" "$(inside "$sid_c" status --global)" "sessions"

# inherits window from the global config
printf '{"enabled":true,"limit":50,"window":"five_hour"}' >"$GD/config.json"
reading 59 five_hour
inside "$sid_a" set 60 --strict >/dev/null
has "session without --window uses the global window" "$(pre Bash "$sid_a")" "5-hour"
inside "$sid_a" clear >/dev/null

# subagents (agent_id) get their session's limit
reset_env
reading 61
inside "$sid_a" set 60 --strict >/dev/null
check "subagent hook carries agent_id and inherits the session limit" '.continue==false and (.stopReason|test("this session"))' "$(pre Bash "$sid_a" ',"agent_id":"ag1","agent_type":"Explore"')"
is_empty "subagent of an unlimited session is unaffected" "$(pre Bash "$sid_b" ',"agent_id":"ag1","agent_type":"Explore"')"
reading 59
has "subagent gets the wind-down notice of its session" "$(pre Bash "$sid_a" ',"agent_id":"ag2"')" "wind-down"
check "subagent spawn refused in the session's wind-down band" '.hookSpecificOutput.permissionDecision=="deny"' "$(pre Agent "$sid_a" ',"agent_id":"ag3"')"

# migration: an old (0.1.x) config.json with a limit and no sessions dir
reset_env
mkdir -p "$GD"
printf '{"enabled":true,"limit":60,"window":"seven_day","wind_down":2,"mode":"strict"}\n' >"$GD/config.json"
reading 61
check "old config: still enforced as the global limit" '.continue==false and (.stopReason|test("the global 60"))' "$(pre Bash "$sid_a")"
check "old config: any session id, and none at all" '.continue==false' "$(hook PreToolUse x '{"tool_name":"Bash"}')"
out=$("$UG" status)
has "old config: status says global" "$out" "(global limit: applies to every session without its own)"
out=$(inside "$sid_a" status)
has "old config: status in a session says global" "$out" "global limit"
check "old config: hooks keep working after a session limit appears" '.continue==false' "$(pre Bash "$sid_b")"
inside "$sid_a" set 90 --strict >/dev/null
check "old config: other sessions still follow it" '.continue==false' "$(pre Bash "$sid_b")"
check "old config untouched by a session set" '.limit==60' "$(cat "$GD/config.json")"
printf '{"enabled":false,"limit":60}\n' >"$GD/config.json"
is_empty "old config with enabled false: silent" "$(pre Bash "$sid_b")"

# statusline segment follows the session's limit
reset_env
"$UG" set 60 --global --strict >/dev/null
inside "$sid_a" set 80 --strict >/dev/null
in3="{\"session_id\":\"$sid_a\",\"rate_limits\":{\"seven_day\":{\"used_percentage\":34,\"resets_at\":$RESET}}}"
eq "statusline shows the session's limit" "$(sl "$in3")" "week 34%/80"
eq "statusline for another session shows the global limit" "$(sl "${in3/$sid_a/$sid_b}")" "week 34%/60"

# pruning: stale session limits go, fresh ones stay
reset_env
inside "$sid_a" set 60 --strict >/dev/null
inside "$sid_b" set 60 --strict >/dev/null
touch -t 202001010000 "$(SD $sid_b)"
out=$("$UG" status)
ensure "status prunes a limit not seen for 7+ days" test ! -e "$(SD $sid_b)"
ensure "status keeps a fresh limit" test -e "$(SD $sid_a)"
inside "$sid_b" set 60 --strict >/dev/null
touch -t 202001010000 "$(SD $sid_b)"
reading 58.5
pre Bash "$sid_b" >/dev/null # touches its own file, so an active session never expires
ensure "a hook call refreshes last seen" test -e "$(SD $sid_b)"
touch -t 202001010000 "$(SD $sid_b)"
reading 58.5
pre Bash "$sid_a" >/dev/null # a notice is written, which prunes
ensure "a hook notice prunes other stale sessions" test ! -e "$(SD $sid_b)"
ensure "the notifying session keeps its limit" test -e "$(SD $sid_a)"

# ---------------------------------------------------------------- soft mode (the default) and strict mode
reset_env
inside "$sid_a" set 60 >/dev/null
check "set without a mode flag stores no mode (soft)" 'has("mode")|not' "$(cat "$(SD $sid_a)")"
has "status shows soft" "$(inside "$sid_a" status)" "soft"
reading 58.4
has "soft: wind-down band is unchanged" "$(pre Bash "$sid_a")" "USAGE GUARD (wind-down)"
check "soft: wind-down still denies Agent" '.hookSpecificOutput.permissionDecision=="deny"' "$(pre Agent "$sid_a")"
reading 61.2
out=$(pre Bash "$sid_a")
check "soft at the limit: context only, never a stop" '.continue==null and .decision==null and .hookSpecificOutput.permissionDecision==null and (.hookSpecificOutput.additionalContext|type=="string")' "$out"
for w in "USAGE GUARD (limit reached)" "61.2% of the 60% limit set for this session" "Stop working now" "commit or save state" "short handoff note" "tell the user the limit is reached" "wait" "explicitly tells you to" "usage-guard set <new>" "usage-guard off"; do
  has "limit-reached text: $w" "$out" "$w"
done
# cadence: once, then every 10th PreToolUse call, and again at the next whole percent
n=0 shown=''
for i in $(seq 1 25); do
  o=$(pre Bash "$sid_a")
  [ -n "$o" ] && shown="$shown $i"
  case $o in *'"continue"'* | *'"decision"'*) n=$((n + 1)) ;; esac
done
eq "limit-reached is injected on calls 11 and 21 (call 1 was above)" "$shown" " 10 20"
eq "no call blocked in 25 soft calls" "$n" "0"
reading 62.5
has "re-injected at the next whole percent" "$(pre Bash "$sid_a")" "62.5%"
is_empty "same whole percent again is silent" "$(pre Bash "$sid_a")"
for i in 1 2 3; do
  out=$(ups "$sid_a")
  check "soft: every prompt gets the instruction, none is blocked (#$i)" '.decision==null and (.hookSpecificOutput.additionalContext|test("limit reached"))' "$out"
done
has "soft: session start gets it too" "$(hook SessionStart x "{\"session_id\":\"$sid_a\"}")" "limit reached"
for t in Agent Task Workflow; do
  check "soft at the limit denies $t" '.continue==null and .hookSpecificOutput.permissionDecision=="deny" and (.hookSpecificOutput.permissionDecisionReason|test("subagents"))' "$(pre "$t" "$sid_a")"
done
out=$(pre Bash "$sid_a" ',"agent_id":"ag1"')
has "soft: a subagent gets the subagent wording" "$out" "short status note"
check "soft: a subagent is not stopped either" '.continue==null and .hookSpecificOutput.permissionDecision==null' "$out"
is_empty "soft: other sessions are untouched" "$(pre Bash "$sid_b")"
printf '{"enabled":true,"limit":60}' >"$GD/config.json"
has "soft: a 0.1-style global limit is soft too" "$(pre Bash "$sid_c")" "global limit"
check "soft: ... and does not block" '.continue==null' "$(pre Bash "$sid_c" ',"agent_id":"a9"')"
eq "soft statusline segment says LIMIT" "$(sl "{\"session_id\":\"$sid_a\",\"rate_limits\":{\"seven_day\":{\"used_percentage\":63,\"resets_at\":$RESET}}}")" "week 63%/60 LIMIT"

# strict mode: the hard stop, opt-in
inside "$sid_a" set 60 --strict >/dev/null
check "--strict is stored" '.mode=="strict"' "$(cat "$(SD $sid_a)")"
has "status shows strict" "$(inside "$sid_a" status)" "strict"
has "list marks strict" "$("$UG" status)" ", strict"
check "strict: tool call stopped" '.continue==false and .hookSpecificOutput.permissionDecision=="deny"' "$(pre Bash "$sid_a")"
check "strict: prompt blocked" '.decision=="block"' "$(ups "$sid_a")"
check "strict: Agent stopped" '.continue==false' "$(pre Agent "$sid_a")"
for i in 1 2 3; do pre Bash "$sid_a" >/dev/null; done
check "strict: no cadence, every call stopped" '.continue==false' "$(pre Bash "$sid_a")"
inside "$sid_a" set 70 >/dev/null
eq "raising the limit keeps strict" "$(jq -r .mode "$(SD $sid_a)")" "strict"
inside "$sid_a" set 60 --soft >/dev/null
eq "--soft goes back" "$(jq -r .mode "$(SD $sid_a)")" "soft"
out=$(pre Bash "$sid_a")
check "after --soft: not blocked" '.continue==null and .decision==null' "${out:-{\}}"
printf '{"enabled":true,"limit":60,"mode":"strict"}' >"$GD/config.json"
inside "$sid_c" set 60 >/dev/null
check "a session inherits the global mode" '.continue==false' "$(pre Bash "$sid_c")"
"$UG" set 60 --global --soft >/dev/null
eq "set --global --soft" "$(jq -r .mode "$GD/config.json")" "soft"

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
"$UG" set 60 --global --strict >/dev/null
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
