#!/bin/zsh
# The activity list's row actions (2026-11-20): on the row under the pointer only, Review for a
# finished session that changed something (Changes, with that session's entry chosen) and the ×
# for anything that has ended (put away until it's something else).
#
#   SIDE_UIT=/tmp/side-uit-sessions scripts/uitest/uitest.sh build && SIDE_UIT=/tmp/side-uit-sessions scripts/uitest/check-activity-actions.sh
set -uo pipefail
U=$(dirname "$0")/uitest.sh
ROOT=${SIDE_UIT:-/tmp/side-uit}
BIN=$ROOT/bin
OUT=$ROOT/check-activity-actions
rm -rf $OUT; mkdir -p $OUT
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1 (${3:-})"; failures=$((failures + 1)); fi; }
dump() { $U post activity-dump; sleep 0.7; awk '/^\[activity\]/{block=""} {block=block $0 "\n"} END{printf "%s", block}' $ROOT/side.log; }
items() { dump | grep '^item '; }
hover() { $U post "activity-hover $1"; sleep 0.5; grep -a '^\[activity-hover\]' $ROOT/side.log | tail -1 | sed 's/^\[activity-hover\] *//'; }
actions() { $U post queue-actions; sleep 0.6; grep -a '^\[queue-actions\]' $ROOT/side.log | tail -1; }

P=$ROOT/fixtures/activity-actions
rm -rf $P; mkdir -p $P && cd $P && git init -q -b main && printf 'hi\n' > README.md && git add -A && git -c user.email=t@t -c user.name=t commit -qm init && cd - > /dev/null

$U launch $P; sleep 2
$U post "window-size 1100 700" "stage run"; sleep 2.5
$U post hooks-dump; sleep 0.6
INBOX=$(grep -a '^\[hooks\]' $ROOT/side.log | tail -1 | sed 's/.*inbox=\([^ ]*\).*/\1/'); mkdir -p $INBOX
# Two Claude Codes, each finishing a turn out of sight; only the first one's hooks say what it wrote.
$U claude
$U type "FAKE_CLAUDE_TURN=4 $BIN/agents/claude
"
sleep 1.5
$U type "first
"
FIRST=$(pgrep -nf "$BIN/agents/claude")
$U post "action newSession"; sleep 2
$U claude
$U type "FAKE_CLAUDE_TURN=3 $BIN/agents/claude
"
sleep 1.5
$U type "second
"
$U post "stage make"; sleep 0.5
event() { print -r "{\"side\":{\"agent\":\"claude\",\"ppid\":$FIRST,\"pid\":$$,\"at\":$(date +%s)},\"event\":$1}" > $INBOX/$(date +%s)-$RANDOM.json; }
event "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"aa-1\",\"cwd\":\"$P\",\"prompt\":\"Retry the login twice\"}"
printf 'func login() {\n  retry(2)\n}\n' > $P/Login.swift
event "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"aa-1\",\"cwd\":\"$P\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$P/Login.swift\",\"content\":\"func login() {\\n  retry(2)\\n}\\n\"}}"
event "{\"hook_event_name\":\"Stop\",\"session_id\":\"aa-1\",\"cwd\":\"$P\"}"
printf 'hi\nedited elsewhere\n' > $P/README.md
$U post hooks-read; sleep 6
i=$(items); echo "$i" | sed 's/^/     /'
check "both finished, out of sight" '[[ $(echo "$i" | grep -c finished) == 2 ]]' "$i"
# Changes on the whole branch first, so Review has something to change.
$U post "stage review"; sleep 2; $U post "queue-select branch"; sleep 1; $U post "stage make"; sleep 0.5
$U post activity-open; sleep 1
a0=$(hover 0); a1=$(hover 1)
check "hovered, the hooked session offers Review and Dismiss; the other only Dismiss" '[[ "$a0|$a1" == "Review,Dismiss|Dismiss" || "$a0|$a1" == "Dismiss|Review,Dismiss" ]]' "$a0|$a1"
$U post "activity-hover 0"; sleep 0.3
$U post "snapshot-all $OUT"; sleep 1.5
$U post "activity-hover 1"; sleep 0.3
mkdir -p $OUT/second; $U post "snapshot-all $OUT/second"; sleep 1.5
# Only the row under the pointer shows its actions.
$U post "activity-hover 0"; sleep 0.3
r=$( [[ $a0 == Review* ]] && echo 0 || echo 1 ); d=$(( 1 - r ))
$U post "activity-review $r"; sleep 3
c=$(actions)
check "Review: Changes, with the session's entry chosen" '[[ $c == *"chosen Retry the login twice"* ]]' "$c"
check "and it's dealt with: off the list" '[[ $(items | grep -c finished) == 1 ]]' "$(items)"
$U post "stage make"; sleep 0.5
$U post "activity-dismiss 0"; sleep 1
check "Dismiss puts the other away" '[[ -z $(items) ]]' "$(items)"
$U quit
echo "$failures failed; shots in $OUT"
