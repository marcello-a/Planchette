#!/bin/sh
# Installs the Planchette integrations for a dev run (the packaged .app does
# this itself on launch, see HookInstaller.swift):
#   - Claude Code hooks in ~/.claude/settings.json
#   - Codex session claim in ~/.codex/hooks.json + [features] hooks in config.toml
#   - the control CLI at ~/.planchette/planchette, which terminals get as
#     $PLANCHETTE_CLI
# Merges rather than overwrites; existing hooks stay untouched and a timestamped
# backup is written next to each file. Safe to re-run — installs are idempotent.
set -eu

HOOK_BIN="$(cd "$(dirname "$0")" && pwd)/planchette-hook"
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"

[ -x "$HOOK_BIN" ] || { echo "planchette-hook not found/executable at $HOOK_BIN" >&2; exit 1; }

python3 - "$SETTINGS" "$HOOK_BIN" <<'PY'
import json, os, shutil, stat, sys, time
from pathlib import Path

settings_path = Path(sys.argv[1])
hook_bin = sys.argv[2] + " claude"   # agent label, see planchette-hook
# Keep in step with HookInstaller.events (Swift). PreToolUse/PostToolUse are the
# only proof that a granted permission moved the turn on, and SubagentStop is
# deliberately mapped to "no state change" — without them a dev run behaves
# differently from the packaged app.
events = [
    "SessionStart", "UserPromptSubmit", "Notification", "PermissionRequest",
    "PreToolUse", "PostToolUse", "Stop", "SubagentStop", "SessionEnd",
]
tool_events = {"PreToolUse", "PostToolUse"}   # per-tool entries: matcher "*"

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
        entry = {"hooks": [{"type": "command", "command": hook_bin}]}
        if event in tool_events:
            entry["matcher"] = "*"
        entries.append(entry)
        print(f"installed: {event}")
    else:
        print(f"already installed: {event}")

settings_path.parent.mkdir(parents=True, exist_ok=True)
# Atomic (a crash mid-write must not truncate the user's settings) and through the
# symlink, if there is one: dotfile managers keep this file as a link.
real = settings_path.resolve()
tmp = real.with_name(real.name + ".planchette-tmp")
tmp.write_text(json.dumps(settings, indent=2) + "\n")
# A new file gets the umask's mode (0644); settings.json can hold secrets in `env`,
# so it keeps the mode the old file had (or 0600 when there was none).
os.chmod(tmp, stat.S_IMODE(real.stat().st_mode) if real.exists() else 0o600)
os.replace(tmp, real)
print(f"written: {settings_path}")
PY

# --- Codex: session claim only (see HookInstaller.swift for why) -------------
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
if [ -d "$CODEX_DIR" ]; then
    python3 - "$CODEX_DIR" "$HOOK_BIN" <<'PY'
import json, shutil, sys, time
from pathlib import Path

codex_dir = Path(sys.argv[1])
hook_cmd = sys.argv[2] + " codex"

hooks_path = codex_dir / "hooks.json"
root = {}
if hooks_path.exists():
    root = json.loads(hooks_path.read_text() or "{}")
    backup = hooks_path.with_suffix(f".json.planchette-bak-{time.strftime('%Y%m%d%H%M%S')}")
    shutil.copy2(hooks_path, backup)
    print(f"backup: {backup}")

hooks = root.setdefault("hooks", {})
entries = hooks.setdefault("SessionStart", [])
already = any(
    h.get("command") == hook_cmd
    for entry in entries
    for h in entry.get("hooks", [])
)
if already:
    print("already installed: codex SessionStart")
else:
    entries.append({"hooks": [{"type": "command", "command": hook_cmd}]})
    print("installed: codex SessionStart")
hooks_path.write_text(json.dumps(root, indent=2) + "\n")
print(f"written: {hooks_path}")

# Codex only runs hooks when the feature is on.
config_path = codex_dir / "config.toml"
text = config_path.read_text() if config_path.exists() else ""
lines = text.split("\n") if text else []
in_features, features_at, done = False, None, False
for i, raw in enumerate(lines):
    line = raw.strip()
    if line.startswith("["):
        in_features = line == "[features]"
        if in_features and features_at is None:
            features_at = i
        continue
    if in_features and line.split("=")[0].strip() == "hooks":
        if "true" not in line:
            lines[i] = "hooks = true"
            print("enabled: codex [features] hooks")
        else:
            print("already enabled: codex [features] hooks")
        done = True
        break
if not done:
    if features_at is not None:
        lines.insert(features_at + 1, "hooks = true")
    else:
        lines += ([""] if text and not text.endswith("\n") else []) + ["[features]", "hooks = true", ""]
    print("enabled: codex [features] hooks")
config_path.write_text("\n".join(lines))
print(f"written: {config_path}")
PY
else
    echo "skipped codex: no $CODEX_DIR"
fi

# --- Control CLI -------------------------------------------------------------
CLI_SRC="$(cd "$(dirname "$0")" && pwd)/planchette"
CLI_DEST="$HOME/.planchette/planchette"
if [ -f "$CLI_SRC" ]; then
    mkdir -p "$(dirname "$CLI_DEST")"
    cp "$CLI_SRC" "$CLI_DEST"
    chmod +x "$CLI_DEST"
    echo "installed: $CLI_DEST"
else
    echo "skipped cli: $CLI_SRC not found"
fi
