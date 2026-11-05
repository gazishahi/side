#!/bin/zsh
# Publishes Alloy to its public repository: every version is a tag *and* a GitHub Release, made
# in one go so the two can't drift apart. (Heron was published here too until it was retired,
# 2026-11-04; its repository is archived.)
#
#   scripts/publish-package.sh Alloy 0.7.4 "0.7.4: what changed"   copy, commit, push, wait for
#                                                                   CI, tag, release
#   scripts/publish-package.sh --release-only Alloy 0.7.4          the Release for a tag that
#                                                                   already exists (backfill)
#   DRY_RUN=1 scripts/publish-package.sh --release-only Alloy 0.7.4  print those notes only
#
# The commit message's first argument is its subject; set NOTES_BODY for a body (its "- " lines
# become sub-bullets in the release notes). Notes are the commits since the previous tag.
# Versions below 1.0 are ordinary releases, not pre-releases, so GitHub shows them as Latest.
set -euo pipefail
cd "$(dirname "$0")/.."

RELEASE_ONLY=0; [[ "${1:-}" == "--release-only" ]] && { RELEASE_ONLY=1; shift; }
PACKAGE="${1:?Alloy}"; VERSION="${2:?version, e.g. 0.7.4}"
case "$PACKAGE" in Alloy) ;; *) echo "Alloy only, not $PACKAGE (Heron is retired)" >&2; exit 1;; esac
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "version must be X.Y.Z" >&2; exit 1; }
REPO="gazishahi/${PACKAGE:l}"
AUTHOR_NAME="Gazi Shahi"; AUTHOR_EMAIL="74158471+gazishahi@users.noreply.github.com"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/publish-$PACKAGE.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
git clone -q "https://github.com/$REPO.git" "$WORK/repo"
ROOT=$PWD
cd "$WORK/repo"

if (( ! RELEASE_ONLY )); then
  SUBJECT="${3:?commit subject}"
  git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null && { echo "$VERSION is already tagged" >&2; exit 1; }
  [[ -z "$(git -C "$ROOT" status --porcelain -- "Packages/$PACKAGE")" ]] || { echo "Packages/$PACKAGE has uncommitted changes; publish commits only" >&2; exit 1; }
  echo "==> Copying Packages/$PACKAGE at $(git -C "$ROOT" rev-parse --short HEAD)"
  find . -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
  git -C "$ROOT" archive "HEAD:Packages/$PACKAGE" | tar -x
  git add -A
  git diff --cached --quiet && { echo "nothing changed since the last publish" >&2; exit 1; }
  # An array: `${NOTES_BODY:+-m "$NOTES_BODY"}` is one word in zsh ("-m <body>"), which made the
  # body start with a space and the notes skip its first bullet (Heron 0.1.2).
  message=(-m "$SUBJECT"); [[ -n "${NOTES_BODY:-}" ]] && message+=(-m "$NOTES_BODY")
  git -c user.name="$AUTHOR_NAME" -c user.email="$AUTHOR_EMAIL" commit -q "${message[@]}"
  git push -q origin HEAD
  SHA=$(git rev-parse HEAD)
  echo "==> Waiting for CI on ${SHA:0:7}"
  RUN=""
  for _ in {1..60}; do
    RUN=$(gh run list -R "$REPO" --commit "$SHA" --json databaseId -q '.[0].databaseId' 2>/dev/null || true)
    [[ -n "$RUN" ]] && break; sleep 5
  done
  [[ -n "$RUN" ]] || { echo "no CI run appeared for $SHA; not tagging" >&2; exit 1; }
  gh run watch "$RUN" -R "$REPO" --exit-status >/dev/null || { echo "CI failed on $SHA; not tagging ($(gh run view "$RUN" -R "$REPO" --json url -q .url))" >&2; exit 1; }
  git -c user.name="$AUTHOR_NAME" -c user.email="$AUTHOR_EMAIL" tag -a "$VERSION" -m "$PACKAGE $VERSION"
  git push -q origin "$VERSION"
  echo "==> Tagged $VERSION"
fi

git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null || { echo "no tag $VERSION" >&2; exit 1; }
[[ -z "${DRY_RUN:-}" ]] && gh release view "$VERSION" -R "$REPO" >/dev/null 2>&1 && { echo "$PACKAGE $VERSION already has a Release"; exit 0; }

# The notes: each commit since the previous tag, its "X.Y.Z: " prefix dropped, its body's
# "- " bullets under it.
PREVIOUS=$(git tag --sort=v:refname | awk -v v="$VERSION" '$0 == v { print prev; exit } { prev = $0 }')
RANGE="$VERSION"; [[ -n "$PREVIOUS" ]] && RANGE="$PREVIOUS..$VERSION"
NOTES="$WORK/notes.md"
{
  echo "## Changes"; echo
  for sha in $(git log --reverse --format=%H "$RANGE"); do
    subject=$(git log -1 --format=%s "$sha" | sed -E 's/^[0-9]+\.[0-9]+\.[0-9]+: //')
    [[ "$subject" == "Initial commit" ]] && continue
    echo "- ${(U)subject[1]}${subject[2,-1]}"
    # A body bullet may wrap onto indented lines: joined back into one.
    git log -1 --format=%b "$sha" | awk '{ sub(/^ +- /, "- ") } /^- / { if (item) print item; item = "  " $0; next }
      /^  +[^ ]/ && item { sub(/^ +/, ""); item = item " " $0; next }
      { if (item) print item; item = "" } END { if (item) print item }'
  done
  echo
  echo "Swift Package Manager: \`.package(url: \"https://github.com/$REPO.git\", from: \"$VERSION\")\`"
  [[ -n "$PREVIOUS" ]] && { echo; echo "**Full changelog:** https://github.com/$REPO/compare/$PREVIOUS...$VERSION"; }
} > "$NOTES"

[[ -n "${DRY_RUN:-}" ]] && { cat "$NOTES"; exit 0; }

# Latest only if no later version is tagged (a backfill of an old tag mustn't take it).
NEWEST=$(git tag --sort=v:refname | tail -1)
LATEST=false; [[ "$NEWEST" == "$VERSION" ]] && LATEST=true
gh release create "$VERSION" -R "$REPO" --verify-tag --title "$PACKAGE $VERSION" --notes-file "$NOTES" --latest="$LATEST" >/dev/null
echo "==> Released: https://github.com/$REPO/releases/tag/$VERSION"
