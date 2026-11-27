#!/bin/sh
# Applies Planchette's patches (vendor/patches/ghostty/*.patch, in name order) to the pinned
# vendor/ghostty submodule before GhosttyKit is built:
#
#   sh scripts/apply-ghostty-patches.sh               # apply (a no-op when applied)
#   sh scripts/apply-ghostty-patches.sh --check-only  # say what it would do, change nothing
#
# Idempotent: a series that is applied already is left alone, so a second run, a CI cache and
# a local re-build all work. A series that neither applies nor is applied stops the build —
# the submodule moved under it. The patches are a series: a later one may change what an
# earlier one changed, so each is tried on the result of the one before, in a scratch index
# (GIT_INDEX_FILE): the working tree and the submodule's own index stay untouched until the
# whole series is known to fit.
#
# Each patch is its own reviewed change, like a bump of the pin (AGENTS.md, ground rule 2).
set -eu

CHECK_ONLY=false
[ "${1:-}" = "--check-only" ] && CHECK_ONLY=true

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GHOSTTY="${GHOSTTY_DIR:-$ROOT/vendor/ghostty}"
PATCHES="${GHOSTTY_PATCHES_DIR:-$ROOT/vendor/patches/ghostty}"

[ -d "$GHOSTTY/src" ] || { echo "error: $GHOSTTY has no sources (git submodule update --init)" >&2; exit 1; }

set --
for patch in "$PATCHES"/*.patch; do
    [ -e "$patch" ] && set -- "$@" "$patch"
done
[ $# -gt 0 ] || exit 0

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT INT TERM

# simulate <-R or ""> <patch>...: whether the patches, in the given order, apply one after
# the other to the working tree's current content. Only a scratch index is written.
simulate() {
    flag="$1"; shift
    index="$SCRATCH/index"
    rm -f "$index"
    GIT_INDEX_FILE="$index" git -C "$GHOSTTY" read-tree HEAD || return 1
    # The files the patches touch, as they are in the working tree now.
    for patch in "$@"; do
        git -C "$GHOSTTY" apply --numstat "$patch" | cut -f3-
    done | sort -u | GIT_INDEX_FILE="$index" git -C "$GHOSTTY" update-index --add --remove --stdin || return 1
    for patch in "$@"; do
        GIT_INDEX_FILE="$index" git -C "$GHOSTTY" apply --cached $flag "$patch" 2>/dev/null || return 1
    done
}

names() { for patch in "$@"; do basename "$patch"; done; }

if simulate "" "$@"; then
    if $CHECK_ONLY; then
        names "$@" | sed 's/$/ applies/'
        exit 0
    fi
    for patch in "$@"; do
        git -C "$GHOSTTY" apply "$patch"
        echo "applied $(basename "$patch")"
    done
    exit 0
fi

# Applied already: the series comes off again, last patch first.
reversed=""
for patch in "$@"; do reversed="$patch
$reversed"; done
old_ifs="$IFS"; IFS='
'
# shellcheck disable=SC2086 # split on newlines only: the reversed list
set -- $reversed
IFS="$old_ifs"
if simulate "-R" "$@"; then
    names "$@" | sort | sed 's/^/already applied /'
    exit 0
fi

echo "error: the patches do not apply to $(git -C "$GHOSTTY" describe --tags 2>/dev/null || echo vendor/ghostty):" >&2
names "$@" | sort | sed 's/^/  /' >&2
exit 1
