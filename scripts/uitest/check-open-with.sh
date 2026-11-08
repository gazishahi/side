#!/bin/zsh
# Files from Finder's Open With or the Dock icon (2026-11-06): a file in the window's project
# opens there; a file in another repository opens that repository in a new window, in front of
# its remembered tabs; a folder opens as a project; a file in no project opens alone in a window
# of its own, the Editor only, Markdown on its preview, its folder not made a project.
#
#   scripts/uitest/uitest.sh build && scripts/uitest/check-open-with.sh
set -uo pipefail
U=$(dirname "$0")/uitest.sh
ROOT=${SIDE_UIT:-/tmp/side-uit}
OUT=$ROOT/check-open-with
rm -rf $OUT; mkdir -p $OUT
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1 (${3:-})"; failures=$((failures + 1)); fi; }
state() { $U post windows-dump; sleep 0.7; grep '^\[windows\]' $ROOT/side.log | tail -1; }

A=$ROOT/fixtures/pdf-project
B=$ROOT/fixtures/other-repo
mkdir -p $B/docs
[[ -d $B/.git ]] || (cd $B && git init -q && echo x > a.txt && echo "# Notes" > docs/notes.md && git add -A && git -c user.email=t@t -c user.name=t commit -qm init)
[[ -f $A/doc.pdf ]] || $(dirname "$0")/check-pdf.sh > /dev/null
echo "hello" > $A/hello.txt

$U launch; sleep 1.5
$U post "window-size 1100 760" "project-switch $A"; sleep 2.5
$U post "open-url file://$A/doc.pdf"; sleep 1.5
line=$(state); echo "     $line"
check "a file in this project opens here" '[[ $line == "[windows] pdf-project"*"model=doc.pdf"* && $line != *"||"* ]]' "$line"
$U post "open-url file://$B/docs/notes.md"; sleep 3
line=$(state); echo "     $line"
# (Not checked key: an app driven in the background has no key window.)
check "a file in another repository opens that repository in a new window" '[[ $line == *"|| other-repo"*"model=notes.md"* ]]' "$line"
mkdir -p $ROOT/fixtures/plain-folder
$U post "open-url file://$ROOT/fixtures/plain-folder/"; sleep 2.5
line=$(state); echo "     $line"
check "a folder opens as a project" '[[ $line == *"|| plain-folder"* ]]' "$line"
$U shot $OUT/other.png > /dev/null
L=$ROOT/fixtures/loose
mkdir -p $L
printf '# Loose notes\n\nRead **here**.\n' > $L/notes.md
cp $A/doc.pdf $L/loose.pdf
$U post "open-url file://$L/notes.md"; sleep 2
$U post "open-url file://$L/loose.pdf"; sleep 2
line=$(state); echo "     $line"
check "each loose file opens alone in a window of its own" '[[ $line == *"|| loose(loose)"*"model=notes.md"*"|| loose(loose)"*"model=loose.pdf"* ]]' "$line"
$U post "open-url file://$L/notes.md"; sleep 1.5
again=$(state)
$U post "snapshot-last $OUT/loose-pdf.png"; sleep 1
check "opening it again brings its window back, no new one" '[[ $(echo $again | grep -o "(loose)" | wc -l) -eq 2 ]]' "$again"
$U post "loose-dump"; sleep 0.6
loose=$(grep '^\[loose\]' $ROOT/side.log | tail -1); echo "     $loose"
$U post "open-url file://$L/notes.md"; sleep 1; $U post "snapshot-last $OUT/loose-last.png"; sleep 1
check "the Editor alone, Markdown on its preview, and no project made of its folder" '[[ $loose == *"stages=hidden chip=hidden preview=true"* && $loose != *"loose-in-projects"* ]]' "$loose"
$U post "loose-open-folder"; sleep 2.5
line=$(state); echo "     $line"
# (The key-window mark, "*", says nothing here: which window is key depends on timing.)
check "Open Folder as Project makes the window a project window, the file still open" '[[ $(echo $line | grep -o "(loose)" | wc -l) -eq 1 && ${line//\*/} == *"|| loose strip= model=notes.md"* ]]' "$line"
$U post "snapshot-last $OUT/folder-project.png"; sleep 1
$U quit
echo "$failures failed; captures in $OUT"
exit $(( failures > 0 ))
