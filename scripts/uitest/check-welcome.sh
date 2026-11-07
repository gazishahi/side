#!/bin/zsh
# The welcome (SIDE_DESIGN_WELCOME.md): every page in light and dark, mid-animation and settled,
# for looking at; and that Help shows it, the pages move, and closing marks it seen.
#
#   scripts/uitest/uitest.sh build && scripts/uitest/check-welcome.sh
set -uo pipefail
U=$(dirname "$0")/uitest.sh
ROOT=${SIDE_UIT:-/tmp/side-uit}
OUT=$ROOT/check-welcome
rm -rf $OUT; mkdir -p $OUT
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1 (${3:-})"; failures=$((failures + 1)); fi; }
state() { $U post welcome-state; sleep 0.5; grep -a '^\[welcome\]' $ROOT/side.log | tail -1; }

$U launch; sleep 2
check "not shown on its own under UI testing" '[[ $(state) == *"shown=false"* ]]' "$(state)"
for look in ${=LOOKS:-dark light}; do
  $U post "appearance $look" "welcome-show 0"; sleep 0.4
  $U post "welcome-snapshot $OUT/$look-0-arriving.png"; sleep 1.6
  for page in 0 1 2 3 4 5; do
    $U post "welcome-go $page"; sleep 0.5
    $U post "welcome-snapshot $OUT/$look-$page-moving.png"; sleep ${SETTLE:-2.5}
    $U post "welcome-snapshot $OUT/$look-$page.png"; sleep 0.5
  done
  check "on the last page ($look)" '[[ $(state) == *"page=5"* ]]' "$(state)"
  $U post "welcome-close"; sleep 0.8
  check "closed ($look)" '[[ $(state) == *"shown=false"* ]]' "$(state)"
done
$U quit
echo "$failures failed; captures in $OUT"
exit $(( failures > 0 ))
