#!/bin/zsh
# A PDF opens in Make (the owner, 2026-11-06: Side couldn't show one): its pages, between the
# top row and the bar; ⌘F finds in its text, a row per page, with no replace; ⌘G goes on.
#
#   scripts/uitest/uitest.sh build && scripts/uitest/check-pdf.sh
set -uo pipefail
U=$(dirname "$0")/uitest.sh
ROOT=${SIDE_UIT:-/tmp/side-uit}
OUT=$ROOT/check-pdf
rm -rf $OUT; mkdir -p $OUT
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1 (${3:-})"; failures=$((failures + 1)); fi; }
pdf() { $U post pdf-dump; sleep 0.6; grep '^\[pdf\]' $ROOT/side.log | tail -1; }

F=$ROOT/fixtures/pdf-project
mkdir -p $F
if [[ ! -f $F/doc.pdf ]]; then
  (for p in 1 2 3; do echo "Page $p of the fixture."; echo "The needle sits here on page $p."; for i in $(seq 1 55); do echo "filler line $i"; done; done) > $F/doc.txt
  cupsfilter -i text/plain $F/doc.txt > $F/doc.pdf 2>/dev/null
fi

$U launch; sleep 1.5
$U post "window-size 1100 760" "project-switch $F"; sleep 2.5
$U post "stage make" "open $F/doc.pdf"; sleep 1.5
line=$(pdf); echo "     $line"
check "the PDF shows, all its pages" '[[ $line == *"shown=true pages=3"* ]]' "$line"
$U shot $OUT/open.png > /dev/null
$U post "find needle"; sleep 1.2
line=$(pdf); echo "     $line"
check "find counts a match on each page, marks them, and offers no replace" '[[ $line == *"find=1 of 3"* && $line == *"marked=3"* && $line == *"replace=false"* ]]' "$line"
$U shot $OUT/find.png > /dev/null
$U post "key return"; sleep 0.8
$U post "key return"; sleep 1
line=$(pdf); echo "     $line"
# (cupsfilter breaks the pages its own way: the second and third matches are both on page 2.)
check "Return goes on to the last match" '[[ $line == *"find=3 of 3"* && $line == *"page=2"* ]]' "$line"
$U shot $OUT/third.png > /dev/null
$U quit
echo "$failures failed; captures in $OUT"
exit $(( failures > 0 ))
