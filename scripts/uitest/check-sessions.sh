#!/bin/zsh
# Sessions, phase 1 (SIDE_RFC_SESSIONS.md): a program in a Terminal tab reports what it's doing
# (OSC 7501); its keeper keeps the record, and Side's session registry shows it, with the
# checkout it's in. Side's own reading stands in for a program that reports nothing.
#
#   SIDE_UIT=/tmp/side-uit-sessions scripts/uitest/uitest.sh build && SIDE_UIT=/tmp/side-uit-sessions scripts/uitest/check-sessions.sh
set -uo pipefail
U=$(dirname "$0")/uitest.sh
ROOT=${SIDE_UIT:-/tmp/side-uit}
OUT=$ROOT/check-sessions
rm -rf $OUT; mkdir -p $OUT
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1 (${3:-})"; failures=$((failures + 1)); fi; }
sessions() { $U post sessions-dump; sleep 0.8; awk '/^\[sessions\]$/{block=""; on=1; next} /^\[sessions-end\]$/{on=0} on{block=block $0 "\n"} END{printf "%s", block}' $ROOT/side.log; }

P=$ROOT/fixtures/sessions
rm -rf $P
mkdir -p $P && cd $P && git init -q -b main && echo "hello" > README.md && git add -A && git -c user.email=t@t -c user.name=t commit -qm init && git branch feature && git worktree add -q .claude/worktrees/fix feature
# What a reporting program sends: `report <state> [key=value…]`; a status report and a long wait.
cat > $P/.git/report <<'SH'
#!/bin/sh
state=$1; shift
pairs="state=$state"
for pair in "$@"; do pairs="$pairs:$pair"; done
printf '\033]7501;%s\007' "$pairs"
sleep 600
SH
chmod +x $P/.git/report
cd - > /dev/null

$U launch $P; sleep 2
$U post "window-size 1200 800" "stage run"; sleep 3
# "Run swift test?" in base64 is UnVuIHN3aWZ0IHRlc3Q/.
# Typed a character every 0.1 s: started in the project, so the path is short.
$U post "run-type .git/report blocked kind=permission msg=UnVuIHN3aWZ0IHRlc3Q/
"; sleep 9
s=$(sessions); echo "$s" | sed 's/^/     /'
check "the program's own report: needs permission, and why" '[[ $s == *"Needs permission | reported"*"Run swift test?"* ]]' "$s"
check "on the main folder's branch" '[[ $s == *"| main |"* ]]' "$s"
$U shot $OUT/blocked.png > /dev/null

# A second tab, in the agent's worktree, working at 40%.
$U post "run-new-tab"; sleep 2
$U post "run-type cd .claude/worktrees/fix && ../../../.git/report working progress=40
"; sleep 11
s=$(sessions); echo "$s" | sed 's/^/     /'
check "a session in an agent's worktree is on its branch" '[[ $s == *"Working | reported | feature |"* ]]' "$s"
check "needs-you comes first" '[[ $(echo "$s" | head -1) == *"Needs permission"* ]]' "$s"

$U quit
echo "$failures failed; captures in $OUT"
exit $(( failures > 0 ))
