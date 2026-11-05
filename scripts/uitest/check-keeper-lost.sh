#!/bin/zsh
# A terminal whose connection to its keeper ends while the keeper runs on (the owner, 2026-11-05:
# two Claude Code tabs said their sessions had ended; their keepers and Claude were still
# running). Another client takes the session, as a second Side would: the tab says so, a key
# brings it back, and it works; then its X still closes it.
#
#   scripts/uitest/uitest.sh build && scripts/uitest/check-keeper-lost.sh
set -uo pipefail
U=$(dirname "$0")/uitest.sh
ROOT=${SIDE_UIT:-/tmp/side-uit}
OUT=$ROOT/check-keeper-lost; rm -rf $OUT; mkdir -p $OUT
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1 (${3:-})"; failures=$((failures + 1)); fi; }
tabs() { $U post tabs-dump; sleep 0.4; grep -a "^\[tabs\]" $ROOT/side.log | tail -1 | sed 's/^\[tabs\] //'; }
count() { tabs | sed -E 's/.*model=(.*) active=.*/\1/' | tr '|' '\n' | grep -c . ; }
clients() { lsof -a -U -p $1 2>/dev/null | grep -c "\.sock" ; }

$U launch
$U post "window-size 1100 640"
$U post "stage run"; sleep 3
$U post "action newSession"; sleep 3
id=$(ls -t $ROOT/run/*.json | head -1 | xargs basename | sed 's/\.json$//')
pid=$(python3 -c "import json;print(json.load(open('$ROOT/run/$id.json'))['keeperPID'])")
check "two tabs" '[[ $(count) == 2 ]]' "$(tabs)"
check "Side is attached to the new tab's keeper" '[[ $(clients $pid) == 2 ]]' "$(clients $pid)"
# Another client attaches, then goes: the keeper is left with no one.
python3 - "$ROOT/run/$id.sock" <<'PY'
import json, socket, struct, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(sys.argv[1])
def frame(kind, obj): body = json.dumps(obj).encode(); return bytes([kind]) + struct.pack('<I', len(body)) + body
s.sendall(frame(1, {"build": "test"})); s.sendall(frame(2, {"cols": 80, "rows": 24, "history": 100}))
time.sleep(0.5); s.close()
PY
sleep 1.5
check "the keeper logged why it let Side go" 'grep -q "client let go: another client attached" $ROOT/run/$id.log' "$(cat $ROOT/run/$id.log)"
check "the keeper still runs" 'kill -0 $pid' ""
check "nothing is attached now" '[[ $(clients $pid) == 1 ]]' "$(clients $pid)"
$U shot $OUT/taken.png >/dev/null
$U type "x"
sleep 1.5
check "a key brings it back" '[[ $(clients $pid) == 2 ]]' "$(clients $pid)"
$U type "echo rejoined"
$U shot $OUT/rejoined.png >/dev/null
echo "     look: $OUT/rejoined.png shows the prompt and \"echo rejoined\" typed"
# Its X closes it.
$U post "tab-x 1"; sleep 1.5
check "its X closes it" '[[ $(count) == 1 ]]' "$(tabs)"
# The one tab left has an X too, after its name (⌘W was the only way).
$U post "action newSession"; sleep 2; $U post "tab-x 0"; sleep 1.5
before=$(ls -t $ROOT/run/*.json | head -1)
$U post tab-solo-hover; sleep 0.3; $U shot $OUT/solo.png >/dev/null
$U post "tab-x 0"; sleep 2.5
after=$(ls -t $ROOT/run/*.json | head -1)
check "the single tab's X closes it (a fresh terminal takes its place)" '[[ $after != $before ]]' "$before → $after"
$U quit
echo "$failures failed"
exit $(( failures > 0 ))
