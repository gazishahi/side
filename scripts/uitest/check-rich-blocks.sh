#!/bin/zsh
# Rich blocks (SIDE_DESIGN_SESSIONS_2026-11-06.md, session 2): a finished message's Mermaid
# diagram, CSV and Markdown tables, SVG and an image in the project draw as themselves between
# its prose; Source shows the text; a column sorts; a diagram that doesn't parse says so.
# A stand-in agent (fake-acp.py).
#
#   scripts/uitest/uitest.sh build && scripts/uitest/check-rich-blocks.sh
set -uo pipefail
U=$(dirname "$0")/uitest.sh
ROOT=${SIDE_UIT:-/tmp/side-uit}
OUT=$ROOT/check-rich-blocks
rm -rf $OUT; mkdir -p $OUT
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1 (${3:-})"; failures=$((failures + 1)); fi; }
rich() { $U post rich-dump; sleep 0.8; awk '/^\[rich\]$/{block=""; on=1; next} /^\[rich-end\]$/{on=0} on{block=block $0 "\n"} END{printf "%s", block}' $ROOT/side.log; }

P=$ROOT/fixtures/rich-blocks
rm -rf $P
mkdir -p $P && cd $P && git init -q -b main && echo "hello" > README.md && git add -A && git -c user.email=t@t -c user.name=t commit -qm init
cd - > /dev/null

$U launch $P; sleep 2
$U post "window-size 1300 900" "think-track claude-code"; sleep 4
$U post "think-send Explain it RICH"; sleep 6
r=$(rich)
check "five blocks between the prose" '[[ $(echo $r | grep -c "^block ") == 5 ]]' "$r"
check "the diagram is drawn" '[[ $(echo $r | grep "block mermaid") == *drawn=* ]]' "$r"
check "the CSV is a table, quoted commas kept" '[[ $(echo $r | grep -m1 "block table") == *"rows=3"* ]]' "$r"
check "the Markdown table is one too" '[[ $(echo $r | grep -c "block table") == 2 ]]' "$r"
check "the SVG is a picture" '[[ $(echo $r | grep "block svg") == *picture=120x40* ]]' "$r"
check "the project's image is shown" '[[ $(echo $r | grep "block image") == *picture=200x60* ]]' "$r"
check "the prose stays bubbles" '[[ $(echo $r | grep "^bubbles") == "bubbles 3" ]]' "$r"
$U shot $OUT/rich.png > /dev/null
$U post "rich-action sort"; sleep 0.8
check "a column sorts, numbers as numbers" '[[ $(rich | grep -m1 "block table") == *first=Tabs,\ wide* ]]' "$(rich)"
$U post "rich-action source"; sleep 0.8
check "Source shows the text" '[[ $(rich | grep "block mermaid") == *source=true* ]]' "$(rich)"
$U shot $OUT/source.png > /dev/null

$U post "think-send Again RICH BAD"; sleep 6
check "a diagram that doesn't parse says so" '[[ $(rich | grep "block mermaid") == *problem=* ]]' "$(rich)"
$U shot $OUT/bad.png > /dev/null

$U quit
echo "$failures failed; captures in $OUT"
exit $(( failures > 0 ))
