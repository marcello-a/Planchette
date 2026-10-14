"""Can a typed command get lost after the connection flood and a pending clipboard dialog?

usage: typed_after_flood.py <label> <binary> <scratch-folder> <rounds>
The sequence of the earlier harness run in which a typed command did not execute:
 90 idle connections at once -> an oversize request -> a client that vanishes -> an OSC 52 clipboard read
 (a dialog stays pending) -> typed commands. Each round types a command that creates a file and checks it.
Repeated `rounds` times in ONE instance (flood and probe each round), plus a fresh-instance round first.
"""
import json, os, signal, socket, subprocess, sys, threading, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from perf_common import REPO, UserFilesGuard, scratch_root
label, binary, rounds = sys.argv[1], sys.argv[2], int(sys.argv[4])
root = scratch_root(sys.argv[3])
binary = os.path.abspath(binary)   # the instance is started with cwd=/, so a relative path would not be found
files_guard = UserFilesGuard()
state_dir = f"{root}/state"; os.makedirs(state_dir, exist_ok=True); work = f"{root}/work"; os.makedirs(work, exist_ok=True)
G, S = "11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222"
probe = f"{root}/probe.py"
open(probe, "w").write('''
import os, select, sys, termios, time, tty
fd = sys.stdin.fileno(); saved = termios.tcgetattr(fd); data = b""
try:
    tty.setraw(fd); os.write(1, b"\\x1b]52;c;?\\x07"); end = time.time() + 3.0
    while time.time() < end:
        ready, _, _ = select.select([fd], [], [], 0.2)
        if ready:
            data += os.read(fd, 65536)
            if b"\\x07" in data or b"\\x1b\\\\" in data: break
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, saved)
open(sys.argv[1], "w").write(str(len(data)))
''')
json.dump({"autoUpdateCheck": False, "aiEnabled": False, "language": "en", "durableTerminals": False,
  "groups": [{"id": G, "name": "probe", "sessionIDs": [S], "activeSessionID": S, "active": True, "favorite": False, "color": "none", "viewMode": "tabs"}],
  "sessions": [{"id": S, "groupID": G, "workingDirectory": work, "currentDirectory": work, "durable": False,
                "startupCommand": "exec /bin/bash --noprofile --norc", "resumeClaudeOnRestore": False, "state": "free",
                "stateSince": 780000000, "seen": True, "tags": [], "agentKind": "none", "color": "none"}],
  "windows": [{"id": "00000000-0000-0000-0000-0000000000a1", "groupIDs": [G], "selectedGroupID": G, "folders": [], "showsProjectOverview": False}]},
  open(f"{state_dir}/state.json", "w"))
env = {k: v for k, v in os.environ.items() if not k.startswith("PLANCHETTE_")}
env.update(PLANCHETTE_STATE_DIR=state_dir, GHOSTTY_RESOURCES_DIR=f"{REPO}/vendor/ghostty/zig-out/share/ghostty")
FRONT = subprocess.run(["osascript", "-e", 'tell application "System Events" to get unix id of first process whose frontmost is true'], capture_output=True, text=True).stdout.strip()
app = subprocess.Popen([binary], env=env, stdout=open(f"{root}/app.log", "w"), stderr=subprocess.STDOUT, cwd="/")
stop = threading.Event(); stolen = []
def guard():
    q = 'tell application "System Events" to get unix id of first process whose frontmost is true'
    while not stop.is_set():
        if subprocess.run(["osascript", "-e", q], capture_output=True, text=True).stdout.strip() == str(app.pid) and FRONT:
            subprocess.run(["osascript", "-e", f'tell application "System Events" to set frontmost of (first process whose unix id is {FRONT}) to true'], capture_output=True)
            stolen.append(1)
        stop.wait(0.15)
threading.Thread(target=guard, daemon=True).start()
sockpath = None
def rpc(payload, timeout=20):
    c = socket.socket(socket.AF_UNIX); c.settimeout(timeout); c.connect(sockpath)
    c.sendall(json.dumps(payload).encode()); c.shutdown(socket.SHUT_WR)
    b = b""
    while True:
        ch = c.recv(65536)
        if not ch: break
        b += ch
    return json.loads(b)
def type_in(text): 
    # submit False: the text carries its own newline (see harness.py, type_in)
    r = rpc({"planchette_request": "session.prompt", "id": S, "text": text, "force": True, "submit": False}); assert r["ok"], r
def wait_file(path, seconds):
    end = time.time() + seconds
    while time.time() < end:
        if os.path.exists(path): return open(path).read().strip()
        time.sleep(0.05)
    return None
try:
    for _ in range(80):
        time.sleep(0.25)
        try:
            sockpath = open(f"{state_dir}/socket").read().strip()
            if os.path.exists(sockpath): break
        except OSError: pass
    time.sleep(4)
    misses = 0; latencies = []
    for n in range(1, rounds + 1):
        # the flood: 90 idle connections at once, held; then an oversize request and a vanishing client
        held = []
        for _ in range(90):
            c = socket.socket(socket.AF_UNIX); c.settimeout(0.05)
            try: c.connect(sockpath); held.append(c)
            except OSError: c.close()
        time.sleep(1.5)
        for c in held: c.close()          # as the original harness did, before the next steps
        held = []
        time.sleep(0.5)
        big = socket.socket(socket.AF_UNIX); big.settimeout(10); big.connect(sockpath)
        try:
            big.sendall(b'{"planchette_request":"session.list","pad":"' + b"a" * (5 << 20) + b'"}'); big.shutdown(socket.SHUT_WR); big.recv(10)
        except OSError: pass
        big.close()
        gone = socket.socket(socket.AF_UNIX); gone.connect(sockpath)
        gone.sendall(json.dumps({"planchette_request": "session.wait", "id": S, "until": ["error"], "timeout_ms": 2000}).encode()); gone.shutdown(socket.SHUT_WR); gone.close()
        time.sleep(2.5)
        # the clipboard read: a dialog stays pending
        out = f"{root}/osc{n}.out"
        type_in(f"python3 {probe} {out}\n")
        wait_file(out, 8)
        for c in held: c.close()
        # typed commands right after, as the harness did
        t0 = time.time(); marker = f"{root}/typed{n}.done"
        type_in(f"echo ok > {marker}\n")
        got = wait_file(marker, 10)
        lat = time.time() - t0
        if got is None: misses += 1; print(f"[{label}] round {n}: MISS - the typed command did not run within 10 s", flush=True)
        else: latencies.append(lat)
        time.sleep(1.0)
    med = sorted(latencies)[len(latencies)//2] if latencies else None
    print(f"[{label}] {rounds} rounds: {rounds - misses} typed commands ran, {misses} missed; median typed->done {None if med is None else round(med*1000)} ms; focus taken {len(stolen)} time(s)", flush=True)
finally:
    stop.set()
    app.send_signal(signal.SIGKILL)
    try: app.wait(timeout=10)
    except subprocess.TimeoutExpired: pass
    try: os.unlink(f"/tmp/planchette-{app.pid}.sock")
    except OSError: pass
    subprocess.run(["pkill", "-f", f"{root}/"], capture_output=True)
    files_guard.report(label)
