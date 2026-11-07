#!/bin/zsh
# The jump bar (SIDE_DESIGN_SESSIONS_2026-11-06.md, session 2): one tick per message sent,
# placed where it falls in the conversation, a failed turn's tick in Failed's color; a jump
# brings the message into view; ⌥⌘↑ and ⌥⌘↓ step through them. A stand-in agent (fake-acp.py).
#
#   scripts/uitest/uitest.sh build && scripts/uitest/check-jump-bar.sh
set -uo pipefail
U=$(dirname "$0")/uitest.sh
ROOT=${SIDE_UIT:-/tmp/side-uit}
OUT=$ROOT/check-jump-bar
rm -rf $OUT; mkdir -p $OUT
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1 (${3:-})"; failures=$((failures + 1)); fi; }
jump() { $U post jump-dump; sleep 0.8; awk '/^\[jump\]$/{block=""; on=1; next} /^\[jump-end\]$/{on=0} on{block=block $0 "\n"} END{printf "%s", block}' $ROOT/side.log; }
field() { jump | awk -v key="$1" '$1==key{ $1=""; sub(/^ /,""); print }' | tail -1; }

P=$ROOT/fixtures/jump-bar
rm -rf $P
mkdir -p $P && cd $P && git init -q -b main && echo "hello" > README.md && git add -A && git -c user.email=t@t -c user.name=t commit -qm init
cd - > /dev/null

$U launch $P; sleep 2
$U post "window-size 1300 820" "think-track claude-code"; sleep 4
$U post "think-send First question LONG"; sleep 3
check "one message: no rail" '[[ $(field shown) == false ]]' "$(jump)"
$U post "think-send Second question FAIL"; sleep 3
$U post "think-send Third question LONG"; sleep 3
$U post "think-send Fourth question LONG"; sleep 3
j=$(jump)
check "a tick per message" '[[ $(echo $j | grep -c "^mark ") == 4 ]]' "$j"
fractions=($(echo $j | awk '$1=="mark"{print $3}'))
check "placed in order, down the conversation" '[[ ${fractions[1]} < ${fractions[2]} && ${fractions[2]} < ${fractions[3]} && ${fractions[3]} < ${fractions[4]} ]]' "${fractions[*]}"
check "the failed turn's tick says so" '[[ $(echo $j | grep "Second question") == *failed* ]]' "$j"
check "at the end, the last message is current" '[[ $(field current) == $(echo $j | awk "\$1==\"mark\"{id=\$2} END{print id}") ]]' "$j"
$U shot $OUT/rail.png > /dev/null
last=$(field current)
$U post jump-previous; sleep 0.8
prev=$(field current)
check "⌥⌘↑ goes to the message before" '[[ $prev != $last ]]' "$last $prev"
first=$(jump | awk '$1=="mark"{print $2; exit}')
$U post jump-previous; sleep 0.5; $U post jump-previous; sleep 0.8
check "and on to the first" '[[ $(field current) == $first ]]' "$(jump)"
$U shot $OUT/first.png > /dev/null
$U post jump-next; sleep 0.8
check "⌥⌘↓ goes forward" '[[ $(field current) != $first ]]' "$(jump)"

$U quit
echo "$failures failed; captures in $OUT"
exit $(( failures > 0 ))
