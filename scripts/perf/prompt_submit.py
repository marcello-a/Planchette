"""Does session.prompt SUBMIT what it types? Run against zsh, bash 3.2 or the real Claude Code CLI.

usage: prompt_submit.py <label> <binary> <scratch-folder> <zsh|bash|claude> [prompt-text ...]
  claude mode needs the `claude` CLI on PATH (or $CLAUDE_BIN); it runs against stub_api.py, never the real API.
  `battery [N]` as the prompt text runs the full battery in claude mode (N prompts in a row, default 12).
An isolated Planchette instance runs the program in its terminal. Then `session.prompt` is called
the way an agent would call it. For a shell the output line of the command is looked for on the
screen; for Claude Code the stand-in API server (stub_api.py) logs every request it receives, so a
prompt that was really submitted shows up there with its text.
"""
import json, os, signal, socket, subprocess, sys, time, shutil
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from perf_common import REPO, UserFilesGuard, scratch_root
label, binary, mode = sys.argv[1], sys.argv[2], sys.argv[4]
root = scratch_root(sys.argv[3])
binary = os.path.abspath(binary)   # the instance is started with cwd=/, so a relative path would not be found
extra_prompts = sys.argv[5:]
files_guard = UserFilesGuard()
scr = os.path.dirname(os.path.abspath(__file__))
state_dir = f"{root}/state"; os.makedirs(state_dir, exist_ok=True)
work = f"{root}/work"; os.makedirs(work, exist_ok=True)
home = f"{root}/home"; os.makedirs(f"{home}/.claude", exist_ok=True)
zdot = f"{root}/zdot"; os.makedirs(zdot, exist_ok=True)
stub_log = f"{root}/stub.log"; open(stub_log, "w").close()
G, S = "11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222"

# --- the program the terminal runs -------------------------------------------------------------
stub = None
if mode == "zsh":
    command = f"exec env ZDOTDIR={zdot} HISTFILE=/dev/null PS1='PROMPT> ' /bin/zsh -f -i"
elif mode == "bash":
    command = "exec /bin/bash --noprofile --norc"
elif mode == "claude":
    sock = socket.socket(); sock.bind(("127.0.0.1", 0)); port = sock.getsockname()[1]; sock.close()
    stub = subprocess.Popen([sys.executable, "-I", f"{scr}/stub_api.py", str(port), stub_log])
    time.sleep(0.5)
    # A fake key (the stand-in API accepts anything), built in two pieces so that no scanner
    # mistakes the source for a leaked Anthropic key.
    key = "sk-ant-" + "api03-" + "PLANCHETTESTUBKEY" * 3
    cfg = {
        "hasCompletedOnboarding": True, "theme": "dark", "numStartups": 12, "firstStartTime": "2026-01-01T00:00:00.000Z",
        "customApiKeyResponses": {"approved": [key[-20:]], "rejected": []},
        "hasAcknowledgedCostThreshold": True, "bypassPermissionsModeAccepted": True,
        "projects": {work: {"hasTrustDialogAccepted": True, "allowedTools": [], "hasCompletedProjectOnboarding": True,
                            "projectOnboardingSeenCount": 5}},
    }
    json.dump(cfg, open(f"{home}/.claude.json", "w"))
    json.dump(cfg, open(f"{home}/.claude/.claude.json", "w"))
    env_pairs = {
        "HOME": home, "CLAUDE_CONFIG_DIR": f"{home}/.claude", "ANTHROPIC_API_KEY": key,
        "ANTHROPIC_BASE_URL": f"http://127.0.0.1:{port}", "DISABLE_AUTOUPDATER": "1", "DISABLE_TELEMETRY": "1",
        "DISABLE_ERROR_REPORTING": "1", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "DISABLE_BUG_COMMAND": "1",
        "CLAUDE_CODE_DISABLE_TERMINAL_TITLE": "1", "NO_PROXY": "127.0.0.1", "no_proxy": "127.0.0.1",
    }
    exports = " ".join(f"{k}={v}" for k, v in env_pairs.items())
    claude = os.environ.get("CLAUDE_BIN") or shutil.which("claude")
    if not claude:
        raise SystemExit("claude mode needs the `claude` CLI on PATH (or set CLAUDE_BIN)")
    command = f"exec env {exports} {claude}"
else:
    raise SystemExit("mode must be zsh, bash or claude")

json.dump({"autoUpdateCheck": False, "aiEnabled": False, "language": "en", "durableTerminals": False,
  "groups": [{"id": G, "name": "probe", "sessionIDs": [S], "activeSessionID": S, "active": True, "favorite": False, "color": "none", "viewMode": "tabs"}],
  "sessions": [{"id": S, "groupID": G, "workingDirectory": work, "currentDirectory": work, "durable": False,
                "startupCommand": command, "resumeClaudeOnRestore": False, "state": "free",
                "stateSince": 780000000, "seen": True, "tags": [], "agentKind": "none", "color": "none"}],
  "windows": [{"id": "00000000-0000-0000-0000-0000000000a1", "groupIDs": [G], "selectedGroupID": G, "folders": [], "showsProjectOverview": False}]},
  open(f"{state_dir}/state.json", "w"))
env = {k: v for k, v in os.environ.items() if not k.startswith("PLANCHETTE_")}
env.update(PLANCHETTE_STATE_DIR=state_dir, GHOSTTY_RESOURCES_DIR=f"{REPO}/vendor/ghostty/zig-out/share/ghostty")
FRONT_BEFORE_LAUNCH = subprocess.run(["osascript", "-e", 'tell application "System Events" to get unix id of first process whose frontmost is true'],
                                     capture_output=True, text=True).stdout.strip()
app = subprocess.Popen([binary], env=env, stdout=open(f"{root}/app.log", "w"), stderr=subprocess.STDOUT, cwd="/")
sockpath = None
import threading
_guard_stop = threading.Event()
_stolen = []
def _focus_guard():
    # The instance activates itself at launch. Whoever was working keeps the keyboard: poll the
    # frontmost process for as long as the run lasts and hand the focus back at once.
    probe = 'tell application "System Events" to get unix id of first process whose frontmost is true'
    while not _guard_stop.is_set():
        r = subprocess.run(["osascript", "-e", probe], capture_output=True, text=True)
        if r.stdout.strip() == str(app.pid) and FRONT_BEFORE_LAUNCH:
            subprocess.run(["osascript", "-e", f'tell application "System Events" to set frontmost of (first process whose unix id is {FRONT_BEFORE_LAUNCH}) to true'], capture_output=True)
            _stolen.append(time.time())
        _guard_stop.wait(0.15)
threading.Thread(target=_focus_guard, daemon=True).start()

def rpc(payload, timeout=10):
    c = socket.socket(socket.AF_UNIX); c.settimeout(timeout); c.connect(sockpath)
    c.sendall(json.dumps(payload).encode()); c.shutdown(socket.SHUT_WR)
    b = b""
    while True:
        ch = c.recv(65536)
        if not ch: break
        b += ch
    return json.loads(b)

def screen(lines=40):
    r = rpc({"planchette_request": "session.read", "id": S, "lines": lines})
    return r["result"]["text"] if r.get("ok") else f"(read failed: {r})"

def stub_requests():
    out = []
    for line in open(stub_log):
        try: out.append(json.loads(line))
        except Exception: pass
    return out

def show(title, text):
    print(f"----- {title}", flush=True)
    for l in text.rstrip().splitlines()[-18:]:
        print("   | " + l.rstrip()[:150], flush=True)

try:
    for _ in range(80):
        time.sleep(0.25)
        try:
            sockpath = open(f"{state_dir}/socket").read().strip()
            if os.path.exists(sockpath): break
        except OSError: pass

    # --- wait until the program is ready for input -----------------------------------------------
    def is_ready(text):
        lines = [l.rstrip() for l in text.splitlines() if l.strip()]
        last = lines[-1].strip() if lines else ""
        if mode == "zsh": return last == "PROMPT>"          # the LAST line: the typed startup line contains the text too
        if mode == "bash": return last.endswith("$")
        return "shift+tab to cycle" in text or "for shortcuts" in text   # claude
    def frontmost():
        r = subprocess.run(["osascript", "-e", 'tell application "System Events" to get unix id of first process whose frontmost is true'],
                           capture_output=True, text=True)
        return r.stdout.strip()
    front_before = FRONT_BEFORE_LAUNCH
    started = time.time(); text = ""
    while time.time() - started < 60:
        time.sleep(1)
        text = screen()
        if is_ready(text): break
    ready = is_ready(text)
    print(f"[{label}/{mode}] focus: user's app pid {front_before!r}; my instance took it {len(_stolen)} time(s) so far, the guard gave it back", flush=True)
    print(f"[{label}/{mode}] ready after {time.time()-started:.1f}s: {ready}", flush=True)
    if not ready:
        show("screen while waiting (not ready)", text)
    time.sleep(1.5)

    def wait_for_request(token, timeout=8.0):
        t_end = time.time() + timeout
        while time.time() < t_end:
            for q in stub_requests():
                if q.get("path", "").startswith("/v1/messages") and token in (q.get("user_tail") or ""):
                    return q
            time.sleep(0.12)
        return None

    def prompt(text, submit=True):
        payload = {"planchette_request": "session.prompt", "id": S, "text": text, "force": True}
        if not submit: payload["submit"] = False
        return rpc(payload)

    def requests_containing(token):
        return [q for q in stub_requests() if q.get("path", "").startswith("/v1/messages") and token in (q.get("user_tail") or "")]

    if mode == "claude" and extra_prompts[:1] == ["battery"]:
        import threading
        count = int(extra_prompts[1]) if len(extra_prompts) > 1 else 12
        table = []
        # Warm-up: a first-run prompt of the TUI ("try the new renderer?") may swallow the first
        # prompts. Go on only once one has reached the API.
        warmed = False
        for w in range(1, 7):
            prompt(f"WARMUP_{w}_TOKEN")
            if wait_for_request(f"WARMUP_{w}_TOKEN", 6): warmed = True; break
            time.sleep(1)
        print(f"[{label}/claude] warm-up done after {w} prompt(s): {warmed}", flush=True)
        time.sleep(2)
        # A. repeated prompts, one after the other
        ok = 0; lat = []
        for i in range(1, count + 1):
            token = f"SEQ{i:03d}X"
            t0 = time.time(); r = prompt(token)
            q = wait_for_request(token)
            if r.get("ok") and q: ok += 1; lat.append(q["t"] - t0)
            else: print(f"[{label}/claude]   MISS: {token}", flush=True)
            time.sleep(1.0)
        table.append((f"{count} prompts in a row", f"{ok}/{count} submitted", f"median {sorted(lat)[len(lat)//2]*1000:.0f} ms to reach the API" if lat else "-"))
        print(f"[{label}/claude] A: {ok}/{count} submitted", flush=True)
        # B. multi-line text is ONE message
        prompt("ML_FIRST_LINE\nML_SECOND_LINE\nML_THIRD_LINE"); time.sleep(3)
        qs = requests_containing("ML_THIRD_LINE")
        tail = qs[0]["user_tail"] if qs else ""
        ordered = bool(qs) and tail.find("ML_FIRST_LINE") < tail.find("ML_SECOND_LINE") < tail.find("ML_THIRD_LINE") and tail.find("ML_FIRST_LINE") >= 0
        table.append(("multi-line text", f"{len(qs)} request(s); all three lines in order: {ordered}", "-"))
        print(f"[{label}/claude] B multi-line: requests={len(qs)} ordered={ordered}", flush=True)
        time.sleep(1.5)
        # C. quotes, dollar, backtick, umlauts, CJK, emoji
        special = 'SPECIAL "dq" \'sq\' $HOME `bt` \u00e4\u00f6\u00fc \u65e5\u672c\u8a9e \U0001F642 END_SPECIAL'
        prompt(special); q = wait_for_request("END_SPECIAL")
        intact = bool(q) and special in q["user_tail"]
        table.append(("quotes, $, backtick, umlauts, CJK, emoji", f"submitted: {bool(q)}; arrived intact: {intact}", "-"))
        print(f"[{label}/claude] C special: submitted={bool(q)} intact={intact}", flush=True)
        time.sleep(2)
        # D. three concurrent prompts to the same terminal
        tokens = ["CONC_AAAAAA", "CONC_BBBBBB", "CONC_CCCCCC"]
        threads = [threading.Thread(target=prompt, args=(t,)) for t in tokens]
        for th in threads: th.start()
        for th in threads: th.join()
        time.sleep(6)
        per = [requests_containing(t) for t in tokens]
        merged = [q for t in tokens for q in requests_containing(t) if sum(x in q["user_tail"] for x in tokens) > 1]
        table.append(("3 concurrent prompts", f"requests per prompt: {[len(x) for x in per]}; merged into one: {len(merged)}", "-"))
        print(f"[{label}/claude] D concurrent: per-prompt requests={[len(x) for x in per]} merged={len(merged)}", flush=True)
        time.sleep(2)
        # E. submit=false only types
        before_e = len(stub_requests())
        prompt("NOSUBMIT_TOKEN", submit=False); time.sleep(3)
        got = requests_containing("NOSUBMIT_TOKEN")
        on_screen = "NOSUBMIT_TOKEN" in screen()
        table.append(("submit=false", f"requests: {len(got)}; text waiting in the input box: {on_screen}", "-"))
        print(f"[{label}/claude] E submit=false: requests={len(got)} typed-on-screen={on_screen}", flush=True)
        show("final screen", screen())
        print(f"[{label}/claude] BATTERY: " + " | ".join(f"{a}: {b}" for a, b, _ in table), flush=True)
    else:
        prompts = extra_prompts or [f"PLANCHETTE_PROBE_{mode.upper()}_1"]
        results = []
        for n, spec in enumerate(prompts, 1):
            token = spec
            before = len(stub_requests())
            sent = f"echo {token}" if mode in ("zsh", "bash") else token
            payload = {"planchette_request": "session.prompt", "id": S, "text": sent, "force": True}
            t0 = time.time()
            r = rpc(payload)
            took = time.time() - t0
            print(f"[{label}/{mode}] session.prompt #{n} {sent!r}: ok={r.get('ok')} error={r.get('error')!r} (call took {took*1000:.0f} ms)", flush=True)
            ok = None
            if mode == "claude":
                for _ in range(40):                      # up to 8 s for the request to reach the stub
                    time.sleep(0.2)
                    reqs = [q for q in stub_requests()[before:] if q.get("path", "").startswith("/v1/messages") and token in (q.get("user_tail") or q.get("user_text") or "")]
                    if reqs: break
                ok = bool(reqs)
                print(f"[{label}/{mode}] #{n} prompt SUBMITTED (the stub API received it with exactly this text): {ok}", flush=True)
                time.sleep(2.5)                          # let the stub reply render and the box clear
            else:
                time.sleep(2)
                text = screen()
                lines = [l.rstrip() for l in text.splitlines()]
                ok = any(l.strip() == token for l in lines)
                print(f"[{label}/{mode}] #{n} command EXECUTED (its output line is on screen): {ok}", flush=True)
            results.append((spec, ok))
        show("final screen", screen())
        print(f"[{label}/{mode}] SUMMARY: " + ", ".join(f"{spec}={'yes' if ok else 'NO'}" for spec, ok in results), flush=True)
finally:
    _guard_stop.set()
    print(f"[{label}/{mode}] focus taken by my instance {len(_stolen)} time(s) in total", flush=True)
    app.send_signal(signal.SIGKILL)
    try: app.wait(timeout=10)
    except subprocess.TimeoutExpired: pass
    if stub: stub.kill()
    try: os.unlink(f"/tmp/planchette-{app.pid}.sock")
    except OSError: pass
    subprocess.run(["pkill", "-f", f"{root}/"], capture_output=True)
    files_guard.report(label)
