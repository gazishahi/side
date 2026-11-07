#!/bin/zsh
# One Claude Code conversation in two terminals (the owner, 2026-11-05: tabs resumed
# conversations still running in terminals no tab showed, and both copies answered). The tab
# says so: Go There when a tab shows the other, End That One when none does, and ending it ends
# that terminal.
#
#   scripts/uitest/uitest.sh build && scripts/uitest/check-duplicate-claude.sh
set -uo pipefail
U=$(dirname "$0")/uitest.sh
ROOT=${SIDE_UIT:-/tmp/side-uit}
OUT=$ROOT/check-duplicate-claude; rm -rf $OUT; mkdir -p $OUT
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1 (${3:-})"; failures=$((failures + 1)); fi; }
notice() { $U post duplicate-dump; sleep 0.5; grep -a '^\[duplicate\]' $ROOT/side.log | tail -1 | sed 's/^\[duplicate\] //'; }
id=11111111-2222-4333-8444-555555555555

$U launch
$U post "window-size 1100 640"
$U post "stage run"; sleep 3
first=$(ls -t $ROOT/run/*.json | head -1 | xargs basename | sed 's/\.json$//')
$U claude; $U type "claude --session-id $id
"; sleep 1.5
check "one copy: no notice" '[[ $(notice) == none ]]' "$(notice)"
# A terminal no tab shows, running the same conversation: started straight from the keeper, a
# shell that runs claude, then let go, as the owner's was after its tab was closed.
orphan=0123456789abcdef
python3 - "$ROOT" "$orphan" "$id" <<'PY'
import json, os, socket, struct, subprocess, sys, time
root, sid, conversation = sys.argv[1:]
run = f"{root}/run"
spec = {"id": sid, "executable": "/bin/zsh", "arguments": ["-f", "-i"], "directory": root, "cols": 80, "rows": 24,
        "scrollbackLines": 1000, "client": {"project": "/elsewhere", "track": ""},
        "environment": [f"PATH={root}/bin/agents:/usr/bin:/bin", f"FAKE_CLAUDE_SESSIONS={root}/claude-config/sessions", "TERM=xterm-256color"]}
launch = f"{run}/{sid}.launch.json"
json.dump(spec, open(launch, "w"))
keeper = f"{root}/dd/Build/Products/Release/Side.app/Contents/Helpers/Side Session Keeper.app/Contents/MacOS/SideSessionKeeper"
subprocess.Popen([keeper, "--launch", launch], env={"SIDE_SESSIONS_DIR": run, "PATH": "/usr/bin:/bin"},
                 stdout=open(f"{run}/{sid}.log", "w"), stderr=subprocess.STDOUT, start_new_session=True)
for _ in range(100):
    if os.path.exists(f"{run}/{sid}.sock"): break
    time.sleep(0.05)
time.sleep(0.3)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(f"{run}/{sid}.sock")
def frame(kind, body): return bytes([kind]) + struct.pack('<I', len(body)) + body
s.sendall(frame(1, json.dumps({"build": "test"}).encode())); s.sendall(frame(2, json.dumps({"cols": 80, "rows": 24, "history": 0}).encode()))
time.sleep(0.5)
s.sendall(frame(4, f"claude --session-id {conversation}\r".encode()))
time.sleep(1.5)
s.sendall(frame(3, b"")); s.close()
PY
sleep 4
check "with no tab showing the other: End That One" '[[ $(notice) == "background $orphan" ]]' "$(notice)"
$U shot $OUT/background.png >/dev/null
pid=$(python3 -c "import json;print(json.load(open('$ROOT/run/$orphan.json'))['keeperPID'])")
$U post duplicate-end; sleep 3
check "ending it ends that terminal" '! kill -0 $pid 2>/dev/null' "keeper $pid"
check "and the notice goes" '[[ $(notice) == none ]]' "$(notice)"
$U post "action newSession"; sleep 3
$U claude; $U type "claude --resume $id
"; sleep 4
check "a second copy in another tab: Go There" '[[ $(notice) == "tab $first" ]]' "$(notice)"
$U shot $OUT/tab.png >/dev/null
$U quit
echo "$failures failed; captures in $OUT"
exit $(( failures > 0 ))
