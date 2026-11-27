#!/bin/sh
# Tests for scripts/apply-ghostty-patches.sh and the patches in vendor/patches/ghostty.
#
#   sh scripts/test-ghostty-patches.sh
#
# 1. The apply script, in a throwaway repository: a patch is applied once, a second run
#    leaves it alone, a patch that does not fit stops with an error, and the order is the
#    name order.
# 2. Every real patch fits the pinned submodule: it applies, or it is already applied
#    (a CI cache, a local build). Read-only: git apply --check touches nothing.
#    Skipped with a note when the submodule is not checked out.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
APPLY="$HERE/apply-ghostty-patches.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- 1. The apply script --------------------------------------------------------------
repo="$TMP/ghostty"; patches="$TMP/patches"
mkdir -p "$repo/src" "$patches"
printf 'one\ntwo\nthree\n' > "$repo/src/a.txt"
git -C "$repo" init -q && git -C "$repo" add . && git -C "$repo" commit -qm base

# Two patches whose second needs the first: proves the name order.
cp "$repo/src/a.txt" "$TMP/orig"
sed 's/two/TWO/' "$TMP/orig" > "$repo/src/a.txt"
git -C "$repo" diff > "$patches/0001-two.patch"
sed 's/TWO/TWO\nfour/' "$repo/src/a.txt" > "$TMP/next" && cp "$TMP/next" "$repo/src/a.txt"
git -C "$repo" diff > "$TMP/both.patch"
git -C "$repo" checkout -q -- src
# 0002 is the diff from the 0001 state to the final state.
sed 's/two/TWO/' "$TMP/orig" > "$repo/src/a.txt" && git -C "$repo" add . && git -C "$repo" commit -qm tmp
cp "$TMP/next" "$repo/src/a.txt" && git -C "$repo" diff > "$patches/0002-four.patch"
git -C "$repo" reset -q --hard HEAD~1

run() { GHOSTTY_DIR="$repo" GHOSTTY_PATCHES_DIR="$patches" sh "$APPLY"; }

out="$(run)" || fail "first run failed: $out"
echo "$out" | grep -qx "applied 0001-two.patch" || fail "0001 not applied: $out"
echo "$out" | grep -qx "applied 0002-four.patch" || fail "0002 not applied in order: $out"
cmp -s "$repo/src/a.txt" "$TMP/next" || fail "result differs from the expected file"

out="$(run)" || fail "second run failed: $out"
[ "$(echo "$out" | grep -c '^already applied')" = 2 ] || fail "second run was not a no-op: $out"
cmp -s "$repo/src/a.txt" "$TMP/next" || fail "second run changed the file"
[ -z "$(git -C "$repo" diff --cached)" ] || fail "the index was touched"

# The submodule moved under the patch: stop, change nothing.
git -C "$repo" checkout -q -- src
printf 'one\nzwei\nthree\n' > "$repo/src/a.txt"
cp "$repo/src/a.txt" "$TMP/moved"
if run > "$TMP/out" 2>&1; then fail "a patch that does not fit did not stop the build"; fi
grep -q "error: the patches do not apply" "$TMP/out" || fail "no error for the misfit: $(cat "$TMP/out")"
cmp -s "$repo/src/a.txt" "$TMP/moved" || fail "a misfit changed the file"

# Half applied (0001 only): neither applies nor is applied — stop, change nothing.
git -C "$repo" checkout -q -- src
git -C "$repo" apply "$patches/0001-two.patch"
cp "$repo/src/a.txt" "$TMP/half"
if run > "$TMP/out" 2>&1; then fail "a half-applied series did not stop the build"; fi
cmp -s "$repo/src/a.txt" "$TMP/half" || fail "a half-applied series changed the file"

# --check-only changes nothing, and no run touches the repository's own index.
git -C "$repo" checkout -q -- src
index_before="$(shasum "$repo/.git/index")"
out="$(GHOSTTY_DIR="$repo" GHOSTTY_PATCHES_DIR="$patches" sh "$APPLY" --check-only)" || fail "check-only failed: $out"
echo "$out" | grep -qx "0002-four.patch applies" || fail "check-only output: $out"
cmp -s "$repo/src/a.txt" "$TMP/orig" || fail "check-only changed the file"
run > /dev/null || fail "apply after check-only failed"
[ "$(shasum "$repo/.git/index")" = "$index_before" ] || fail "the repository's index was written"
[ -z "$(git -C "$repo" diff --cached)" ] || fail "the index was touched"

# A path with a space survives the series.
git -C "$repo" checkout -q -- src
printf 'x\n' > "$repo/src/with space.txt" && git -C "$repo" add . && git -C "$repo" commit -qm space
printf 'y\n' > "$repo/src/with space.txt" && git -C "$repo" diff > "$patches/0003-space.patch"
git -C "$repo" checkout -q -- src
run > /dev/null || fail "a path with a space did not apply"
[ "$(cat "$repo/src/with space.txt")" = y ] || fail "the path with a space was not patched"
run > /dev/null || fail "a path with a space: the second run failed"
rm "$patches/0003-space.patch"

# No patches: nothing to do, success.
empty="$TMP/none"; mkdir "$empty"
GHOSTTY_DIR="$repo" GHOSTTY_PATCHES_DIR="$empty" sh "$APPLY" > /dev/null || fail "no patches failed"

# No sources: a clear error.
if GHOSTTY_DIR="$TMP/missing" GHOSTTY_PATCHES_DIR="$patches" sh "$APPLY" > /dev/null 2>&1; then
    fail "a missing submodule did not stop the build"
fi
echo "ok: apply script"

# --- 2. The real patches fit the pinned submodule -------------------------------------
GHOSTTY="${GHOSTTY_DIR:-$ROOT/vendor/ghostty}"
if [ ! -d "$GHOSTTY/src" ]; then
    echo "skip: $GHOSTTY is not checked out (git submodule update --init)"
    exit 0
fi
out="$(GHOSTTY_DIR="$GHOSTTY" sh "$APPLY" --check-only 2>&1)" || fail "the patches do not fit vendor/ghostty: $out"
echo "$out" | sed 's/^/ok: /'
