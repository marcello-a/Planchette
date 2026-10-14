"""Does an open app-modal dialog (the update offer) stall terminals and the control API?

usage: dialog_freeze.py <label> <binary> <scratch-folder> <autoUpdateCheck: 1|0>
A terminal runs a loop that (a) prints a changing title 20x/s to the PTY and (b) appends a line
to a file each iteration. If the app stops draining the PTY the loop blocks on its printf and the
file stops growing. The control API is probed with a 3 s timeout throughout.
"""
import json, os, re, signal, socket, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from perf_common import REPO, FocusGuard, UserFilesGuard, scratch_root, tool
label, binary, check = sys.argv[1], sys.argv[2], sys.argv[4] == "1"
root = scratch_root(sys.argv[3])
binary = os.path.abspath(binary)   # the instance is started with cwd=/, so a relative path would not be found
files_guard = UserFilesGuard(); focus_guard = FocusGuard()
state_dir = f"{root}/state"; os.makedirs(state_dir, exist_ok=True); os.makedirs(f"{root}/repo", exist_ok=True)
ticks = f"{root}/ticks.log"; open(ticks, "w").close()
G, S = "11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222"
open(f"{root}/loop.sh", "w").write(f"""#!/bin/sh
while :; do printf '\\033]0;t %s\\007' $RANDOM; echo x >> {ticks}; sleep 0.05; done
""")
loop = f"exec /bin/sh {root}/loop.sh"
json.dump({"autoUpdateCheck": check, "aiEnabled": False, "durableTerminals": False,
  "groups": [{"id": G, "name": "probe", "sessionIDs": [S], "activeSessionID": S, "active": True, "favorite": False, "color": "none", "viewMode": "tabs"}],
  "sessions": [{"id": S, "groupID": G, "workingDirectory": f"{root}/repo", "currentDirectory": f"{root}/repo", "durable": False,
                "startupCommand": loop, "resumeClaudeOnRestore": False, "state": "free",
                "stateSince": 780000000, "seen": True, "tags": [], "agentKind": "none", "color": "none"}],
  "windows": [{"id": "00000000-0000-0000-0000-0000000000a1", "groupIDs": [G], "selectedGroupID": G, "folders": [], "showsProjectOverview": False}]},
  open(f"{state_dir}/state.json", "w"))
env = {k: v for k, v in os.environ.items() if not k.startswith("PLANCHETTE_")}
env.update(PLANCHETTE_STATE_DIR=state_dir, GHOSTTY_RESOURCES_DIR=f"{REPO}/vendor/ghostty/zig-out/share/ghostty")
app = subprocess.Popen([binary], env=env, stdout=open(f"{root}/app.log", "w"), stderr=subprocess.STDOUT, cwd="/")
focus_guard.start(app.pid)
def api_ok(timeout=3):
    try:
        c = socket.socket(socket.AF_UNIX); c.settimeout(timeout); c.connect(sock)
        c.sendall(b'{"planchette_request":"session.list"}'); c.shutdown(socket.SHUT_WR)
        b = b""
        while True:
            ch = c.recv(65536)
            if not ch: break
            b += ch
        return json.loads(b).get("ok") is True
    except Exception:
        return False
def count(): return sum(1 for _ in open(ticks))
try:
    for _ in range(80):
        time.sleep(0.25)
        try:
            sock = open(f"{state_dir}/socket").read().strip()
            if os.path.exists(sock): break
        except OSError: pass
    print(f"[{label}] autoUpdateCheck={check}; sampling every 1s from launch: (loop iterations since previous sample | control API answers within 3s)", flush=True)
    prev = 0
    for t in range(1, 41):
        time.sleep(1)
        now = count(); ok = api_ok(2)
        raw = subprocess.run([tool("windows"), str(app.pid)], capture_output=True, text=True).stdout.splitlines()
        wins = " ".join(f"{m.group(1)}:{m.group(2)}" for m in (re.search(r"layer=(\d+) (\d+x\d+)", line) for line in raw) if m)
        print(f"[{label}] t={t:2d}s  total={now:5d}  +{now - prev:3d}   api={'ok' if ok else 'NO ANSWER'}   windows(layer:WxH)={wins}", flush=True)
        prev = now
finally:
    focus_guard.stop()
    app.send_signal(signal.SIGTERM)
    try: app.wait(timeout=10)
    except subprocess.TimeoutExpired: app.kill()
    try: os.unlink(f"/tmp/planchette-{app.pid}.sock")
    except OSError: pass
    subprocess.run(["pkill", "-f", f"{root}/ticks.log"], capture_output=True)
    files_guard.report(label)
