"""Does a session.wait whose caller went away keep its connection (descriptor) until the timeout?

usage: session_wait.py <label> <binary> <scratch-folder>
Counts the unix-socket descriptors of the app (lsof -U) while:
  A. a client sent session.wait, half-closed (what the CLI does) and keeps waiting  -> must STAY connected
  B. that client then closes the connection completely                              -> must be released
  C. a second client waits and the state arrives later                               -> must get its answer
"""
import json, os, signal, socket, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from perf_common import REPO, FocusGuard, UserFilesGuard, scratch_root, tool
label, binary = sys.argv[1], sys.argv[2]
root = scratch_root(sys.argv[3])
binary = os.path.abspath(binary)   # the instance is started with cwd=/, so a relative path would not be found
files_guard = UserFilesGuard(); focus_guard = FocusGuard()
state_dir = f"{root}/state"; os.makedirs(state_dir, exist_ok=True); os.makedirs(f"{root}/repo", exist_ok=True)
G, S = "11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222"
json.dump({"autoUpdateCheck": False, "aiEnabled": False, "durableTerminals": False,
  "groups": [{"id": G, "name": "probe", "sessionIDs": [S], "activeSessionID": S, "active": True, "favorite": False, "color": "none", "viewMode": "tabs"}],
  "sessions": [{"id": S, "groupID": G, "workingDirectory": f"{root}/repo", "currentDirectory": f"{root}/repo", "durable": False,
                "startupCommand": "exec /bin/sleep 3600", "resumeClaudeOnRestore": False, "state": "free",
                "stateSince": 780000000, "seen": True, "tags": [], "agentKind": "none", "color": "none"}],
  "windows": [{"id": "00000000-0000-0000-0000-0000000000a1", "groupIDs": [G], "selectedGroupID": G, "folders": [], "showsProjectOverview": False}]},
  open(f"{state_dir}/state.json", "w"))
env = {k: v for k, v in os.environ.items() if not k.startswith("PLANCHETTE_")}
env.update(PLANCHETTE_STATE_DIR=state_dir, GHOSTTY_RESOURCES_DIR=f"{REPO}/vendor/ghostty/zig-out/share/ghostty")
app = subprocess.Popen([binary], env=env, stdout=open(f"{root}/app.log", "w"), stderr=subprocess.STDOUT, cwd="/")
focus_guard.start(app.pid)
sock = None
def unix_fds():
    out = subprocess.run(["lsof", "-a", "-p", str(app.pid), "-U"], capture_output=True, text=True).stdout.strip().splitlines()
    return max(0, len(out) - 1)          # minus the header
def connect():
    c = socket.socket(socket.AF_UNIX); c.settimeout(10); c.connect(sock); return c
def send_wait(timeout_ms, until):
    c = connect()
    c.sendall(json.dumps({"planchette_request": "session.wait", "id": S, "until": until, "timeout_ms": timeout_ms}).encode())
    c.shutdown(socket.SHUT_WR)           # half-close: the client still waits for the answer
    return c
try:
    for _ in range(80):
        time.sleep(0.25)
        try:
            sock = open(f"{state_dir}/socket").read().strip()
            if os.path.exists(sock): break
        except OSError: pass
    time.sleep(2)
    base = unix_fds()
    print(f"[{label}] idle: unix descriptors = {base}", flush=True)

    a = send_wait(300_000, ["waiting"])
    time.sleep(1.5)
    n1 = unix_fds()
    time.sleep(3.0)
    n2 = unix_fds()
    print(f"[{label}] A waiting (half-closed): +{n1 - base} after 1.5 s, +{n2 - base} after 4.5 s   (must stay +1: the client is still waiting)", flush=True)

    a.close()                            # Ctrl-C / killed tool: the process is gone
    t0 = time.time(); series = []
    for _ in range(6):
        time.sleep(0.7)
        series.append((round(time.time() - t0, 1), unix_fds() - base))
    print(f"[{label}] A closed completely: (seconds after close, descriptors above idle) = {series}", flush=True)

    b = send_wait(30_000, ["waiting"])
    time.sleep(1.0)
    c = connect()
    c.sendall(json.dumps({"planchette_session": S, "agent": "claude", "event": {"hook_event_name": "PermissionRequest", "session_id": "x"}}).encode())
    c.shutdown(socket.SHUT_WR); c.close()
    b.settimeout(10)
    data = b""
    try:
        while True:
            ch = b.recv(65536)
            if not ch: break
            data += ch
    except Exception as e:
        data = f"(error: {e})".encode()
    try:
        reply = json.loads(data)
        print(f"[{label}] C answered after the state arrived: ok={reply.get('ok')} timed_out={reply.get('result', {}).get('timed_out')} state={reply.get('result', {}).get('session', {}).get('state')}", flush=True)
    except Exception:
        print(f"[{label}] C: no usable answer: {data[:120]!r}", flush=True)
finally:
    focus_guard.stop()
    app.send_signal(signal.SIGTERM)
    try: app.wait(timeout=10)
    except subprocess.TimeoutExpired: app.kill()
    try: os.unlink(f"/tmp/planchette-{app.pid}.sock")
    except OSError: pass
    files_guard.report(label)
