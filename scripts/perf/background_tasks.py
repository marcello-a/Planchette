"""Does Planchette notice what the real Claude Code runs in the background?

usage: background_tasks.py <label> <binary> <scratch-folder>
The real `claude` CLI (needs it on PATH, or $CLAUDE_BIN) runs in an isolated Planchette instance
against stub_api.py, which makes it start real background work without any model behind it: two
shells (`sleep 45`, `sleep 90`) and an agent (25 s). Its hooks reach the instance through the
repository's own hook script, exactly as an installed one would.

Three views of the same moment:
  footer   what Claude Code itself prints under its prompt ("2 shells") - the truth. It counts
           shells only; a background agent is listed in a panel below it instead.
  app      what Planchette reports for the terminal: `session.get` -> `background_tasks`
           (the sidebar badge is drawn from the same list)
  picture  a screenshot of the window in `<scratch>/shots`, for a person to look at

A pass: the app counts the shells and the agent as they start, and says nothing once the last
one ended. Run it through with_displays.sh, like the other GUI scripts.
"""
import json, os, re, signal, socket, subprocess, sys, time, shutil
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from perf_common import REPO, FocusGuard, UserFilesGuard, scratch_root, tool
label, binary = sys.argv[1], sys.argv[2]
root = scratch_root(sys.argv[3])
binary = os.path.abspath(binary)   # the instance is started with cwd=/, so a relative path would not be found
files_guard = UserFilesGuard(); focus_guard = FocusGuard()
here = os.path.dirname(os.path.abspath(__file__))
state_dir = f"{root}/state"; os.makedirs(state_dir, exist_ok=True)
work = f"{root}/work"; os.makedirs(work, exist_ok=True)
home = f"{root}/home"; os.makedirs(f"{home}/.claude", exist_ok=True)
shots = f"{root}/shots"; os.makedirs(shots, exist_ok=True)
stub_log = f"{root}/stub.log"; open(stub_log, "w").close()
G, S = "11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222"

# --- Claude Code, isolated: its own home and config, the stand-in API, the repository's hook -----
claude = os.environ.get("CLAUDE_BIN") or shutil.which("claude")
if not claude:
    raise SystemExit("needs the `claude` CLI on PATH (or set CLAUDE_BIN)")
sock = socket.socket(); sock.bind(("127.0.0.1", 0)); port = sock.getsockname()[1]; sock.close()
stub = subprocess.Popen([sys.executable, "-I", f"{here}/stub_api.py", str(port), stub_log])
time.sleep(0.5)
key = "sk-ant-" + "api03-" + "PLANCHETTESTUBKEY" * 3   # fake, built in pieces so no scanner takes it for a leak
cfg = {
    "hasCompletedOnboarding": True, "theme": "dark", "numStartups": 12, "firstStartTime": "2026-01-01T00:00:00.000Z",
    "customApiKeyResponses": {"approved": [key[-20:]], "rejected": []}, "hasAcknowledgedCostThreshold": True,
    "projects": {work: {"hasTrustDialogAccepted": True, "allowedTools": [], "hasCompletedProjectOnboarding": True,
                        "projectOnboardingSeenCount": 5}},
    # first-run questions Claude Code would otherwise ask (and a key press could not answer)
    "hasResetAutoModeOptInForDefaultOffer": True, "hasSeenAutoDefaultNudge": True, "fullscreenUpsellSeenCount": 10,
    "lastReleaseNotesSeen": "2.1.299",
}
json.dump(cfg, open(f"{home}/.claude.json", "w")); json.dump(cfg, open(f"{home}/.claude/.claude.json", "w"))
hook = {"type": "command", "command": f"{REPO}/hook/planchette-hook claude"}
events = ["SessionStart", "UserPromptSubmit", "Notification", "PermissionRequest", "PreToolUse", "PostToolUse", "Stop",
          "SubagentStop", "SessionEnd"]   # HookInstaller.events
json.dump({"permissions": {"allow": ["Bash(sleep *)", "Agent"], "defaultMode": "default"},
           "hooks": {e: [{"matcher": "*", "hooks": [hook]}] if e in ("PreToolUse", "PostToolUse") else [{"hooks": [hook]}] for e in events}},
          open(f"{home}/.claude/settings.json", "w"))
env_pairs = {"HOME": home, "CLAUDE_CONFIG_DIR": f"{home}/.claude", "ANTHROPIC_API_KEY": key,
             "ANTHROPIC_BASE_URL": f"http://127.0.0.1:{port}", "DISABLE_AUTOUPDATER": "1", "DISABLE_TELEMETRY": "1",
             "DISABLE_ERROR_REPORTING": "1", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "DISABLE_BUG_COMMAND": "1",
             "NO_PROXY": "127.0.0.1", "no_proxy": "127.0.0.1"}
command = "exec env " + " ".join(f"{k}={v}" for k, v in env_pairs.items()) + f" {claude}"

json.dump({"autoUpdateCheck": False, "aiEnabled": False, "language": "en", "durableTerminals": False,
  "groups": [{"id": G, "name": "probe", "sessionIDs": [S], "activeSessionID": S, "active": True, "favorite": False, "color": "none", "viewMode": "tabs"}],
  "sessions": [{"id": S, "groupID": G, "workingDirectory": work, "currentDirectory": work, "durable": False,
                "startupCommand": command, "resumeClaudeOnRestore": False, "state": "free",
                "stateSince": 780000000, "seen": True, "tags": [], "agentKind": "none", "color": "none"}],
  "windows": [{"id": "00000000-0000-0000-0000-0000000000a1", "groupIDs": [G], "selectedGroupID": G, "folders": [], "showsProjectOverview": False}]},
  open(f"{state_dir}/state.json", "w"))
env = {k: v for k, v in os.environ.items() if not k.startswith("PLANCHETTE_")}
env.update(PLANCHETTE_STATE_DIR=state_dir, GHOSTTY_RESOURCES_DIR=f"{REPO}/vendor/ghostty/zig-out/share/ghostty")
app = subprocess.Popen([binary], env=env, stdout=open(f"{root}/app.log", "w"), stderr=subprocess.STDOUT, cwd="/")
focus_guard.start(app.pid)
sockpath = None


def rpc(payload, timeout=10):
    c = socket.socket(socket.AF_UNIX); c.settimeout(timeout); c.connect(sockpath)
    c.sendall(json.dumps(payload).encode()); c.shutdown(socket.SHUT_WR)
    b = b""
    while True:
        ch = c.recv(65536)
        if not ch: break
        b += ch
    return json.loads(b)


def screen():
    r = rpc({"planchette_request": "session.read", "id": S, "lines": 45})
    return r["result"]["text"] if r.get("ok") else ""


def footer_shells(text):
    """What Claude itself prints in its footer: "2 shells" -> 2, nothing -> 0."""
    m = re.search(r"(\d+) shells?\b", text)
    return int(m.group(1)) if m else 0


def idle(text):
    tail = "\n".join([l for l in text.splitlines() if l.strip()][-4:])
    return "manual mode on" in tail and "esc to interrupt" not in tail


def app_tasks():
    """What Planchette says about the terminal: (shells, agents). The key is absent when nothing runs."""
    r = rpc({"planchette_request": "session.get", "id": S})
    session = (r.get("result") or {}).get("session") or r.get("result") or {}
    tasks = session.get("background_tasks") or {}
    return tasks.get("shells", 0), tasks.get("agents", 0)


def shot(name):
    windows = subprocess.run([tool("windows"), str(app.pid)], capture_output=True, text=True).stdout.splitlines()
    best = None
    for line in windows:
        m = re.match(r"(\d+) layer=0 (\d+)x(\d+)", line)
        if m and (best is None or int(m.group(2)) * int(m.group(3)) > best[1]):
            best = (m.group(1), int(m.group(2)) * int(m.group(3)))
    if not best:
        return None
    path = f"{shots}/{name}.png"
    subprocess.run(["screencapture", "-x", "-o", "-l", best[0], path], capture_output=True)
    return path if os.path.exists(path) and os.path.getsize(path) > 0 else None


results = []   # (check, ok)
try:
    for _ in range(80):
        time.sleep(0.25)
        try:
            sockpath = open(f"{state_dir}/socket").read().strip()
            if os.path.exists(sockpath): break
        except OSError: pass
    started = time.time(); text = ""
    while time.time() - started < 60:
        time.sleep(1); text = screen()
        if idle(text): break
    print(f"[{label}] Claude Code ready after {time.time()-started:.1f}s: {idle(text)}", flush=True)
    time.sleep(1.5)
    print(f"[{label}] before anything runs: app says {app_tasks()} (shells, agents)", flush=True)
    results.append(("nothing is reported before a task starts", app_tasks() == (0, 0)))

    def prompt(text):
        end = time.time() + 40
        while time.time() < end and not idle(screen()): time.sleep(0.5)
        rpc({"planchette_request": "session.prompt", "id": S, "text": text, "force": True})

    t0 = time.time()
    # (prompt, shells running afterwards, agents running afterwards): nothing ends before the check
    plan = [("BGSHELL45", 1, 0), ("BGSHELL90", 2, 0), ("BGAGENT25", 2, 1)]
    for token, shells, agents in plan:
        prompt(token)
        time.sleep(7)
        footer, said = footer_shells(screen()), app_tasks()
        print(f"[{label}] after {token}: Claude's footer says {footer} shell(s); app says {said[0]} shell(s), {said[1]} agent(s)"
              f"   (expected {shells} and {agents})", flush=True)
        results.append((f"{token}: footer {shells} shell(s)", footer == shells))
        results.append((f"{token}: app {shells} shell(s), {agents} agent(s)", said == (shells, agents)))
        print(f"[{label}]   picture: {shot(f'after-{token}')}", flush=True)
    # now let them end on their own: the agent first, then the 45 s shell, then the 90 s one
    last = None; trace = []
    end = time.time() + 110
    while time.time() < end:
        footer, said = footer_shells(screen()), app_tasks()
        if (footer, said) != last:
            trace.append((round(time.time() - t0, 1), footer, said)); last = (footer, said)
            print(f"[{label}]   t={trace[-1][0]:5.1f}s  footer {footer} shell(s); app {said[0]} shell(s), {said[1]} agent(s)", flush=True)
            if sum(said) == 1 and len(trace) > 3: print(f"[{label}]   picture: {shot('one-left')}", flush=True)
        if footer == 0 and said == (0, 0): break
        time.sleep(0.7)
    print(f"[{label}]   picture: {shot('end')}", flush=True)
    results.append(("the app says nothing once the last task ended", last is not None and last[1] == (0, 0)))
    print(f"[{label}] RESULT: " + "; ".join(f"{name}: {'ok' if ok else 'FAIL'}" for name, ok in results), flush=True)
finally:
    stub.kill()
    focus_guard.stop()
    app.send_signal(signal.SIGKILL)
    try: app.wait(timeout=10)
    except subprocess.TimeoutExpired: pass
    try: os.unlink(f"/tmp/planchette-{app.pid}.sock")
    except OSError: pass
    subprocess.run(["pkill", "-f", f"{root}/"], capture_output=True)
    files_guard.report(label)
