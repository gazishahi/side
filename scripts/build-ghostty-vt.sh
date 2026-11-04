#!/bin/zsh
# Builds libghostty-vt from the pinned Ghostty commit into Packages/SideSessions, where the session
# keeper links it statically. Build output (~50 MB), git-ignored. Needs Zig 0.17 (brew install zig).
# The same commit as Benchmarks/Terminal, so the benchmarks measure what ships.
set -euo pipefail
cd "$(dirname "$0")/.."
commit=${GHOSTTY_COMMIT:-c7f68a7f48c6a5b357689eb8c2328bc2dab5d8ed}
src=${GHOSTTY_SRC:-build/ghostty}
out=Packages/SideSessions/GhosttyVt.xcframework
if [[ -d $out && -f $out/.commit && "$(cat $out/.commit)" == "$commit" ]]; then echo "libghostty-vt $commit already built."; exit 0; fi
if [[ ! -d $src ]]; then git clone -q https://github.com/ghostty-org/ghostty "$src"; fi
git -C "$src" fetch -q origin "$commit" && git -C "$src" checkout -q "$commit"
(cd "$src" && zig build -Demit-lib-vt -Doptimize=ReleaseFast)
rm -rf "$out" && cp -R "$src/zig-out/lib/ghostty-vt.xcframework" "$out"
echo "$commit" > "$out/.commit"
echo "libghostty-vt $commit built into $out."
