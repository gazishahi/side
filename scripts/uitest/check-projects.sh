#!/bin/zsh
# Project switching with Claude Code working in the project left behind: the activity pill says
# so from the other project, and its click brings this window back to it (2026-11-04: a new
# window opened instead).
#
#   scripts/uitest/uitest.sh build && scripts/uitest/check-projects.sh
set -uo pipefail
U=$(dirname "$0")/uitest.sh
ROOT=${SIDE_UIT:-/tmp/side-uit}
OTHER=$ROOT/fixtures/webapp
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1 (${3:-})"; failures=$((failures + 1)); fi; }
dump() { $U post activity-dump; sleep 0.7; awk '/^\[activity\]/{b=""} {b=b $0 "\n"} END{printf "%s", b}' $ROOT/side.log; }
field() { dump | awk -v key="$1" '$1==key{ $1=""; sub(/^ /,""); print }' | tail -1; }

# A second project, with a logo where web projects keep one.
if [[ ! -d $OTHER/.git ]]; then
  mkdir -p $OTHER/public
  print '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="14" fill="#6d28d9"/></svg>' > $OTHER/public/favicon.svg
  (cd $OTHER && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm init)
fi

$U launch
$U post "window-size 1000 600" "stage run"; sleep 3
$U claude
$U type "FAKE_CLAUDE_TURN=6 claude
"
$U type "go
"
$U post "project-switch $OTHER"; sleep 2.5
check "the window shows the other project" '[[ $(field project) == webapp ]]' "$(field project)"
check "the pill says what's working in the first" '[[ $(field pill) == "Claude Code working" ]]' "$(field pill)"
sleep 6
check "and that it finished" '[[ $(field pill) == "Claude Code finished" ]]' "$(field pill)"
$U post "activity-open"; sleep 2.5
check "its click brings this window back to that project" '[[ $(field project) == repo && $(field windows) == 1 ]]' "$(field project), $(field windows) windows"
check "on its Terminal tab" '[[ $(field stage) == run && $(field pill) == "-" ]]' "$(field stage), pill $(field pill)"
$U quit
echo "$failures failed"
exit $(( failures > 0 ))
