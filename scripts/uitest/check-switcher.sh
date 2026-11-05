#!/bin/zsh
# The project switcher (⌃⌘P, the project chip) and the ⌃⇥ strip, designed with the owner on
# 2026-11-04: open projects first, the ones not open after them; typing narrows; Return switches;
# ⌘⌫ puts a held project away (it stays, under Not open); ⌃⇥ cycles and letting go switches.
#
#   scripts/uitest/uitest.sh build && scripts/uitest/check-switcher.sh
set -uo pipefail
U=$(dirname "$0")/uitest.sh
ROOT=${SIDE_UIT:-/tmp/side-uit}
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1 (${3:-})"; failures=$((failures + 1)); fi; }
last() { $U post "$1"; sleep 0.7; grep "$2" $ROOT/side.log | tail -1; }
switcher() { last switcher-dump '^\[switcher\]'; }
project() { $U post activity-dump; sleep 0.7; awk '/^\[activity\]/{b=""} {b=b $0 "\n"} END{printf "%s", b}' $ROOT/side.log | awk '$1=="project"{print $2}' | tail -1; }

for name in webapp api old; do
  dir=$ROOT/fixtures/$name
  [[ -d $dir/.git ]] || (mkdir -p $dir && cd $dir && git init -q && echo x > a.txt && git add -A && git -c user.email=t@t -c user.name=t commit -qm init)
done

$U launch
$U post "window-size 1280 800" "switcher-layout grid"; sleep 1
for name in old webapp api; do $U post "project-switch $ROOT/fixtures/$name"; sleep 2.5; done

$U post projects; sleep 1
line=$(switcher)
check "this window's project comes first, then the held ones" '[[ $line == *'"'"'entries=["api", "repo", "old", "webapp"]'"'"'* ]]' "$line"
check "Return goes somewhere new: the first one that isn't here" '[[ $line == *"selected=repo"* ]]' "$line"
check "the panel sits below the window's top, in it" '[[ $line == *"panel (260.0, 4"* ]]' "$line"

$U post "switcher-type wb"; sleep 0.5
line=$(switcher)
check "typing narrows, characters in order" '[[ $line == *'"'"'entries=["webapp"]'"'"'* && $line == *"selected=webapp"* ]]' "$line"
$U post "switcher-key return"; sleep 3
check "Return switches to it" '[[ $(project) == webapp ]]' "$(project)"
check "and the switcher closes" '[[ $(switcher) == *closed* ]]' "$(switcher)"

$U post projects; sleep 1
$U post "switcher-key putaway"; sleep 1
line=$(switcher)
# Held ones in their ⌃1–9 order (repo, old, api); the first, selected, is put away.
check "⌘⌫ puts the selected held project away; it stays, not open, last" '[[ $line == *'"'"'entries=["webapp", "old", "api", "repo"]'"'"'* ]]' "$line"
$U post "switcher-key escape"; sleep 0.5
check "Escape closes it" '[[ $(switcher) == *closed* ]]' "$(switcher)"

$U post cycle; sleep 0.3; $U post cycle; sleep 0.5; $U post cycle-release; sleep 3
# The first ⌃⇥ picks the next one (old), the second moves on (api).
check "⌃⇥ twice and letting go: two along" '[[ $(project) == api ]]' "$(project)"
$U post cycle-back; sleep 0.5; $U post cycle-release; sleep 3
# From the first, back one wraps to the last: repo, not open, opens again.
check "⌃⇧⇥ goes back, and a project not open opens" '[[ $(project) == repo ]]' "$(project)"

$U quit
echo "$failures failed"
exit $(( failures > 0 ))
