#!/bin/zsh
# Sessions, phase 4 (SIDE_RFC_SESSIONS.md): Changes as a review queue. A stand-in session (a perl
# process running the real hook, as Claude Code would) writes Login.swift; README.md changes with
# no write Side saw. Changes lists the session by what it was asked, then what isn't
# attributed, then the whole branch; choosing one shows only its hunks.
#
#   SIDE_UIT=/tmp/side-uit-sessions scripts/uitest/uitest.sh build && SIDE_UIT=/tmp/side-uit-sessions scripts/uitest/check-review-queue.sh
set -uo pipefail
U=$(dirname "$0")/uitest.sh
ROOT=${SIDE_UIT:-/tmp/side-uit}
OUT=$ROOT/check-review-queue
rm -rf $OUT; mkdir -p $OUT
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1 (${3:-})"; failures=$((failures + 1)); fi; }
queue() { $U post queue-dump; sleep 0.8; awk '/^\[queue\]$/{block=""; on=1; next} /^\[queue-end\]$/{on=0} on{block=block $0 "\n"} END{printf "%s", block}' $ROOT/side.log; }

P=$ROOT/fixtures/review-queue
rm -rf $P; mkdir -p $P && cd $P && git init -q -b main && printf 'hi\n' > README.md && git add -A && git -c user.email=t@t -c user.name=t commit -qm init && cd - > /dev/null

$U launch $P; sleep 2
$U post "window-size 1280 800" "appearance light"; sleep 1
# What Side's hook folder is, for the stand-in to write to.
$U post hooks-dump; sleep 0.6
INBOX=$(grep '^\[hooks\]' $ROOT/side.log | tail -1 | sed 's/.*inbox=\([^ ]*\).*/\1/')
HOOK=$(dirname "$0")/../../SIDE/side-hook
send() { print -rn "$1" | SIDE_HOOKS_DIR=$INBOX perl -e 'open(my $h, "|-", "/bin/sh", $ARGV[0], "claude"); print $h <STDIN>; close $h' $HOOK; }

perl -e 'sleep 600' &
STAND_IN=$!
send "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"rq-1\",\"cwd\":\"$P\",\"prompt\":\"Fix the flaky login test\"}"
printf 'func login() {\n  retry(2)\n}\n' > $P/Login.swift
send "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"rq-1\",\"cwd\":\"$P\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$P/Login.swift\",\"content\":\"func login() {\\n  retry(2)\\n}\\n\"}}"
send "{\"hook_event_name\":\"Stop\",\"session_id\":\"rq-1\",\"cwd\":\"$P\"}"
printf 'hi\nedited elsewhere\n' > $P/README.md
sleep 1; $U post hooks-read; sleep 1
$U post "stage review"; sleep 3
q=$(queue); echo "$q" | sed 's/^/     /'
check "the session first, by what it was asked, with its file" '[[ $(echo "$q" | sed -n 1p) == "Fix the flaky login test | "*"| Login.swift" ]]' "$q"
check "then what no write Side saw explains" '[[ $(echo "$q" | sed -n 2p) == "Not attributed | "*"| README.md" ]]' "$q"
$U shot $OUT/queue.png > /dev/null
$U post "queue-select 1"; sleep 1.5
$U shot $OUT/unattributed.png > /dev/null
$U post "queue-select branch"; sleep 2
$U shot $OUT/branch.png > /dev/null
kill $STAND_IN 2>/dev/null
$U quit
echo "$failures failed; shots in $OUT"
exit $failures
