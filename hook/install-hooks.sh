#!/bin/sh
# Installs the Planchette hooks into ~/.claude/settings.json (merge, not
# overwrite; existing hooks stay untouched). A timestamped backup is written
# next to the file. Safe to re-run — installs are idempotent.
set -eu

HOOK_BIN="$(cd "$(dirname "$0")" && pwd)/planchette-hook"
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"

[ -x "$HOOK_BIN" ] || { echo "planchette-hook not found/executable at $HOOK_BIN" >&2; exit 1; }

python3 - "$SETTINGS" "$HOOK_BIN" <<'PY'
import json, shutil, sys, time
from pathlib import Path

settings_path = Path(sys.argv[1])
hook_bin = sys.argv[2]
events = ["SessionStart", "UserPromptSubmit", "Notification", "Stop", "SessionEnd"]

settings = {}
if settings_path.exists():
    settings = json.loads(settings_path.read_text() or "{}")
    backup = settings_path.with_suffix(f".json.planchette-bak-{time.strftime('%Y%m%d%H%M%S')}")
    shutil.copy2(settings_path, backup)
    print(f"backup: {backup}")

hooks = settings.setdefault("hooks", {})
for event in events:
    entries = hooks.setdefault(event, [])
    already = any(
        h.get("command") == hook_bin
        for entry in entries
        for h in entry.get("hooks", [])
    )
    if not already:
        entries.append({"hooks": [{"type": "command", "command": hook_bin}]})
        print(f"installed: {event}")
    else:
        print(f"already installed: {event}")

settings_path.parent.mkdir(parents=True, exist_ok=True)
settings_path.write_text(json.dumps(settings, indent=2) + "\n")
print(f"written: {settings_path}")
PY
