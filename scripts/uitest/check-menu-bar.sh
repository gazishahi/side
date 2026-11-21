#!/bin/zsh
# The menu bar's list while Side is closed (SIDE/BackgroundSessions.swift, Helpers/SideNotifier
# --menu). Three kept terminals: `sleep` running, a stand-in Claude Code that the hook's events
# describe, and an idle shell. Side quits, leaving them running; the helper lists the first two,
# follows the events written after, drops what ends, and goes when Side opens again. There's no
# screen to capture here, so the helper writes its menu and icon (SIDE_MENU_BAR_DUMP).
#
#   SIDE_UIT=/tmp/side-uit-sessions scripts/uitest/uitest.sh build && SIDE_UIT=/tmp/side-uit-sessions scripts/uitest/check-menu-bar.sh
set -uo pipefail
U=$(dirname "$0")/uitest.sh
ROOT=${SIDE_UIT:-/tmp/side-uit}
APP=$ROOT/dd/Build/Products/Release/Side.app
OUT=$ROOT/check-menu-bar
rm -rf $OUT; mkdir -p $OUT
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1 (${3:-})"; failures=$((failures + 1)); fi; }
menu() { sleep ${1:-1.5}; cat $OUT/menu.txt 2>/dev/null; }

P=$ROOT/fixtures/menu-bar/side
rm -rf $ROOT/fixtures/menu-bar; mkdir -p $P && git -C $P init -q
HOOKS=$ROOT/hooks
rm -rf $HOOKS; mkdir -p $HOOKS

$U launch $P; sleep 2
$U post "stage run"; sleep 2
$U type "sleep 900"; $U post "key return"; sleep 0.5
$U post "action newSession"; sleep 1.5
$U type "perl -e '\$0=\"side-menu-standin\"; sleep 900'"; $U post "key return"; sleep 1
$U post "action newSession"; sleep 1.5
STAND_IN=$(pgrep -f side-menu-standin | head -1)
check "the stand-in runs in a kept terminal" '[[ -n $STAND_IN ]]'

# Side quits; its terminals carry on.
pkill -f "$APP/Contents/MacOS/Side"; for _ in {1..50}; do pgrep -f "$APP/Contents/MacOS/Side" >/dev/null || break; sleep 0.1; done
event() { print -r -- "{\"side\":{\"agent\":\"claude\",\"ppid\":$STAND_IN,\"pid\":1,\"at\":$(date +%s)},\"event\":$1}" > $HOOKS/$(date +%s)-$RANDOM.json; }
event '{"hook_event_name":"UserPromptSubmit","session_id":"mb-1","prompt":"Fix the flaky login test"}'
event '{"hook_event_name":"PermissionRequest","session_id":"mb-1","tool_name":"Bash","tool_input":{"command":"swift test"}}'

NOTIFIER="$APP/Contents/Helpers/Side Notifier.app/Contents/MacOS/Side Notifier"
SIDE_MENU_BAR_DUMP=$OUT SIDE_HOOKS_DIR=$HOOKS "$NOTIFIER" --menu --side $APP --defaults com.shahi.side.uitest.sessions --run $ROOT/run > $OUT/helper.log 2>&1 &
HELPER=$!
m=$(menu 2.5); echo "$m" | sed 's/^/     /'
check "the count of what needs you on the icon" '[[ $(echo "$m" | sed -n 1p) == "button:  1" ]]' "$m"
check "two sessions: the idle shell isn't one" '[[ $m == *"Side — 2 sessions"* ]]' "$m"
check "needs you first, by what it was asked, with why" '[[ $m == *"Needs You"$'"'"'\n'"'"'"side · Fix the flaky login test"*"/ Wants to run swift test"* ]]' "$m"
check "then what's working, by its command" '[[ $m == *"Working"$'"'"'\n'"'"'"side · sleep 900"* ]]' "$m"
check "each row can be stopped with Option" '[[ $m == *"⌥ Stop “sleep 900”"* ]]' "$m"
check "Open Side, Stop All, Settings" '[[ $m == *"Open Side"$'"'"'\n'"'"'"Stop All Sessions…"*"Settings…"* ]]' "$m"
cp $OUT/icon.png $OUT/icon-needs-you.png 2>/dev/null

event '{"hook_event_name":"PostToolUse","session_id":"mb-1","tool_name":"Bash"}'
event '{"hook_event_name":"Stop","session_id":"mb-1"}'
m=$(menu)
check "the turn ends: finished, and nothing needs you" '[[ $m == "button: "$'"'"'\n'"'"'* && $m == *"Finished"$'"'"'\n'"'"'"side · Fix the flaky login test   "* ]]' "$m"
pkill -f "^sleep 900"
m=$(menu 4)
check "a program that ends leaves the list" '[[ $m == *"Side — 1 session"$'"'"'\n'"'"'* && $m != *"sleep 900"* ]]' "$m"
check "the events stay for Side to read" '[[ $(ls $HOOKS | wc -l | tr -d " ") == 4 ]]' "$(ls $HOOKS)"

# Side opens: the menu goes.
$U launch $P; sleep 3
check "Side opening ends the helper" '! kill -0 $HELPER 2>/dev/null'
kill $HELPER 2>/dev/null
$U quit
echo "$failures failed; in $OUT"
exit $failures
