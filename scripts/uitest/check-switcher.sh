#!/bin/zsh
# The project switcher (⌃⌘P, the project chip) and the ⌃⇥ strip (SIDE_DESIGN_POLISH_0.5.md §2–3):
# a list by default, grown out of the stage bar and sitting just above it; open projects first;
# typing narrows; Return switches; ⌘⌫ puts a held project away; hover moves nothing. ⌃⇥ shows
# open projects only, a quick tap switches with no panel, letting go switches.
#
#   scripts/uitest/uitest.sh build && scripts/uitest/check-switcher.sh
set -uo pipefail
U=$(dirname "$0")/uitest.sh
ROOT=${SIDE_UIT:-/tmp/side-uit}
OUT=$ROOT/check-switcher
rm -rf $OUT; mkdir -p $OUT/open $OUT/close $OUT/cycle
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1 (${3:-})"; failures=$((failures + 1)); fi; }
last() { $U post "$1"; sleep 0.7; grep "$2" $ROOT/side.log | tail -1; }
switcher() { last switcher-dump '^\[switcher\]'; }
cycle() { last cycle-dump '^\[cycle\]'; }
project() { $U post activity-dump; sleep 0.7; awk '/^\[activity\]/{b=""} {b=b $0 "\n"} END{printf "%s", b}' $ROOT/side.log | awk '$1=="project"{print $2}' | tail -1; }

for name in webapp api old; do
  dir=$ROOT/fixtures/$name
  [[ -d $dir/.git ]] || (mkdir -p $dir && cd $dir && git init -q && echo x > a.txt && git add -A && git -c user.email=t@t -c user.name=t commit -qm init)
done

$U launch
$U post "window-size 1280 800" "switcher-layout list"; sleep 1
for name in old webapp api; do $U post "project-switch $ROOT/fixtures/$name"; sleep 2.5; done

$U post projects "snapshots $OUT/open 10 30"; sleep 1.2
line=$(switcher)
echo "     $line"
check "this window's project comes first, then the held ones" '[[ $line == *'"'"'entries=["api", "repo", "old", "webapp"]'"'"'* ]]' "$line"
check "Return goes somewhere new: the first one that isn't here" '[[ $line == *"selected=repo"* ]]' "$line"
# Above the stage bar, centred: its bottom edge near the window's bottom, not the top.
y=$(echo $line | sed -E 's/.*panel \(([0-9.]+), ([0-9.]+), ([0-9.]+), ([0-9.]+)\).*/\2/')
x=$(echo $line | sed -E 's/.*panel \(([0-9.]+), ([0-9.]+), ([0-9.]+), ([0-9.]+)\).*/\1/')
w=$(echo $line | sed -E 's/.*panel \(([0-9.]+), ([0-9.]+), ([0-9.]+), ([0-9.]+)\).*/\3/')
check "it sits just above the stage bar" '(( y > 40 && y < 110 ))' "y=$y"
check "centred in the window" '(( x + w / 2 > 630 && x + w / 2 < 650 ))' "x=$x w=$w"
$U shot $OUT/list.png > /dev/null
$U post "switcher-hover 1"; sleep 0.5
$U shot $OUT/hover.png > /dev/null
$U post "switcher-key down"; sleep 0.4

$U post "switcher-type wb"; sleep 0.5
line=$(switcher)
check "typing narrows, characters in order" '[[ $line == *'"'"'entries=["webapp"]'"'"'* && $line == *"selected=webapp"* ]]' "$line"
$U post "switcher-key return" "snapshots $OUT/close 8 30"; sleep 3
check "Return switches to it" '[[ $(project) == webapp ]]' "$(project)"
check "and the switcher closes" '[[ $(switcher) == *closed* ]]' "$(switcher)"

$U post projects; sleep 1
$U post "switcher-key putaway"; sleep 1
line=$(switcher)
# Held ones in their ⌃1–9 order (repo, old, api); the first, selected, is put away.
check "⌘⌫ puts the selected held project away; it stays, not open, last" '[[ $line == *'"'"'entries=["webapp", "old", "api", "repo"]'"'"'* ]]' "$line"
$U post "switcher-key escape"; sleep 0.5
check "Escape closes it" '[[ $(switcher) == *closed* ]]' "$(switcher)"

# A quick tap: no panel, straight to the next open project.
$U post cycle cycle-release; sleep 3
check "a quick ⌃⇥ switches with no panel" '[[ $(project) == old ]]' "$(project)"
$U post cycle; sleep 0.5
line=$(cycle)
echo "     $line"
check "held, the strip shows open projects only" '[[ $line == *"shown=true"* && $line != *repo* ]]' "$line"
$U shot $OUT/cycle.png > /dev/null
$U post "cycle" "snapshots $OUT/cycle 6 30"; sleep 0.6
line=$(cycle)
check "⇥ again moves on, the caption follows" '[[ $line == *"selected="* ]]' "$line"
$U post cycle-release; sleep 3
check "letting go switches" '[[ $(project) != old ]]' "$(project)"

# The file explorer: one floating surface at a time (the owner, 2026-11-05: it came out on a
# project switch, took the keyboard, and sat over the palette).
floating() { last floating-dump '^\[floating\]'; }
$U post "stage make"; sleep 1
$U post "project-switch $ROOT/fixtures/api"; sleep 2.5
check "a project switch doesn't bring the explorer out" '[[ $(floating) == *explorer=false* ]]' "$(floating)"
$U post "action toggleFileExplorer:"; sleep 0.8
check "the explorer opens" '[[ $(floating) == *explorer=true* ]]' "$(floating)"
$U post "action showQuickOpen:"; sleep 0.8
check "the palette puts the explorer away" '[[ $(floating) == "[floating] explorer=false palette=true" ]]' "$(floating)"
$U post "action toggleFileExplorer:"; sleep 0.8
check "the explorer puts the palette away" '[[ $(floating) == "[floating] explorer=true palette=false" ]]' "$(floating)"
$U post projects; sleep 0.8
check "the switcher puts the explorer away" '[[ $(floating) == *explorer=false* ]]' "$(floating)"
$U post "switcher-key escape"; sleep 0.5
$U post "action toggleFileExplorer:"; sleep 0.8
$U post "project-switch $ROOT/fixtures/webapp"; sleep 2.5
check "and a project switch puts it away" '[[ $(floating) == *explorer=false* ]]' "$(floating)"

$U quit
echo "$failures failed; captures in $OUT"
exit $(( failures > 0 ))
