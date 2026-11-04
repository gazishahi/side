#!/bin/zsh
# Writes the six workloads (deterministic; ascii is Side's own Swift sources) and the 13 KB
# Claude-shaped burst the sessions and latency runs stream.
set -euo pipefail
here=${0:A:h}/..
out=$here/workloads; mkdir -p $out
(cd $here/VTBench && swift build -c release)
$here/VTBench/.build/release/VTBench $here/../../SIDE dump $out
python3 -I - $out <<'PY'
import sys
out = sys.argv[1]
d = open(f'{out}/tui.bin', 'rb').read()
mark = b'\x1b[?25l'
starts = [i for i in range(len(d)) if d.startswith(mark, i)][:40]
end = next(s for s in starts if s >= 10_000)
open(f'{out}/tui-burst.bin', 'wb').write(d[:end])
PY
ls -la $out
