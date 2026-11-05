#!/bin/zsh
# Copies Benchmarks/Terminal and its write-up into a checkout of the public side-terminal-bench
# repository (github.com/gazishahi/side-terminal-bench), so others can re-run the benchmarks and
# check the results. Only files git tracks or would track are copied: no workloads, xcframeworks,
# builds or recordings. References to Side's private docs become plain names. Commit and push
# from the checkout yourself, after reading the diff.
#
#   scripts/export-terminal-bench.sh ~/src/side-terminal-bench
set -euo pipefail
cd "$(dirname "$0")/.."
dest=${1:?a checkout of side-terminal-bench}
[[ -d $dest/.git ]] || { echo "$dest is not a git checkout" >&2; exit 1; }

find $dest -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
(cd Benchmarks/Terminal && git ls-files -co --exclude-standard -z | rsync -a --from0 --files-from=- ./ $dest/)
mkdir -p $dest/docs
cp docs/SIDE_TERMINAL_BENCHMARKS_2026-11-03.md $dest/docs/BENCHMARKS_2026-11-03.md
cp Packages/Alloy/LICENSE $dest/LICENSE
cat > $dest/NOTICE <<'EOF'
side-terminal-bench
Copyright 2026 Gazi Shahi

This product is licensed under the Apache License, Version 2.0 (see LICENSE).

TermBench/Sources/Harness/AlloyGlyphAtlas.swift is vendored from Alloy
(https://github.com/gazishahi/alloy), Apache License 2.0.

Not included, fetched when built: Ghostty and libghostty-vt (https://github.com/ghostty-org/ghostty,
MIT) by scripts/build-ghostty.sh, and SwiftTerm (https://github.com/migueldeicaza/SwiftTerm, MIT)
by Swift Package Manager.
EOF

# Paths as they are in this repository, and Side's private docs by name.
(cd $dest && git ls-files -co --exclude-standard -z | xargs -0 perl -pi -e '
      BEGIN { @ARGV = grep { -T } @ARGV }
      s{`Benchmarks/Terminal/`}{this repository}g;
      s{Benchmarks/Terminal/}{}g;
      s{docs/SIDE_TERMINAL_BENCHMARKS_}{docs/BENCHMARKS_}g;
      s{`?docs/SIDE_RFC_TERMINAL_ENGINE\.md`?}{Side\x27s terminal engine RFC}g;
      s{`?docs/SIDE_RFC_SESSION_RESTORE\.md`?}{Side\x27s session restore RFC}g;
      s{Packages/Alloy/Sources/AlloyRender}{Alloy\x27s AlloyRender, github.com/gazishahi/alloy}g;
    ')
echo "exported to $dest; review with: git -C $dest status && git -C $dest diff"
