#!/bin/zsh
# Drives a Release build of Side on screen, for checking UI work the way a person sees it.
#
#   scripts/uitest/uitest.sh build              copy the repo out of ~/Documents and build it
#   scripts/uitest/uitest.sh launch [project]   start it (UI-testing mode) on a project
#   scripts/uitest/uitest.sh post "<command>"…  send UI-testing commands (AppDelegate's list)
#   scripts/uitest/uitest.sh shot <file.png>    capture Side's front window
#   scripts/uitest/uitest.sh type "<text>"      type into the Terminal stage's shell
#   scripts/uitest/uitest.sh claude             put the stand-in `claude` first on the shell's PATH
#   scripts/uitest/uitest.sh quit               quit, and end its keepers and their shells
#
# Everything lives in $SIDE_UIT (default /tmp/side-uit), for two reasons:
# - out of ~/Documents: a build or test run from there waits on macOS's Documents prompt;
# - short: a keeper's socket path must fit in 104 bytes, and a deep folder made keepers fail to
#   start, so the Terminal stage couldn't be tested with real sessions.
set -euo pipefail
ROOT=${SIDE_UIT:-/tmp/side-uit}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
APP=$ROOT/dd/Build/Products/Release/Side.app
BIN=$ROOT/bin
mkdir -p $ROOT $BIN

tools() {
  [[ $BIN/post -nt $REPO/scripts/uitest/post.swift ]] || swiftc -O -o $BIN/post $REPO/scripts/uitest/post.swift
  mkdir -p $BIN/agents
  [[ $BIN/agents/claude -nt $REPO/scripts/uitest/fake-claude.c ]] || cc -O2 -o $BIN/agents/claude $REPO/scripts/uitest/fake-claude.c
}

case ${1:-} in
  build)
    tools
    rsync -a --delete --exclude build --exclude '.build' --exclude DerivedData $REPO/ $ROOT/repo/
    cd $ROOT/repo
    xcodebuild -project SIDE.xcodeproj -scheme SIDE -configuration Release -destination 'platform=macOS' \
      -skipPackagePluginValidation -derivedDataPath $ROOT/dd build 2>&1 | grep -E " error: |BUILD (SUCCEEDED|FAILED)"
    ;;
  launch)
    tools
    $0 quit 2>/dev/null || true
    mkdir -p $ROOT/run
    SIDE_SESSIONS_DIR=$ROOT/run "$APP/Contents/MacOS/Side" -SideUITesting YES -SideUITestingProject ${2:-$ROOT/repo} > $ROOT/side.log 2>&1 &
    echo $! > $ROOT/side.pid
    sleep 4
    ;;
  post)
    shift; $BIN/post "$@" ;;
  shot)
    # Side captures its own window (screencapture can't read a window by id here).
    $BIN/post "snapshot $2"; sleep 1; echo $2 ;;
  type)
    # Typed a character every 0.1 s; waits it out, so the next command doesn't type over it.
    shift; text="$*"; $BIN/post "run-type $text"; sleep $(( ${#text} * 0.1 + 0.5 )) ;;
  claude)
    # The shell's own startup files set PATH after Side's environment, so it's set in the shell.
    $0 type "export PATH=$BIN/agents:\$PATH; clear
" ;;
  quit)
    pkill -f "$APP/Contents/MacOS/Side" || true
    # Keepers outlive Side on purpose; the test ones don't.
    pkill -f "SideSessionKeeper.*$ROOT/run/" || true
    rm -rf $ROOT/run ;;
  *)
    sed -n 2,10p $0; exit 1 ;;
esac
