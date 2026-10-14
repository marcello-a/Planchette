"""Does a terminal that could not start (no active display) come alive when a display returns?

usage: dark_display.py <label> <binary> <scratch-folder>   (usually through dark_display.sh)
Run it while the displays are asleep. The instance is launched (its terminals cannot get a
surface), probed through the API, then the displays are woken with `caffeinate -u` and the
loop in the terminal is watched: ticks.log grows only while the terminal's process runs.
"""
import json, os, signal, socket, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from perf_common import REPO, FocusGuard, UserFilesGuard, scratch_root, tool
label, binary = sys.argv[1], sys.argv[2]
root = scratch_root(sys.argv[3])
binary = os.path.abspath(binary)   # the instance is started with cwd=/, so a relative path would not be found
files_guard = UserFilesGuard(); focus_guard = FocusGuard()
state_dir = f"{root}/state"; os.makedirs(state_dir, exist_ok=True); os.makedirs(f"{root}/repo", exist_ok=True)
ticks = f"{root}/ticks.log"; open(ticks, "w").close()
G, S = "11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222"
open(f"{root}/loop.sh", "w").write(f"""#!/bin/sh
while :; do echo x >> {ticks}; sleep 0.05; done
""")
json.dump({"autoUpdateCheck": False, "aiEnabled": False, "language": "en", "durableTerminals": False,
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
def rpc(payload, timeout=5):
    c = socket.socket(socket.AF_UNIX); c.settimeout(timeout); c.connect(sock)
    c.sendall(json.dumps(payload).encode()); c.shutdown(socket.SHUT_WR)
    b = b""
    while True:
        ch = c.recv(65536)
        if not ch: break
        b += ch
    return json.loads(b) if b else None
def count(): return sum(1 for _ in open(ticks))
def displays(): return subprocess.run([tool("displays")], capture_output=True, text=True).stdout.strip()
def failures(): return sum(1 for l in open(f"{root}/app.log") if "ghostty_surface_new failed" in l)
try:
    for _ in range(80):
        time.sleep(0.25)
        try:
            sock = open(f"{state_dir}/socket").read().strip()
            if os.path.exists(sock): break
        except OSError: pass
    time.sleep(3)
    print(f"[{label}] displays: {displays()}", flush=True)
    print(f"[{label}] before wake: ticks={count()} surface-failures-logged={failures()}", flush=True)
    r = rpc({"planchette_request": "session.new", "cwd": f"{root}/repo"})
    print(f"[{label}] session.new while dark: ok={r.get('ok')} error={r.get('error')!r}", flush=True)
    sessions = rpc({"planchette_request": "session.list"})["result"]["sessions"]
    print(f"[{label}] sessions after that: {len(sessions)} (the failed session.new must leave none behind)", flush=True)
    r = rpc({"planchette_request": "session.prompt", "id": S, "text": "echo hi", "force": True})
    print(f"[{label}] session.prompt to the dead terminal: ok={r.get('ok')} error={r.get('error')!r}", flush=True)
    time.sleep(2)

    wake = subprocess.Popen(["caffeinate", "-u", "-t", "8"])
    t0 = time.time(); first = None; prev = count(); last_print = 0
    while time.time() - t0 < 25:
        time.sleep(0.5)
        now = count()
        if first is None and now > 0:
            first = time.time() - t0
        if time.time() - last_print > 2.4 or (first is not None and first > time.time() - t0 - 0.6):
            last_print = time.time()
            print(f"[{label}] t={time.time()-t0:4.1f}s after wake: ticks={now} (+{now-prev}) displays: {displays()}", flush=True)
        prev = now
    print(f"[{label}] terminal came alive after {None if first is None else round(first, 1)} s; surface failures logged: {failures()}", flush=True)
    r = rpc({"planchette_request": "session.new", "cwd": f"{root}/repo"})
    print(f"[{label}] session.new after wake: ok={r.get('ok')} error={r.get('error')!r}", flush=True)
    wake.wait(timeout=15)
finally:
    focus_guard.stop()
    app.send_signal(signal.SIGKILL)
    try: app.wait(timeout=10)
    except subprocess.TimeoutExpired: pass
    try: os.unlink(f"/tmp/planchette-{app.pid}.sock")
    except OSError: pass
    subprocess.run(["pkill", "-f", f"{root}/loop.sh"], capture_output=True)
    files_guard.report(label)
