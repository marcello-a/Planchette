#!/bin/sh
# Decide whether a push to main releases, and release it. The CI step after build + test.
#
#   scripts/auto-release.sh
#
# A push releases in two cases:
#
#   1. VERSION names a version that is not published yet — a release commit
#      written by hand (a minor or major bump, or a patch with its own notes).
#      That version goes out as written.
#   2. VERSION is already published, and the commits since the last release carry
#      a `feat:`, `fix:` or `perf:`. The patch number goes up by one, on a commit
#      of its own (`chore: release vX.Y.Z`), and that goes out.
#
# Anything else — chore, docs, test, style, refactor, ci — is a build and nothing
# more, so a merge that changes nothing a user can see does not offer an update.
# `[skip release]` in the head commit's message opts a push out of case 2.
#
# The release body is the version's CHANGELOG section (scripts/release.sh). In case
# 2 that section is made here: the `[Unreleased]` entries move under the new
# version, and when there are none, the section lists the commits instead, because
# an update with nothing to read is what this repo's release notes exist to avoid.
#
# Environment (for tests): AUTO_RELEASE_ROOT (the repo, default: this one),
# RELEASE_SCRIPT (default: scripts/release.sh), GH (default: gh).
set -eu

ROOT="${AUTO_RELEASE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
RELEASE_SCRIPT="${RELEASE_SCRIPT:-$ROOT/scripts/release.sh}"
GH="${GH:-gh}"
cd "$ROOT"

VERSION="$(tr -d '[:space:]' < VERSION)"
case "$VERSION" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) echo "error: VERSION says '$VERSION', which is not X.Y.Z" >&2; exit 1 ;;
esac

release() {
    echo "→ releasing v$1"
    sh "$RELEASE_SCRIPT" "$1"
}

# 1. A version nobody has published: it is the release.
if ! "$GH" release view "v$VERSION" >/dev/null 2>&1; then
    echo "→ VERSION names v$VERSION, which is not published yet."
    release "$VERSION"
    exit 0
fi

# 2. Published already: is there something new worth a patch release?
case "$(git log -1 --format=%B)" in
    *"[skip release]"*)
        echo "≡ [skip release] in the head commit — build + test only."
        exit 0 ;;
esac

LAST="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
RANGE="HEAD"
[ -z "$LAST" ] || RANGE="$LAST..HEAD"

# Merge commits name a pull request, not a change: the commits inside it speak.
SUBJECTS="$(git log --no-merges --format=%s "$RANGE")"
WORTH="$(printf '%s\n' "$SUBJECTS" | grep -E '^(feat|fix|perf)(\([^)]*\))?!?:' || true)"
if [ -z "$WORTH" ]; then
    echo "≡ no feat, fix or perf since ${LAST:-the start} — build + test only."
    exit 0
fi

# The next patch number nobody has used.
NEXT="$(printf '%s' "$VERSION" | awk -F. '{ printf "%d.%d.%d", $1, $2, $3 + 1 }')"
while git rev-parse -q --verify "refs/tags/v$NEXT" >/dev/null; do
    NEXT="$(printf '%s' "$NEXT" | awk -F. '{ printf "%d.%d.%d", $1, $2, $3 + 1 }')"
done
DATE="$(date -u +%Y-%m-%d)"
echo "→ ${LAST:-the start}..HEAD carries a feat, fix or perf: v$VERSION becomes v$NEXT."

# --- the CHANGELOG section ---------------------------------------------------

# Does `## [Unreleased]` hold anything?
has_unreleased() {
    awk '/^## \[Unreleased\]/ { inside = 1; next }
         inside && /^## \[/   { exit }
         inside && NF         { found = 1 }
         END                  { exit !found }' CHANGELOG.md
}

# "feat(scope): add a thing" -> "Add a thing"
sentence() {
    sed -E 's/^[a-z]+(\([^)]*\))?!?: *//' | awk '{ print toupper(substr($0, 1, 1)) substr($0, 2) }'
}

# The commits as a section, grouped the way the entries of this file are.
commit_section() {
    for group in "Added:feat" "Fixed:fix" "Changed:perf"; do
        heading="${group%%:*}"
        type="${group#*:}"
        lines="$(printf '%s\n' "$SUBJECTS" | grep -E "^$type(\([^)]*\))?!?:" | sentence || true)"
        [ -z "$lines" ] || {
            printf '\n### %s\n' "$heading"
            printf '%s\n' "$lines" | sed 's/^/- /'
        }
    done
}

SECTION="$(mktemp)"
trap 'rm -f "$SECTION" CHANGELOG.md.new' EXIT INT TERM
if has_unreleased; then
    # The entries stay where they are; the heading goes above them.
    printf '## [%s] — %s\n\n' "$NEXT" "$DATE" > "$SECTION"
else
    { printf '## [%s] — %s\n' "$NEXT" "$DATE"; commit_section; printf '\n'; } > "$SECTION"
fi

awk -v section="$SECTION" '
    { print }
    /^## \[Unreleased\]/ && !done {
        if ((getline blank) > 0) print blank
        while ((getline line < section) > 0) print line
        done = 1
    }' CHANGELOG.md > CHANGELOG.md.new
mv CHANGELOG.md.new CHANGELOG.md
printf '%s\n' "$NEXT" > VERSION

# --- the release commit ------------------------------------------------------

git config user.name >/dev/null 2>&1 || git config user.name "github-actions[bot]"
git config user.email >/dev/null 2>&1 || git config user.email "github-actions[bot]@users.noreply.github.com"
git add VERSION CHANGELOG.md
git commit -q -m "chore: release v$NEXT" \
    -m "Released automatically: ${LAST:-the start}..HEAD carries a feat, fix or perf commit."

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" != "HEAD" ] || BRANCH="${GITHUB_REF_NAME:-main}"   # a detached checkout still knows its branch in CI
if ! git push -q origin "HEAD:$BRANCH"; then
    # Somebody merged while this run was building. Their push starts a run of its
    # own, which sees everything since the last release — this one steps aside.
    echo "≡ $BRANCH moved on while this run was building: the run for the newer push releases." >&2
    exit 0
fi

release "$NEXT"
