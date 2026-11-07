#!/bin/zsh
# Agent's branch panel (SIDE_RFC_AGENT_PANEL.md): docked beside the conversation on a wide
# window, with the agent's plan, the branch's changed files, its terminals and checkpoints;
# hidden on a narrow one until asked for, then floating over the conversation's edge, closed by
# Escape; docked again once the window is wide; the toggle hides and shows it.
# Claude Code is a stand-in (fake-acp.py), never the real one.
#
#   scripts/uitest/uitest.sh build && scripts/uitest/check-agent-panel.sh
set -uo pipefail
U=$(dirname "$0")/uitest.sh
ROOT=${SIDE_UIT:-/tmp/side-uit}
OUT=$ROOT/check-agent-panel
rm -rf $OUT; mkdir -p $OUT
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1 (${3:-})"; failures=$((failures + 1)); fi; }
panel() { $U post agent-panel-dump; sleep 1.2; awk '/^\[agent-panel\]$/{block=""; on=1; next} /^\[agent-panel-end\]$/{on=0} on{block=block $0 "\n"} END{printf "%s", block}' $ROOT/side.log; }
field() { panel | awk -v key="$1" '$1==key{ $1=""; sub(/^ /,""); print }' | tail -1; }

P=$ROOT/fixtures/agent-panel
rm -rf $P
mkdir -p $P && cd $P && git init -q -b main && echo "hello" > README.md && git add -A && git -c user.email=t@t -c user.name=t commit -qm init
cd - > /dev/null

$U launch $P; sleep 2
$U post "window-size 1400 860" "think-track claude-code"; sleep 4
# A terminal on the branch, running something.
$U post "stage run"; sleep 2.5
$U claude
$U type "claude
"
$U post "stage think"; sleep 1
$U post "think-send Fix the pill"; sleep 5
p=$(panel)
check "docked on a wide window" '[[ $(field docked) == true ]]' "$p"
check "the column makes room for it" '[[ $(field column-trailing) -gt 280 ]]' "$p"
check "the agent's plan" '[[ $(echo $p | grep -c "^plan ") == 3 && $p == *"plan completed Fix its width"* ]]' "$p"
check "the branch's changed files" '[[ $p == *"file NOTES.md +3 -0"* ]]' "$p"
check "its terminals" '[[ $p == *"terminal "* ]]' "$p"
check "its checkpoints" '[[ $p == *"checkpoint Fix the pill"* ]]' "$p"
$U shot $OUT/docked.png > /dev/null

$U post "window-size 1000 760"; sleep 1.5
check "hidden on a narrow window" '[[ $(field shown) == false && $(field column-trailing) == 0 ]]' "$(panel)"
$U post agent-panel-toggle; sleep 1.2
check "the toggle floats it over the conversation" '[[ $(field shown) == true && $(field docked) == false && $(field column-trailing) == 0 ]]' "$(panel)"
$U shot $OUT/floating.png > /dev/null
$U post "key escape"; sleep 0.8
check "Escape closes it" '[[ $(field shown) == false ]]' "$(panel)"
$U post agent-panel-toggle; sleep 0.8
$U post "window-size 1400 860"; sleep 1.5
check "wide again: it docks" '[[ $(field docked) == true ]]' "$(panel)"
$U post agent-panel-toggle; sleep 0.8
check "the toggle hides it when docked" '[[ $(field shown) == false && $(field column-trailing) == 0 ]]' "$(panel)"
$U post agent-panel-toggle; sleep 0.8
check "and shows it again" '[[ $(field docked) == true ]]' "$(panel)"

$U quit
echo "$failures failed; captures in $OUT"
exit $(( failures > 0 ))
