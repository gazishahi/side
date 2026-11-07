#!/bin/zsh
# Shared chats (SIDE_RFC_SHARED_CLAUDE_SESSIONS.md): an empty Agent stage offers Claude Code
# chats; Agent lists the folder's chats, marking the one running in a Terminal tab; that tab's
# Open in Agent brings its chat into Agent with its history (asking first, since both are live);
# another chat opens from the list; Continue in Terminal resumes the chat in a new tab.
# Claude Code is a stand-in here (fake-acp.py, fake claude), never the real one.
#
#   scripts/uitest/uitest.sh build && scripts/uitest/check-shared-chats.sh
set -uo pipefail
U=$(dirname "$0")/uitest.sh
ROOT=${SIDE_UIT:-/tmp/side-uit}
OUT=$ROOT/check-shared-chats
rm -rf $OUT; mkdir -p $OUT
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1 (${3:-})"; failures=$((failures + 1)); fi; }
agent() { $U post agent-dump; sleep 0.7; awk '/^\[agent\]$/{block=""; on=1; next} on && /^\[/{on=0} on{block=block $0 "\n"} END{printf "%s", block}' $ROOT/side.log; }
field() { agent | awk -v key="$1" '$1==key{ $1=""; sub(/^ /,""); print }' | tail -1; }
chats() { $U post agent-chats; sleep 2; awk '/^\[agent-chats\]$/{block=""; on=1; next} /^\[agent-chats-end\]$/{on=0} on{block=block $0 "\n"} END{printf "%s", block}' $ROOT/side.log; }

P=$ROOT/fixtures/shared-chats
rm -rf $P
mkdir -p $P && cd $P && git init -q -b main && echo "hello" > README.md && git add -A && git -c user.email=t@t -c user.name=t commit -qm init
cd - > /dev/null

$U launch $P; sleep 2
$U post "window-size 1300 800" "think-track claude-code"; sleep 4
check "an empty Agent stage offers Claude Code chats" '[[ $(field empty-offer) == true ]]' "$(agent)"
$U shot $OUT/empty.png > /dev/null

# A Claude Code chat in Terminal, on the same track.
$U post "stage run"; sleep 2.5
$U claude
$U type "claude
"
sleep 1.5
tab=$(agent | grep '^tab ' | grep '|claude|' | tail -1)
sid=${tab##*|}
check "the Terminal tab runs a chat Side knows the id of" '[[ -n $sid && $sid != - ]]' "$(agent)"

$U post "stage think"; sleep 1
list=$(chats)
check "Agent lists the folder's chats" '[[ $list == *earlier-chat* && $list == *$sid* ]]' "$list"
check "the one in Terminal is marked running there" '[[ $(echo $list | grep $sid) == *"Running in Terminal"* ]]' "$list"
$U post agent-chats-show; sleep 2
mkdir -p $OUT/picker; $U post "snapshot-all $OUT/picker"; sleep 1.5
$U post "key escape"; sleep 0.5

# Open in Agent, from the tab.
$U post "stage run"; sleep 1.5
$U post terminal-open-in-agent; sleep 3
check "Open in Agent goes to Agent" '[[ $(field stage) == think ]]' "$(field stage)"
check "it asked first: the chat is live in Terminal" '[[ $(field warned) != - ]]' "$(agent)"
check "the chat opened" '[[ $(field session) == $sid ]]' "$(agent)"
check "with its history drawn" '[[ $(field user) == *"Fix its width"* && $(field assistant) == *"measure once"* ]]' "$(agent)"
check "and the agent's plan" '[[ $(agent | grep -c "^plan ") == 3 ]]' "$(agent)"
$U shot $OUT/opened.png > /dev/null

# Another chat, from the list.
$U post "agent-open-chat earlier-chat"; sleep 3
check "a chat from the list opens" '[[ $(field session) == earlier-chat ]]' "$(agent)"

# Continue in Terminal.
$U post agent-continue-terminal; sleep 4
check "Continue in Terminal goes to Terminal" '[[ $(field stage) == run ]]' "$(field stage)"
check "Agent says so" '[[ $(field meta) == "Continued in Terminal." ]]' "$(agent)"
check "a new tab resumes the chat" '[[ $(agent | grep "^tab " | grep -c "|claude|earlier-chat") == 1 ]]' "$(agent | grep '^tab ')"
$U shot $OUT/continued.png > /dev/null

$U quit
echo "$failures failed; captures in $OUT"
exit $(( failures > 0 ))
