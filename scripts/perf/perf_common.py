"""Shared helpers for the measurement scripts in this folder.

Every script runs an ISOLATED Planchette instance (PLANCHETTE_STATE_DIR) and talks to its own
socket. Nothing here may touch the instance you work in: see README.md, "Safety".
"""
import hashlib
import os
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
# libghostty looks its resources up here when the app is not a packaged .app (AGENTS.md).
RESOURCES = os.path.join(REPO, "vendor", "ghostty", "zig-out", "share", "ghostty")
HOME = os.path.expanduser("~")


def tool(name):
    """Path of the Swift helper tools/<name>.swift, compiled on first use (and when it changes)."""
    source = os.path.join(HERE, "tools", name + ".swift")
    out_dir = os.path.join(os.environ.get("TMPDIR", "/tmp"), "planchette-perf-tools")
    binary = os.path.join(out_dir, name)
    if not os.path.exists(binary) or os.path.getmtime(binary) < os.path.getmtime(source):
        os.makedirs(out_dir, exist_ok=True)
        subprocess.run(["swiftc", "-O", source, "-o", binary], check=True, capture_output=True)
    return binary


def scratch_root(path):
    """The folder a run keeps everything in. Scripts stop their own helper processes by
    matching this path on the command line, so it must be a folder made for the run."""
    # The real path: /tmp is a symlink to /private/tmp, and a program that resolves its working
    # directory (Claude Code does, for its per-project trust) must find the name we seeded.
    root = os.path.realpath(os.path.abspath(os.path.expanduser(path)))
    parts = [part for part in root.split(os.sep) if part]
    if len(parts) < 3 or root in (os.path.realpath(HOME), os.path.realpath(REPO), os.path.dirname(os.path.realpath(REPO))):
        raise SystemExit(f"refusing to use {root} as a scratch folder: pass a folder that exists only for this run")
    os.makedirs(root, exist_ok=True)
    return root


def frontmost_pid():
    """The process that has the keyboard focus (needs the Accessibility permission, else empty)."""
    result = subprocess.run(
        ["osascript", "-e", 'tell application "System Events" to get unix id of first process whose frontmost is true'],
        capture_output=True, text=True)
    return result.stdout.strip()


def system_events_process(pid, timeout=20):
    """An AppleScript reference to the process with this pid, once System Events really knows it.

    Asked about a pid it has not registered yet, System Events does not fail: `first process
    whose unix id is N` answered with ANOTHER process - once with the installed Planchette
    (build.planchette.app) instead of the isolated instance under test, for a pid a few seconds
    old. A menu click or a keystroke sent that way goes to the real app. The reference is
    returned only after the process it names reports the pid that was asked for."""
    ref = f"(first process whose unix id is {pid})"
    deadline = time.time() + timeout
    while time.time() < deadline:
        r = subprocess.run(
            ["osascript", "-e", f'tell application "System Events" to get unix id of {ref}'],
            capture_output=True, text=True)
        if r.returncode == 0 and r.stdout.strip() == str(pid):
            return ref
        time.sleep(0.5)
    raise SystemExit(f"System Events does not know pid {pid} (yet): not scripting a process it might confuse with another")


class FocusGuard:
    """An isolated instance activates itself when it starts, which takes the keyboard from
    whoever is working. Create the guard BEFORE launching the instance, call start(pid) after,
    and it hands the focus back within about 0.15 s. Does nothing when osascript is not allowed."""

    def __init__(self):
        self.user_pid = frontmost_pid()
        self.taken = 0
        self._stop = threading.Event()

    def start(self, instance_pid):
        def watch():
            while not self._stop.is_set():
                if self.user_pid and frontmost_pid() == str(instance_pid):
                    subprocess.run(
                        ["osascript", "-e",
                         'tell application "System Events" to set frontmost of '
                         f"(first process whose unix id is {self.user_pid}) to true"],
                        capture_output=True)
                    self.taken += 1
                self._stop.wait(0.15)
        threading.Thread(target=watch, daemon=True).start()

    def stop(self):
        self._stop.set()


class UserFilesGuard:
    """Notices when a run changed files in your real home folder, which an isolated instance
    must never do. The check is cheap; call report() at the end of every run."""

    WATCHED = (
        "~/.planchette/planchette",        # the CLI that agents in your real terminals call
        "~/.planchette/planchette-hook",
        "~/.planchette/socket",            # points the hooks at the running instance
        "~/.claude/settings.json",
        "~/.codex/hooks.json",
        "~/.codex/config.toml",
    )

    def __init__(self):
        self.before = {path: self._state(path) for path in self.WATCHED}

    @staticmethod
    def _state(path):
        path = os.path.expanduser(path)
        try:
            info = os.stat(path)
        except OSError:
            return None
        digest = None
        if info.st_size < 4 << 20:
            with open(path, "rb") as handle:
                digest = hashlib.sha256(handle.read()).hexdigest()
        return (info.st_size, int(info.st_mtime), digest)

    def changed(self):
        return [path for path in self.WATCHED if self._state(path) != self.before[path]]

    def report(self, label=""):
        changed = self.changed()
        if not changed:
            print(f"[{label}] your own files are unchanged ({len(self.WATCHED)} checked)", flush=True)
            return False
        print(f"[{label}] WARNING: files in your home folder changed during this run: {', '.join(changed)}", flush=True)
        if "~/.planchette/planchette" in changed:
            print("   ~/.planchette/planchette is the CLI. A Planchette build from before the fix that deploys only\n"
                  "   from a packaged .app copies ITSELF over it when it is started from its build folder.\n"
                  "   Restore it with:\n"
                  "   cp -p /Applications/Planchette.app/Contents/Resources/planchette ~/.planchette/planchette", flush=True)
        print("   (~/.claude/settings.json is also written by your own Claude Code sessions.)", flush=True)
        return True


if __name__ == "__main__" and len(sys.argv) == 3 and sys.argv[1] == "tool":
    print(tool(sys.argv[2]))
