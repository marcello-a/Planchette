"""Does a dialog that a MENU action opens with runModal() stall the app?

usage: menu_dialog.py <label> <binary> <scratch-folder> <scenario: ai-menu | quit-menu>
A terminal runs a loop (ticks.log grows ~15/s while the app drains its PTY); the control API is
probed throughout. The dialog is opened through the real menu bar with System Events (the
process is addressed by its pid, never by name - and only after System Events has confirmed
that the pid is the one it means, see `system_events_process`), left open for a while, then dismissed.
"""
import json, os, signal, socket, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from perf_common import REPO, FocusGuard, UserFilesGuard, scratch_root, system_events_process, tool
label, binary, scenario = sys.argv[1], sys.argv[2], sys.argv[4]
root = scratch_root(sys.argv[3])
binary = os.path.abspath(binary)   # the instance is started with cwd=/, so a relative path would not be found
files_guard = UserFilesGuard(); focus_guard = FocusGuard()
state_dir = f"{root}/state"; os.makedirs(state_dir, exist_ok=True); os.makedirs(f"{root}/repo", exist_ok=True)
ticks = f"{root}/ticks.log"; open(ticks, "w").close()
G, S = "11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222"
open(f"{root}/loop.sh", "w").write(f"""#!/bin/sh
while :; do printf '\\033]0;t %s\\007' $RANDOM; echo x >> {ticks}; sleep 0.05; done
""")
json.dump({"autoUpdateCheck": False, "aiEnabled": scenario == "ai-menu", "language": "en", "durableTerminals": False,
  "groups": [{"id": G, "name": "probe", "sessionIDs": [S], "activeSessionID": S, "active": True, "favorite": False, "color": "none", "viewMode": "tabs"}],
  "sessions": [{"id": S, "groupID": G, "workingDirectory": f"{root}/repo", "currentDirectory": f"{root}/repo", "durable": False,
                "startupCommand": f"exec /bin/sh {root}/loop.sh", "resumeClaudeOnRestore": False, "state": "free",
                "stateSince": 780000000, "seen": True, "tags": [], "agentKind": "none", "color": "none"}],
  "windows": [{"id": "00000000-0000-0000-0000-0000000000a1", "groupIDs": [G], "selectedGroupID": G, "folders": [], "showsProjectOverview": False}]},
  open(f"{state_dir}/state.json", "w"))
env = {k: v for k, v in os.environ.items() if not k.startswith("PLANCHETTE_")}
env.update(PLANCHETTE_STATE_DIR=state_dir, GHOSTTY_RESOURCES_DIR=f"{REPO}/vendor/ghostty/zig-out/share/ghostty")
app = subprocess.Popen([binary], env=env, stdout=open(f"{root}/app.log", "w"), stderr=subprocess.STDOUT, cwd="/")
focus_guard.start(app.pid)
sock = None
def rpc(payload, timeout=3):
    c = socket.socket(socket.AF_UNIX); c.settimeout(timeout); c.connect(sock)
    c.sendall(json.dumps(payload).encode()); c.shutdown(socket.SHUT_WR)
    b = b""
    while True:
        ch = c.recv(65536)
        if not ch: break
        b += ch
    return json.loads(b) if b else None
def api_ok(timeout=2):
    try: return (rpc({"planchette_request": "session.list"}, timeout) or {}).get("ok") is True
    except Exception: return False
def count(): return sum(1 for _ in open(ticks))
def wins():
    return subprocess.run([tool("windows"), str(app.pid)], capture_output=True, text=True).stdout.strip().splitlines()
def osa(script, wait=True):
    cmd = ["osascript", "-e", script]
    if wait:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        return r.returncode, (r.stdout + r.stderr).strip()[:160]
    return subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
proc = None   # set once System Events has been asked and has answered with this pid (system_events_process)
menus = {"ai-menu": ('menu item "Group by topic…" of menu 1 of menu bar item "AI" of menu bar 1', "OK"),
         "quit-menu": (f'menu item "Quit Planchette" of menu 1 of menu bar item 2 of menu bar 1', "Cancel")}
try:
    for _ in range(80):
        time.sleep(0.25)
        try:
            sock = open(f"{state_dir}/socket").read().strip()
            if os.path.exists(sock): break
        except OSError: pass
    time.sleep(3)
    proc = system_events_process(app.pid)
    if scenario == "quit-menu":   # a running, non-durable agent makes the quit ask first
        rpc({"planchette_session": S, "agent": "claude", "event": {"hook_event_name": "UserPromptSubmit", "session_id": "x", "prompt": "hi"}})
        time.sleep(1)
    print(f"[{label}] {scenario}: before: ticks={count()} api={'ok' if api_ok() else 'NO ANSWER'} windows={len(wins())}", flush=True)
    osa(f'tell application "System Events" to set frontmost of {proc} to true')
    time.sleep(1)
    item, button = menus[scenario]
    prev = count()
    opener = osa(f'tell application "System Events" to tell {proc} to click {item}', wait=False)
    for i in range(8):
        time.sleep(0.5)
        now = count(); w = wins()
        print(f"[{label}] +{(i+1)*0.5:3.1f}s menu clicked: ticks=+{now-prev:2d} api={'ok' if api_ok() else 'NO ANSWER'} windows={[l.split(' ',1)[1][:34] for l in w]}", flush=True)
        prev = now
    # The alert is not "window 1" while the app is in the background: try every window.
    dismiss = (f'tell application "System Events" to tell {proc}\n'
               f'  repeat with w in windows\n'
               f'    try\n      click button "{button}" of w\n      return "clicked"\n    end try\n'
               f'  end repeat\n  return "no window has a button {button}"\nend tell')
    rc, out = osa(dismiss)
    print(f"[{label}] dismiss click rc={rc} {out!r}", flush=True)
    time.sleep(1)
    now = count(); print(f"[{label}] after dismiss: ticks=+{now-prev} api={'ok' if api_ok() else 'NO ANSWER'} windows={[l.split(' ',1)[1][:34] for l in wins()]}", flush=True)
finally:
    focus_guard.stop()
    app.send_signal(signal.SIGKILL)
    try: app.wait(timeout=10)
    except subprocess.TimeoutExpired: pass
    try: os.unlink(f"/tmp/planchette-{app.pid}.sock")
    except OSError: pass
    subprocess.run(["pkill", "-f", f"{root}/ticks.log"], capture_output=True)
    subprocess.run(["pkill", "-f", f"{root}/loop.sh"], capture_output=True)
    files_guard.report(label)
