#!/bin/sh
# Tests for the native hook forwarder (hook/planchette-hook.c) against the shell
# script it replaces (hook/planchette-hook).
#
#   sh scripts/test-hook-helper.sh             # build, then the differential cases
#   sh scripts/test-hook-helper.sh --bench 200 # build, then CPU per event, 200 runs each
#
# Builds the helper the way scripts/package.sh does (universal, every warning an
# error), checks that both slices are there, and runs scripts/hook_helper_diff.py:
# both forwarders against fake app sockets in /tmp, byte for byte — for the native
# slice, and for the x86_64 slice under Rosetta where it is installed. Nothing here
# touches ~/.planchette, ~/.claude or a running Planchette. CI runs it next to
# `swift test`.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

HELPER="$TMP/planchette-hook"
sh "$ROOT/hook/build-hook-helper.sh" "$HELPER"
ARCHS="$(lipo -archs "$HELPER")"
for arch in arm64 x86_64; do
    case " $ARCHS " in
        *" $arch "*) ;;
        *) echo "FAIL  the helper has no $arch slice (it has: $ARCHS)" >&2; exit 1 ;;
    esac
done
echo "built $HELPER ($ARCHS)"

# The shell script must stay valid: it is the fallback the app installs when the
# helper cannot run.
sh -n "$ROOT/hook/planchette-hook"

python3 "$HERE/hook_helper_diff.py" "$ROOT/hook/planchette-hook" "$HELPER" "$@"

# The other slice: an Intel Mac runs the x86_64 one. On Apple silicon it runs under
# Rosetta, when that is installed.
case "${1:-}" in --bench) exit 0 ;; esac
if [ "$(uname -m)" = arm64 ] && arch -x86_64 /usr/bin/true 2>/dev/null; then
    lipo "$HELPER" -thin x86_64 -output "$TMP/planchette-hook-x86_64"
    echo
    echo "the x86_64 slice, under Rosetta:"
    python3 "$HERE/hook_helper_diff.py" "$ROOT/hook/planchette-hook" "$TMP/planchette-hook-x86_64" "$@"
else
    echo "skipped the x86_64 slice: no Rosetta here"
fi
