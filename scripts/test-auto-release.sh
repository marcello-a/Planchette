#!/bin/sh
# Tests for scripts/auto-release.sh — what a push to main does about a release.
#
#   sh scripts/test-auto-release.sh
#
# Every scenario runs in a throwaway repository with its own bare "origin", a
# fake `gh` (a version counts as published when it is listed in $PUBLISHED_FILE)
# and a fake release script that only writes down what it was asked to release.
# Nothing here touches this repository, GitHub, or the network. CI runs it before
# the real release step, so a change to the rules fails there, not on a release day.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
AUTO="$HERE/auto-release.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

mkdir "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/bin/sh
[ "$1 $2" = "release view" ] || exit 2
grep -qx "$3" "$PUBLISHED_FILE"
EOF
cat > "$TMP/release-stub.sh" <<'EOF'
#!/bin/sh
echo "$1" >> "$RELEASED_FILE"
EOF
chmod +x "$TMP/bin/gh" "$TMP/release-stub.sh"

count=0
failures=0

expect() {   # expect <what> <actual> <expected>
    count=$((count + 1))
    if [ "$2" != "$3" ]; then
        failures=$((failures + 1))
        printf 'FAIL  %s\n      expected: %s\n      actual:   %s\n' "$1" "$3" "$2"
    fi
}

expect_contains() {   # expect_contains <what> <file> <text>
    count=$((count + 1))
    if ! grep -qF -- "$3" "$2"; then
        failures=$((failures + 1))
        printf 'FAIL  %s\n      "%s" is not in %s:\n' "$1" "$3" "$2"
        sed 's/^/        | /' "$2"
    fi
}

# A repository at v0.2.36, published, with an empty [Unreleased]. Sets R, ORIGIN, WORK.
new_repo() {
    name="$1"
    R="$TMP/$name"
    ORIGIN="$TMP/$name-origin.git"
    PUBLISHED_FILE="$TMP/$name.published"
    RELEASED_FILE="$TMP/$name.released"
    export PUBLISHED_FILE RELEASED_FILE
    : > "$RELEASED_FILE"
    echo v0.2.36 > "$PUBLISHED_FILE"
    git init -q --bare "$ORIGIN"
    git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
    git init -q "$R"
    git -C "$R" symbolic-ref HEAD refs/heads/main
    git -C "$R" remote add origin "$ORIGIN"
    echo 0.2.36 > "$R/VERSION"
    cat > "$R/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

## [0.2.36] — 2026-10-15

### Added
- **An old thing.** It was released.
EOF
    git -C "$R" add -A
    git -C "$R" commit -q -m "chore: release v0.2.36"
    git -C "$R" tag v0.2.36
    git -C "$R" push -q origin main --tags
}

commit() {   # commit <subject>
    echo "$1" >> "$R/changes.txt"
    git -C "$R" add -A
    git -C "$R" commit -q -m "$1"
}

run() {   # run the script in $R; its output goes to $R.out, its exit status to $STATUS
    STATUS=0
    AUTO_RELEASE_ROOT="$R" RELEASE_SCRIPT="$TMP/release-stub.sh" GH="$TMP/bin/gh" \
        sh "$AUTO" > "$R.out" 2>&1 || STATUS=$?
}

released() { tr '\n' ' ' < "$RELEASED_FILE" | sed 's/ $//'; }
head_subject() { git -C "$R" log -1 --format=%s; }
today() { date -u +%Y-%m-%d; }

# --- 1. a version nobody published goes out as written ---------------------------------

new_repo hand
echo 0.3.0 > "$R/VERSION"
printf '# Changelog\n\n## [Unreleased]\n\n## [0.3.0] — 2026-10-16\n\n### Added\n- **A big thing.**\n' > "$R/CHANGELOG.md"
git -C "$R" add -A
git -C "$R" commit -q -m "chore: release v0.3.0"
run
expect "hand bump: exit status" "$STATUS" 0
expect "hand bump: releases the version as written" "$(released)" "0.3.0"
expect "hand bump: makes no commit of its own" "$(head_subject)" "chore: release v0.3.0"

# --- 2. a feat with entries under [Unreleased]: patch bump, the entries move ----------------

new_repo entries
printf '### Added\n- **A new thing.** What it does.\n' > "$TMP/entry.txt"
awk -v entry="$TMP/entry.txt" '{ print } /^## \[Unreleased\]/ { print ""; while ((getline l < entry) > 0) print l }' "$R/CHANGELOG.md" > "$R/CHANGELOG.new"
mv "$R/CHANGELOG.new" "$R/CHANGELOG.md"
commit "feat: a new thing"
run
expect "entries: exit status" "$STATUS" 0
expect "entries: releases the next patch" "$(released)" "0.2.37"
expect "entries: VERSION" "$(cat "$R/VERSION")" "0.2.37"
expect "entries: the release commit" "$(head_subject)" "chore: release v0.2.37"
expect "entries: origin has the release commit" "$(git -C "$ORIGIN" rev-parse main)" "$(git -C "$R" rev-parse HEAD)"
expect_contains "entries: the heading is there" "$R/CHANGELOG.md" "## [0.2.37] — $(today)"
expect "entries: [Unreleased] is empty again, the heading comes first" \
    "$(awk '/^## \[/ { print; n++ } n == 3 { exit }' "$R/CHANGELOG.md" | tr '\n' '|')" \
    "## [Unreleased]|## [0.2.37] — $(today)|## [0.2.36] — 2026-10-15|"
expect "entries: the entry is under the new heading" \
    "$(awk '/^## \[0.2.37\]/ { inside = 1; next } /^## \[/ { inside = 0 } inside && /\*\*A new thing/' "$R/CHANGELOG.md")" \
    "- **A new thing.** What it does."

# --- 3. a fix and nothing under [Unreleased]: the section lists the commit ----------------------

new_repo commits
commit "fix(sidebar): stop the row from flickering"
commit "feat: a bar for long work"
run
expect "commits: releases the next patch" "$(released)" "0.2.37"
expect_contains "commits: a Fixed group" "$R/CHANGELOG.md" "### Fixed"
expect_contains "commits: the fix as a sentence" "$R/CHANGELOG.md" "- Stop the row from flickering"
expect_contains "commits: an Added group" "$R/CHANGELOG.md" "### Added"
expect_contains "commits: the feat as a sentence" "$R/CHANGELOG.md" "- A bar for long work"

# --- 4. perf counts, with a scope and a breaking mark ---------------------------------------------

new_repo perf
commit "perf(render)!: draw less"
run
expect "perf: releases" "$(released)" "0.2.37"
expect_contains "perf: listed under Changed" "$R/CHANGELOG.md" "### Changed"
expect_contains "perf: as a sentence" "$R/CHANGELOG.md" "- Draw less"

# --- 5. chore, docs, test, style and refactor are a build and nothing more -----------------------------

new_repo quiet
commit "chore: tidy"
commit "docs: words"
commit "test: more of them"
commit "style: spacing"
commit "refactor: move a function"
run
expect "quiet: exit status" "$STATUS" 0
expect "quiet: releases nothing" "$(released)" ""
expect "quiet: VERSION stays" "$(cat "$R/VERSION")" "0.2.36"
expect "quiet: no commit of its own" "$(head_subject)" "refactor: move a function"

# --- 6. [skip release] opts a push out --------------------------------------------------------------------

new_repo skip
commit "feat: a thing nobody needs to hear about yet [skip release]"
run
expect "skip: releases nothing" "$(released)" ""

# --- 7. a word that only looks like a type is not one ----------------------------------------------------------

new_repo lookalike
commit "feature: not a type"
commit "fixes: not a type"
commit "Feat: not a type either"
commit "update the thing"
run
expect "lookalike: releases nothing" "$(released)" ""

# --- 8. a merge commit names a pull request; the commits in it speak --------------------------------------------

new_repo merged
git -C "$R" checkout -q -b topic
commit "docs: only words"
git -C "$R" checkout -q main
git -C "$R" merge -q --no-ff topic -m "Merge pull request #1 from somebody/feat/topic"
run
expect "merge of a docs branch: releases nothing" "$(released)" ""

git -C "$R" checkout -q -b topic2
commit "fix: a real fix"
git -C "$R" checkout -q main
git -C "$R" merge -q --no-ff topic2 -m "Merge pull request #2 from somebody/topic2"
run
expect "merge of a fix branch: releases" "$(released)" "0.2.37"

# --- 9. a patch number that is taken is skipped ---------------------------------------------------------------------

new_repo taken
git -C "$R" tag v0.2.37
commit "feat: a thing"
run
expect "taken: skips to the next free number" "$(released)" "0.2.38"
expect "taken: VERSION" "$(cat "$R/VERSION")" "0.2.38"

# --- 10. main moved on while the run was building: this run steps aside -------------------------------------------------

new_repo raced
commit "feat: mine"
git clone -q "$ORIGIN" "$TMP/raced-other"
echo "theirs" > "$TMP/raced-other/theirs.txt"
git -C "$TMP/raced-other" add -A
git -C "$TMP/raced-other" commit -q -m "feat: theirs"
git -C "$TMP/raced-other" push -q origin main
run
expect "raced: exit status" "$STATUS" 0
expect "raced: releases nothing (the newer push does)" "$(released)" ""

# --- 11. a VERSION that is not X.Y.Z stops the run ---------------------------------------------------------------------

new_repo broken
echo "banana" > "$R/VERSION"
git -C "$R" add -A
git -C "$R" commit -q -m "chore: break the version"
run
count=$((count + 1))
[ "$STATUS" -ne 0 ] || { failures=$((failures + 1)); echo "FAIL  broken: a VERSION that is not X.Y.Z must fail the run"; }
expect "broken: releases nothing" "$(released)" ""

# ---------------------------------------------------------------------------------------------------------------------

if [ "$failures" -ne 0 ]; then
    echo "$failures of $count checks failed"
    exit 1
fi
echo "all $count checks passed"
