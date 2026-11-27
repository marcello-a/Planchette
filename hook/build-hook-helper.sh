#!/bin/sh
# Builds the native hook forwarder (hook/planchette-hook.c) with the Xcode / Command
# Line Tools clang — no other dependency.
#
#   hook/build-hook-helper.sh <output> [arch ...]
#
# Without an arch the binary is universal (arm64 + x86_64), as the app bundle ships
# it. The one place that knows the flags: scripts/package.sh, scripts/test-hook-helper.sh
# and the Swift tests all build through here, so a warning fails each of them alike.
set -eu

[ $# -ge 1 ] || { echo "usage: $0 <output> [arch ...]" >&2; exit 2; }
OUT="$1"
shift
[ $# -gt 0 ] || set -- arm64 x86_64

SRC="$(cd "$(dirname "$0")" && pwd)/planchette-hook.c"
ARCH_FLAGS=""
for arch in "$@"; do
    ARCH_FLAGS="$ARCH_FLAGS -arch $arch"
done

# 14.0 is the app's LSMinimumSystemVersion (scripts/package.sh): the helper runs
# wherever the app does.
# shellcheck disable=SC2086 # ARCH_FLAGS is a list of words on purpose
xcrun clang $ARCH_FLAGS \
    -std=c11 -O2 -mmacosx-version-min=14.0 \
    -Wall -Wextra -Wpedantic -Wshadow -Wconversion -Wsign-conversion -Werror \
    -o "$OUT" "$SRC"
