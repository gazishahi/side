#!/bin/zsh
# Sessions, phase 2 (SIDE_RFC_SESSIONS.md): Claude Code's hooks. Offered once in the session
# switcher; turned on, they go into Claude Code's settings (the test's own, never ~/.claude), and
# a session in any terminal shows in Side with what it's doing and why. A perl process stands in
# for Claude Code: it runs the real hook, as Claude Code would, and stays alive as the session.
#
#   SIDE_UIT=/tmp/side-uit-sessions scripts/uitest/uitest.sh build && SIDE_UIT=/tmp/side-uit-sessions scripts/uitest/check-hooks.sh
set -uo pipefail
U=$(dirname "$0")/uitest.sh
ROOT=${SIDE_UIT:-/tmp/side-uit}
OUT=$ROOT/check-hooks
HOME_=$ROOT/hooks-home
rm -rf $OUT $HOME_; mkdir -p $OUT
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1 (${3:-})"; failures=$((failures + 1)); fi; }
hooks() { $U post hooks-dump; sleep 0.6; grep '^\[hooks\]' $ROOT/side.log | tail -1; }
sessions() { $U post sessions-dump; sleep 0.8; awk '/^\[sessions\]$/{block=""; on=1; next} /^\[sessions-end\]$/{on=0} on{block=block $0 "\n"} END{printf "%s", block}' $ROOT/side.log; }

P=$ROOT/fixtures/hooks
rm -rf $P; mkdir -p $P && cd $P && git init -q -b main && echo hi > README.md && git add -A && git -c user.email=t@t -c user.name=t commit -qm init && cd - > /dev/null

$U launch $P; sleep 2
$U post "window-size 1100 700"; sleep 1
h=$(hooks)
check "not installed, and nowhere near ~/.claude" '[[ $h == *"status=notInstalled"* && $h == *"settings=$HOME_/claude/settings.json"* ]]' "$h"
$U post session-switcher; sleep 1
h=$(hooks)
check "the switcher offers them, once" '[[ $h == *"offer=true"* ]]' "$h"
$U shot $OUT/offer.png > /dev/null
$U post session-switcher-hooks-on; sleep 1
h=$(hooks)
check "Turn On puts them in" '[[ $h == *"status=installed"* ]]' "$h"
check "as Side's hook, in the test's settings" 'grep -q "hooks-home/side/bin/side-hook" $HOME_/claude/settings.json' "$(head -c 300 $HOME_/claude/settings.json)"
check "the hook is in place" '[[ -x $HOME_/side/bin/side-hook ]]'
$U post session-switcher; sleep 0.5

# A Claude Code session in another terminal: asked to fix a test, then asking to run one.
HOOK=$HOME_/side/bin/side-hook
INBOX=$HOME_/side/hooks
perl -e '
  my ($hook, $inbox, $cwd) = @ARGV;
  $ENV{SIDE_HOOKS_DIR} = $inbox;
  for my $event (
    qq({"hook_event_name":"SessionStart","session_id":"uit-1","cwd":"$cwd","source":"startup"}),
    qq({"hook_event_name":"UserPromptSubmit","session_id":"uit-1","cwd":"$cwd","prompt":"Fix the flaky login test"}),
    qq({"hook_event_name":"PermissionRequest","session_id":"uit-1","cwd":"$cwd","tool_name":"Bash","tool_input":{"command":"swift test --filter Login"}}),
  ) { open(my $h, "|-", $hook, "claude") or die; print $h $event; close $h; select(undef, undef, undef, 0.05); }
  sleep 600;
' $HOOK $INBOX $P &
STAND_IN=$!
sleep 2
$U post hooks-read; sleep 1
s=$(sessions); echo "$s" | sed 's/^/     /'
check "the session shows, by what it was asked" '[[ $s == *"Fix the flaky login test | claude | Needs permission | reported"* ]]' "$s"
check "with what it wants" '[[ $s == *"Wants to run swift test --filter Login"* ]]' "$s"
$U post session-switcher; sleep 1
$U shot $OUT/session.png > /dev/null
$U post session-switcher; sleep 0.3

# It goes on, and finishes.
print -n '{"hook_event_name":"PostToolUse","session_id":"uit-1","tool_name":"Bash"}' | SIDE_HOOKS_DIR=$INBOX perl -e 'open(my $h, "|-", $ARGV[0], "claude"); print $h <STDIN>; close $h' $HOOK
print -n '{"hook_event_name":"Stop","session_id":"uit-1"}' | SIDE_HOOKS_DIR=$INBOX perl -e 'open(my $h, "|-", $ARGV[0], "claude"); print $h <STDIN>; close $h' $HOOK
sleep 1; $U post hooks-read; sleep 1
s=$(sessions)
check "and finishes" '[[ $s == *"Fix the flaky login test | claude | Finished"* ]]' "$s"
kill $STAND_IN 2>/dev/null

$U post session-switcher; sleep 1
h=$(hooks)
check "on, the offer isn't made again" '[[ $h == *"offer=false"* ]]' "$h"
$U post session-switcher; sleep 0.3
$U post "settings agents"; sleep 1.5
$U post "snapshot-all $OUT/settings"; sleep 1.5
$U quit
echo "$failures failed; shots in $OUT"
exit $failures
