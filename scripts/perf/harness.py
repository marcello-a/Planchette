#!/usr/bin/env python3
"""Drive ONE isolated Planchette instance and print a measurement report.

usage: harness.py <label> <path-to-Planchette-binary> <scratch-folder>

Everything the instance owns lives under <scratch-root> (PLANCHETTE_STATE_DIR), the
CLI is run with a fake HOME so it can never fall back to the user's real socket
pointer, and every request goes to the isolated instance's own socket path.
"""
import json, os, signal, socket, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from perf_common import REPO, RESOURCES as RES, FocusGuard, UserFilesGuard, scratch_root

label, binary = sys.argv[1], sys.argv[2]
root = scratch_root(sys.argv[3])
binary = os.path.abspath(binary)   # the instance is started with cwd=/, so a relative path would not be found
HOOK = f"{REPO}/hook/planchette-hook"
files_guard = UserFilesGuard()     # a run must leave your own files alone: checked again at the end
focus_guard = FocusGuard()         # the instance activates itself at launch; give the focus back

state_dir = f"{root}/state"
home = f"{root}/home"
bindir = f"{root}/bin"
repo = f"{root}/repo"
for d in (state_dir, home, bindir, repo):
    os.makedirs(d, exist_ok=True)
os.chmod(state_dir, 0o700)

report = {"label": label}


def note(key, value):
    report[key] = value
    print(f"[{label}] {key}: {value}", flush=True)


# ---- seed: no update dialog, no AI calls, plain (non-tmux) terminals ----------
G, S = "11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222"
with open(f"{state_dir}/state.json", "w") as handle:
    json.dump({"autoUpdateCheck": False, "aiEnabled": False, "durableTerminals": False,
      "groups": [{"id": G, "name": "probe", "sessionIDs": [S], "activeSessionID": S, "active": True,
                  "favorite": False, "color": "none", "viewMode": "tabs"}],
      "sessions": [{"id": S, "groupID": G, "workingDirectory": repo, "currentDirectory": repo, "durable": False,
                    "startupCommand": "exec /bin/bash --noprofile --norc", "resumeClaudeOnRestore": False,
                    "state": "free", "stateSince": 780000000, "seen": True, "tags": [], "agentKind": "none",
                    "color": "none"}],
      "windows": [{"id": "00000000-0000-0000-0000-0000000000a1", "groupIDs": [G], "selectedGroupID": G,
                   "folders": [], "showsProjectOverview": False}]}, handle)

# ---- a git wrapper that logs who called it ------------------------------------
gitlog = f"{root}/git-calls.log"
open(gitlog, "w").close()
with open(f"{bindir}/git", "w") as handle:
    handle.write(f'#!/bin/sh\necho "ppid=$PPID $*" >> "{gitlog}"\nexec /usr/bin/git "$@"\n')
os.chmod(f"{bindir}/git", 0o755)

# ---- scripts typed into the terminal ------------------------------------------
GLYPHS = '"⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"'
open(f"{root}/glyph-storm.sh", "w").write(f"""#!/bin/sh
# Same title text; only the leading glyph changes, 20 times a second (a spinner).
end=$(( $(date +%s) + $2 ))
while [ $(date +%s) -lt $end ]; do
  for g in {GLYPHS}; do printf '\\033]0;%s Claude Code\\007' "$g"; sleep 0.05; done
done
echo done > "$1"
""")
open(f"{root}/text-storm.sh", "w").write(f"""#!/bin/sh
# The title text really changes every frame, for $2 seconds.
n=0
end=$(( $(date +%s) + $2 ))
while [ $(date +%s) -lt $end ]; do
  for g in {GLYPHS}; do n=$((n+1)); printf '\\033]0;%s job %d\\007' "$g" "$n"; sleep 0.05; done
done
echo done > "$1"
""")
open(f"{root}/probe.py", "w").write('''
import os, select, sys, termios, time, tty
fd = sys.stdin.fileno()
saved = termios.tcgetattr(fd)
data = b""
try:
    tty.setraw(fd)
    os.write(1, b"\\x1b]52;c;?\\x07")          # OSC 52: "send me the clipboard"
    end = time.time() + 3.0
    while time.time() < end:
        ready, _, _ = select.select([fd], [], [], 0.2)
        if ready:
            data += os.read(fd, 65536)
            if b"\\x07" in data or b"\\x1b\\\\" in data:
                break
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, saved)
open(sys.argv[1], "w").write(str(len(data)))      # only the LENGTH leaves this script
''')

# ---- a git repository for the branch checks -----------------------------------
def git(*args):
    return subprocess.run(["/usr/bin/git", *args], cwd=repo, capture_output=True, text=True)

git("init", "-q", "-b", "feat/one")
git("config", "user.email", "t@example.com")
git("config", "user.name", "T")
open(f"{repo}/README", "w").write("x")
git("add", ".")
git("commit", "-qm", "init")

# ---- launch ---------------------------------------------------------------------
env = dict(os.environ)
for key in [k for k in env if k.startswith("PLANCHETTE_")]:
    del env[key]
env.update(PLANCHETTE_STATE_DIR=state_dir, GHOSTTY_RESOURCES_DIR=RES,
           PATH=f"{bindir}:{env['PATH']}")
logfile = open(f"{root}/app.log", "w")
app = subprocess.Popen([binary], env=env, stdout=logfile, stderr=logfile, cwd="/")
focus_guard.start(app.pid)
note("pid", app.pid)

try:
    sock_path = None
    for _ in range(120):
        time.sleep(0.25)
        try:
            sock_path = open(f"{state_dir}/socket").read().strip()
            if sock_path and os.path.exists(sock_path):
                break
        except OSError:
            pass
    assert sock_path, "app did not publish its socket"
    note("socket", sock_path)
    note("socket_mode", oct(os.stat(sock_path).st_mode & 0o777))

    def rpc(payload, timeout=20):
        client = socket.socket(socket.AF_UNIX)
        client.settimeout(timeout)
        client.connect(sock_path)
        client.sendall(json.dumps(payload).encode())
        client.shutdown(socket.SHUT_WR)
        buf = b""
        while True:
            chunk = client.recv(65536)
            if not chunk:
                break
            buf += chunk
        client.close()
        return json.loads(buf)

    def alive():
        return app.poll() is None

    def cpu_seconds():
        out = subprocess.run(["ps", "-o", "cputime=", "-p", str(app.pid)],
                             capture_output=True, text=True).stdout.strip()
        total = 0.0
        for part in out.split(":"):
            total = total * 60 + float(part)
        return total

    def session_state(sid):
        return rpc({"planchette_request": "session.get", "id": sid})["result"]["session"]["state"]

    def notification(sid):
        rows = rpc({"planchette_request": "notification.list"})["result"]["notifications"]
        return next((r for r in rows if r["id"] == sid), {})

    def type_in(sid, command):
        # `submit: False`: every command here ends in its own newline. The Enter that session.prompt
        # presses after a paste would otherwise reach the running program (the OSC 52 probe counts
        # every byte it receives, and counted that Enter as "clipboard").
        reply = rpc({"planchette_request": "session.prompt", "id": sid, "text": command, "force": True, "submit": False})
        assert reply["ok"], reply

    def wait_file(path, seconds):
        end = time.time() + seconds
        while time.time() < end:
            if os.path.exists(path):
                return open(path).read().strip()
            time.sleep(0.2)
        return None

    # ---- 1. basic API -----------------------------------------------------------
    assert rpc({"planchette_request": "session.list"})["ok"]
    sid = S                                         # restored from the seeded state; runs bash 3.2
    # A second terminal through the API, to exercise session.new too.
    extra = rpc({"planchette_request": "session.new", "cwd": repo})
    note("session_new_via_api", extra["ok"])
    time.sleep(5)                                   # let the shell draw its prompt

    # ---- 2. hook events through the real hook script + nc -----------------------
    def fire(event, extra=None):
        payload = {"hook_event_name": event, "session_id": "claude-test-1"}
        payload.update(extra or {})
        started = time.time()
        subprocess.run(["/bin/sh", HOOK, "claude"], input=json.dumps(payload), text=True,
                       env={"PATH": "/usr/bin:/bin", "HOME": home, "PLANCHETTE_SESSION": sid,
                            "PLANCHETTE_SOCKET": sock_path}, timeout=15)
        return started

    started = fire("UserPromptSubmit", {"prompt": "hello from the probe"})
    seen = None
    for _ in range(100):
        if session_state(sid) == "running":
            seen = time.time() - started
            break
        time.sleep(0.02)
    note("hook_to_running_ms", None if seen is None else round(seen * 1000))
    fire("Stop")
    time.sleep(0.5)
    note("state_after_stop", session_state(sid))

    # ---- 3. connection abuse ----------------------------------------------------
    # 3a. a client that connects and says nothing
    client = socket.socket(socket.AF_UNIX)
    client.settimeout(30)
    client.connect(sock_path)
    started = time.time()
    try:
        data = client.recv(1)
        note("idle_client_dropped_after_s", round(time.time() - started, 1))
    except socket.timeout:
        note("idle_client_dropped_after_s", "not within 30 s")
    client.close()

    # 3b. 90 idle connections: how many does the server turn away at once?
    held, refused = [], 0
    for _ in range(90):
        conn = socket.socket(socket.AF_UNIX)
        conn.settimeout(0.05)
        try:
            conn.connect(sock_path)
        except ConnectionRefusedError:
            # The kernel's backlog was full: turned away before the app saw it.
            refused += 1
            conn.close()
            continue
        held.append(conn)
    time.sleep(1.5)
    for conn in held:
        conn.setblocking(False)
        try:
            if conn.recv(1) == b"":
                refused += 1
        except BlockingIOError:
            pass
        except OSError:
            refused += 1
    note("of_90_idle_connections_refused_at_once", refused)
    for conn in held:
        conn.close()
    time.sleep(0.5)
    note("answers_after_flood", rpc({"planchette_request": "session.list"})["ok"])

    # 3c. a 5 MiB request
    big = socket.socket(socket.AF_UNIX)
    big.settimeout(10)
    big.connect(sock_path)
    try:
        big.sendall(b'{"planchette_request":"session.list","pad":"' + b"a" * (5 << 20) + b'"}')
        big.shutdown(socket.SHUT_WR)
        reply = big.recv(65536)
        note("oversize_request_answer", "none (dropped)" if not reply else reply[:60].decode(errors="replace"))
    except OSError as err:
        note("oversize_request_answer", f"connection closed by server ({type(err).__name__})")
    big.close()
    time.sleep(0.5)
    note("answers_after_oversize", rpc({"planchette_request": "session.list"})["ok"])

    # 3d. a client that vanishes before the reply is written
    gone = socket.socket(socket.AF_UNIX)
    gone.connect(sock_path)
    gone.sendall(json.dumps({"planchette_request": "session.wait", "id": sid,
                             "until": ["error"], "timeout_ms": 2000}).encode())
    gone.shutdown(socket.SHUT_WR)
    gone.close()
    time.sleep(4)
    note("alive_after_vanishing_client", alive())
    note("answers_after_vanishing_client", rpc({"planchette_request": "session.list"})["ok"])

    # ---- 4. OSC 52 clipboard read probe ----------------------------------------
    out = f"{root}/osc52.out"
    type_in(sid, f"python3 {root}/probe.py {out}\n")
    reply_bytes = wait_file(out, 8)
    note("osc52_reply_bytes", reply_bytes)
    note("osc52_verdict",
         "READ ANSWERED IMMEDIATELY (clipboard reachable by any program)" if reply_bytes not in (None, "0")
         else "no answer without the user (a dialog is pending)")

    # ---- 5. title storms --------------------------------------------------------
    state_json = f"{state_dir}/state.json"

    def stored_title():
        data = json.load(open(state_json))
        for s in data["sessions"]:
            if s["id"] == sid:
                return s.get("oscTitle")
        return None

    time.sleep(2.5)                                  # let pending saves settle
    idle0 = cpu_seconds(); time.sleep(8); idle_cpu = cpu_seconds() - idle0
    note("idle_cpu_seconds_per_8s", round(idle_cpu, 2))

    done = f"{root}/glyph.done"
    print("--- screen BEFORE typing the glyph storm:", flush=True)
    print(rpc({"planchette_request": "session.read", "id": sid, "lines": 5})["result"]["text"], flush=True)
    type_in(sid, f"sh {root}/glyph-storm.sh {done} 8\n")
    time.sleep(1.5)
    print("--- screen 1.5s AFTER typing it:", flush=True)
    print(rpc({"planchette_request": "session.read", "id": sid, "lines": 5})["result"]["text"], flush=True)
    c0 = cpu_seconds(); m0 = os.stat(state_json).st_mtime_ns
    time.sleep(5)
    glyph_cpu = cpu_seconds() - c0
    wait_file(done, 10)
    time.sleep(2.5)
    note("glyph_storm_cpu_seconds_per_5s", round(glyph_cpu, 2))
    note("stored_title_after_glyph_storm", stored_title())

    done2 = f"{root}/text.done"
    type_in(sid, f"sh {root}/text-storm.sh {done2} 14\n")
    time.sleep(1.0)
    m_start = os.stat(state_json).st_mtime_ns
    t_start = time.time()
    first_change = None
    while time.time() - t_start < 18:
        if os.stat(state_json).st_mtime_ns != m_start:
            first_change = time.time() - t_start
            break
        time.sleep(0.1)
    note("text_storm_14s_first_save_after_s", None if first_change is None else round(first_change, 1))
    wait_file(done2, 10)

    # ---- 6. branch polling: latency and subprocess count --------------------------
    time.sleep(3)
    t0 = time.time()
    branch = None
    for _ in range(300):
        branch = notification(sid).get("branch")
        if branch == "feat/one":
            break
        time.sleep(0.1)
    note("branch_seen", branch)
    git("checkout", "-q", "-b", "feat/two")
    t1 = time.time()
    for _ in range(300):
        if notification(sid).get("branch") == "feat/two":
            break
        time.sleep(0.1)
    note("branch_change_noticed_after_s", round(time.time() - t1, 1))

    # idle window: count `git` processes the APP started
    mark = sum(1 for _ in open(gitlog))
    time.sleep(32)
    lines = open(gitlog).read().splitlines()[mark:]
    mine = [l for l in lines if l.startswith(f"ppid={app.pid} ")]
    note("git_processes_started_by_app_in_32s_idle", len(mine))
    note("git_calls_sample", [l.split(" ", 1)[1] for l in mine][:3])

    note("alive_at_end", alive())
finally:
    focus_guard.stop()
    app.send_signal(signal.SIGTERM)
    try:
        app.wait(timeout=10)
    except subprocess.TimeoutExpired:
        app.kill()
    try:
        os.unlink(f"/tmp/planchette-{app.pid}.sock")
    except OSError:
        pass
    json.dump(report, open(f"{root}/report.json", "w"), indent=2)
    print(f"[{label}] done", flush=True)
    files_guard.report(label)
