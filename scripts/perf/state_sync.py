"""Does the state icon follow what really happens in the terminal?

usage: state_sync.py <label> <binary> <scratch-folder> [scenario ...]     (default: every scenario)

Each scenario starts its own isolated instance (PLANCHETTE_STATE_DIR) and drives something that used
to leave the icon wrong, then waits for the state the terminal should end in:

  shell-ends              a command asks "Do you want to continue? (y/n)", is answered, finishes   -> ready, and stays
  shell-aborted           the same command, killed with SIGINT (what Ctrl+C does) while it asks     -> free
  shell-fails             the same command, ending with exit 3                                      -> error
  shell-plain             `true`, `false`, and `sleep` ended with SIGINT                            -> ready, error, free
  claude-abort-early      a real Claude Code turn, Ctrl+C before anything was printed               -> free
  claude-abort-streaming  a real turn that is printing an answer, Ctrl+C                            -> free
  claude-esc-at-dialog    a real permission dialog ("?"), Esc                                       -> free
  claude-killed           a real turn, `kill -9` of Claude (no SessionEnd hook ever comes)          -> error
  claude-approved-tool    a real permission dialog, answered with Enter, a tool that goes on for 25 s -> running, not waiting
  claude-mcp-allowed      a real MCP call (mcp_probe.py, 25 s) that needs no answer                  -> running all along
  claude-mcp-approved     the same MCP call behind a permission dialog, answered with Enter          -> running, not waiting
  claude-background-shell a turn that starts a shell with `sleep 25` in the background and ends       -> running until the shell ends

The shell scenarios run the user's login shell (zsh, with Ghostty's shell integration) with an EMPTY
ZDOTDIR, so no dotfile runs, in a terminal whose agentKind is `claude` - which is what a terminal keeps
once Claude ran in it. The claude scenarios run the real `claude` CLI (on PATH, or $CLAUDE_BIN) against
stub_api.py; a durable terminal lives in the instance's OWN tmux server (planchette-<hash of the state
folder>), so `tmux send-keys` can press a real Ctrl+C - Planchette's API only pastes text.

Run it through with_displays.sh. ~40 s per scenario. A state is "reached" when it shows within 25 s: the
screen is read every 1.5 s with the app in front and every 6 s behind, and a bold reading needs two polls.
"""
import hashlib, json, os, re, shutil, signal, socket, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from perf_common import REPO, FocusGuard, UserFilesGuard, scratch_root

HERE = os.path.dirname(os.path.abspath(__file__))
G, S = "11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222"
SCENARIOS = ["shell-ends", "shell-aborted", "shell-fails", "shell-plain",
             "claude-abort-early", "claude-abort-streaming", "claude-esc-at-dialog", "claude-killed",
             "claude-approved-tool", "claude-mcp-allowed", "claude-mcp-approved", "claude-background-shell"]


def wait_for(predicate, timeout, step=0.4):
    end = time.time() + timeout
    while time.time() < end:
        if predicate():
            return True
        time.sleep(step)
    return False


class Instance:
    """One isolated Planchette with one terminal, optionally the stand-in API and a Claude config."""

    def __init__(self, label, binary, root, durable, claude, allow=()):
        self.allow = list(allow)
        self.root = root
        self.state_dir = f"{root}/state"; os.makedirs(self.state_dir, exist_ok=True)
        self.work = f"{root}/work"; os.makedirs(self.work, exist_ok=True)
        zdot = f"{root}/zdot"; os.makedirs(zdot, exist_ok=True)
        open(f"{zdot}/.zshrc", "w").write("PROMPT='PROMPT> '\nHISTFILE=/dev/null\n")
        self.stub = None
        self.marker = f"plt-state-sync-{os.getpid()}"
        self.durable = durable
        self.tmux_server = "planchette-" + hashlib.sha256(self.state_dir.encode()).digest()[:4].hex()
        self.files_guard = UserFilesGuard(); self.focus_guard = FocusGuard()
        if claude:
            self._claude_setup()
        json.dump({"autoUpdateCheck": False, "aiEnabled": False, "language": "en", "durableTerminals": durable,
          "groups": [{"id": G, "name": "probe", "sessionIDs": [S], "activeSessionID": S, "active": True, "favorite": False, "color": "none", "viewMode": "tabs"}],
          "sessions": [{"id": S, "groupID": G, "workingDirectory": self.work, "currentDirectory": self.work, "durable": durable,
                        "resumeClaudeOnRestore": False, "state": "free", "stateSince": 780000000, "seen": True,
                        "tags": [], "agentKind": "claude" if not claude else "none", "color": "none"}],
          "windows": [{"id": "00000000-0000-0000-0000-0000000000a1", "groupIDs": [G], "selectedGroupID": G, "folders": [], "showsProjectOverview": False}]},
          open(f"{self.state_dir}/state.json", "w"))
        env = {k: v for k, v in os.environ.items() if not k.startswith("PLANCHETTE_")}
        env.update(PLANCHETTE_STATE_DIR=self.state_dir, GHOSTTY_RESOURCES_DIR=f"{REPO}/vendor/ghostty/zig-out/share/ghostty",
                   ZDOTDIR=zdot, HISTFILE="/dev/null")
        self.app = subprocess.Popen([binary], env=env, stdout=open(f"{root}/app.log", "w"), stderr=subprocess.STDOUT, cwd="/")
        self.focus_guard.start(self.app.pid)
        self.sockpath = None
        for _ in range(80):
            time.sleep(0.25)
            try:
                self.sockpath = open(f"{self.state_dir}/socket").read().strip()
                if os.path.exists(self.sockpath): break
            except OSError: pass
        if not wait_for(lambda: "PROMPT>" in self.screen(), 30):
            raise SystemExit("the shell did not come up")
        time.sleep(1.0)

    def _claude_setup(self):
        claude = os.environ.get("CLAUDE_BIN") or shutil.which("claude")
        if not claude:
            raise SystemExit("claude scenarios need the `claude` CLI on PATH (or set CLAUDE_BIN)")
        home = f"{self.root}/home"; os.makedirs(f"{home}/.claude", exist_ok=True)
        stub_log = f"{self.root}/stub.log"; open(stub_log, "w").close()
        s = socket.socket(); s.bind(("127.0.0.1", 0)); port = s.getsockname()[1]; s.close()
        self.stub = subprocess.Popen([sys.executable, "-I", f"{HERE}/stub_api.py", str(port), stub_log])
        time.sleep(0.5)
        key = "sk-ant-" + "api03-" + "PLANCHETTESTUBKEY" * 3
        cfg = {"hasCompletedOnboarding": True, "theme": "dark", "numStartups": 12, "firstStartTime": "2026-01-01T00:00:00.000Z",
               "customApiKeyResponses": {"approved": [key[-20:]], "rejected": []}, "hasAcknowledgedCostThreshold": True,
               "projects": {self.work: {"hasTrustDialogAccepted": True, "allowedTools": [], "hasCompletedProjectOnboarding": True,
                                        "projectOnboardingSeenCount": 5}},
               "hasResetAutoModeOptInForDefaultOffer": True, "hasSeenAutoDefaultNudge": True, "fullscreenUpsellSeenCount": 10,
               "lastReleaseNotesSeen": "99.0.0",
               # an MCP server of the user's own scope: no project approval to answer first
               "mcpServers": {"probe": {"type": "stdio", "command": sys.executable, "args": ["-I", f"{HERE}/mcp_probe.py"]}}}
        json.dump(cfg, open(f"{home}/.claude.json", "w")); json.dump(cfg, open(f"{home}/.claude/.claude.json", "w"))
        hook = {"type": "command", "command": f"{REPO}/hook/planchette-hook claude"}
        events = ["SessionStart", "UserPromptSubmit", "Notification", "PermissionRequest", "PreToolUse", "PostToolUse", "Stop",
                  "SubagentStop", "SessionEnd"]   # HookInstaller.events
        json.dump({"permissions": {"allow": self.allow, "defaultMode": "default"},
                   "hooks": {e: [{"matcher": "*", "hooks": [hook]}] if e in ("PreToolUse", "PostToolUse") else [{"hooks": [hook]}] for e in events}},
                  open(f"{home}/.claude/settings.json", "w"))
        pairs = {"HOME": home, "CLAUDE_CONFIG_DIR": f"{home}/.claude", "ANTHROPIC_API_KEY": key, "ANTHROPIC_BASE_URL": f"http://127.0.0.1:{port}",
                 "DISABLE_AUTOUPDATER": "1", "DISABLE_TELEMETRY": "1", "DISABLE_ERROR_REPORTING": "1",
                 "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "DISABLE_BUG_COMMAND": "1", "NO_PROXY": "127.0.0.1", "no_proxy": "127.0.0.1"}
        self.claude_command = ("exec " if self.durable else "") + "env " + " ".join(f"{k}={v}" for k, v in pairs.items()) \
            + f" {claude} --append-system-prompt {self.marker}"

    def rpc(self, payload, timeout=10):
        c = socket.socket(socket.AF_UNIX); c.settimeout(timeout); c.connect(self.sockpath)
        c.sendall(json.dumps(payload).encode()); c.shutdown(socket.SHUT_WR)
        b = b""
        while True:
            ch = c.recv(65536)
            if not ch: break
            b += ch
        return json.loads(b)

    def state(self):
        return (self.rpc({"planchette_request": "session.get", "id": S}).get("result") or {}).get("session", {}).get("state", "?")

    def screen(self, n=40):
        r = self.rpc({"planchette_request": "session.read", "id": S, "lines": n})
        return r["result"]["text"] if r.get("ok") else ""

    def type_line(self, text):
        self.rpc({"planchette_request": "session.prompt", "id": S, "text": text, "force": True})

    def at_prompt(self):
        lines = [l.rstrip() for l in self.screen().splitlines() if l.strip()]
        return bool(lines) and lines[-1].strip() == "PROMPT>"

    def tmux(self, *args):
        return subprocess.run([shutil.which("tmux") or "/opt/homebrew/bin/tmux", "-L", self.tmux_server, *args], capture_output=True, text=True)

    def press(self, key):
        """A real key press into the durable terminal's pane (tmux, the instance's own server)."""
        return self.tmux("send-keys", "-t", f"=planchette-{S.lower()}:", key)

    def start_claude(self):
        self.type_line(self.claude_command)
        if not wait_for(lambda: "manual mode on" in self.screen(), 40):
            raise SystemExit("Claude Code did not reach its prompt")
        time.sleep(1.5)

    def reaches(self, wanted, timeout=25):
        """The states seen until `wanted` shows (or the time is up): (reached, 'a -> b -> c')."""
        seen = []; end = time.time() + timeout
        while time.time() < end:
            s = self.state()
            if not seen or seen[-1] != s: seen.append(s)
            if s == wanted: return True, " -> ".join(seen)
            time.sleep(0.5)
        return False, " -> ".join(seen)

    def timeline(self, seconds, step=0.5):
        """The states seen over `seconds`, each with how long it stayed: 'waiting 2.5s -> running 11.0s'."""
        spans, end = [], time.time() + seconds
        while time.time() < end:
            s, now = self.state(), time.time()
            if spans and spans[-1][0] == s: spans[-1][2] = now
            else: spans.append([s, now, now])
            time.sleep(step)
        return " -> ".join(f"{s} {b - a + step:.1f}s" for s, a, b in spans)

    def spans(self, seconds, step=0.5):
        """The states seen over `seconds` as (state, seconds since the start when it began)."""
        seen, start = [], time.time()
        while time.time() - start < seconds:
            s = self.state()
            if not seen or seen[-1][0] != s: seen.append((s, round(time.time() - start, 1)))
            time.sleep(step)
        return seen

    def close(self):
        self.focus_guard.stop()
        self.app.send_signal(signal.SIGKILL)
        try: self.app.wait(timeout=10)
        except subprocess.TimeoutExpired: pass
        if self.stub: self.stub.kill()
        if self.durable: self.tmux("kill-server")   # this instance's server only
        try: os.unlink(f"/tmp/planchette-{self.app.pid}.sock")
        except OSError: pass
        subprocess.run(["pkill", "-f", f"{self.root}/"], capture_output=True)
        self.files_guard.report(os.path.basename(self.root))


def ask_script(root):
    path = f"{root}/work/ask.sh"
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "w").write('''#!/bin/sh
# $1 = exit code at the end, $2 = seconds the command goes on after the answer
echo "==> Downloading something"
printf 'Do you want to continue? (y/n) '
read answer
echo "answer: $answer"
sleep ${2:-4}
echo "all done"
exit ${1:-0}
''')
    os.chmod(path, 0o755)
    return path


def shell(name, root, binary):
    ask = ask_script(root)
    inst = Instance(name, binary, root, durable=False, claude=False)
    try:
        if name == "shell-ends":
            inst.type_line(f"{ask} 0 3"); wait_for(lambda: "Do you want to continue" in inst.screen(), 10)
            inst.type_line("y"); wait_for(inst.at_prompt, 15)
            ok, seen = inst.reaches("ready", 8)
            time.sleep(4)   # the question is still on the screen: it must not come back
            return ok and inst.state() == "ready", f"{seen}; 4 s later: {inst.state()}"
        if name == "shell-aborted":
            inst.type_line(f"{ask} 0 40"); wait_for(lambda: "Do you want to continue" in inst.screen(), 10)
            time.sleep(3); subprocess.run(["pkill", "-INT", "-f", ask], capture_output=True)
            ok, seen = inst.reaches("free", 8)
            return ok, seen
        if name == "shell-fails":
            inst.type_line(f"{ask} 3 2"); wait_for(lambda: "Do you want to continue" in inst.screen(), 10)
            inst.type_line("y"); wait_for(inst.at_prompt, 15)
            return inst.reaches("error", 8)
        if name == "shell-plain":
            results = []
            for command, wanted in (("true", "ready"), ("false", "error")):
                inst.type_line(command); wait_for(inst.at_prompt, 10)
                results.append((command, inst.reaches(wanted, 6)))
            inst.type_line("sleep 4243"); time.sleep(2.5)
            subprocess.run(["pkill", "-INT", "-f", "sleep 4243"], capture_output=True)
            results.append(("sleep+SIGINT", inst.reaches("free", 6)))
            return all(r[1][0] for r in results), "; ".join(f"{c}: {r[1]}" for c, r in results)
    finally:
        inst.close()


def claude(name, root, binary):
    inst = Instance(name, binary, root, durable=name != "claude-killed", claude=True,
                    allow=["mcp__probe__slow"] if name == "claude-mcp-allowed" else [])
    try:
        inst.start_claude()
        if name == "claude-approved-tool":
            # A permission dialog, answered with Enter, and a tool that then takes 25 s: what does the icon say meanwhile?
            inst.type_line("PERMWAIT25 please wait a while")
            if not inst.reaches("waiting", 30)[0]: return False, f"no question (state {inst.state()}); screen: {inst.screen(14)!r}"
            time.sleep(2); inst.press("Enter")
            line = inst.timeline(34)
            return "running" in line.split("->")[1] if "->" in line else False, line
        if name == "claude-background-shell":
            # The turn starts a shell that sleeps 25 s and ends at once: what does the icon say while the shell runs?
            inst.type_line("BGSHELL25 start something and tell me")
            began = time.time()
            first = inst.spans(8)
            # The turn is over, the shell runs: the API talks about the turn (turn_state) and does not refuse a prompt.
            got = inst.rpc({"planchette_request": "session.get", "id": S})["result"]["session"]
            prompted = inst.rpc({"planchette_request": "session.prompt", "id": S, "text": "STREAM2 and now this"})
            rest = inst.spans(36)
            seen = first + [(s, round(t + time.time() - began - 36, 1)) for s, t in rest]
            line = " -> ".join(f"{s}@{t}s" for s, t in seen) + f"; get: state={got.get('state')} turn_state={got.get('turn_state')}; prompt ok={prompted.get('ok')} {prompted.get('error', '')}"
            # idle before the shell is over (it began ~2 s after the prompt) is the old, wrong answer
            idle_early = [t for s, t in seen if s in ("ready", "free") and 1 < t < 20]
            held = got.get("state") == "running" and got.get("turn_state") in ("ready", "free")
            return not idle_early and held and prompted.get("ok") is True, line
        if name in ("claude-mcp-allowed", "claude-mcp-approved"):
            inst.type_line("MCPCALL25 call the server")
            if name == "claude-mcp-approved":
                if not inst.reaches("waiting", 40)[0]: return False, f"no question (state {inst.state()}); screen: {inst.screen(16)!r}"
                time.sleep(2); inst.press("Enter")
            line = inst.timeline(36)
            states = [part.split()[0] for part in line.split(" -> ")]
            return states[:1] == ["running"] or "running" in states, line
        if name == "claude-abort-early":
            inst.type_line("SLOW60 please take your time")
            if not inst.reaches("running", 10)[0]: return False, "never ran"
            time.sleep(3); inst.press("C-c")
            return inst.reaches("free")
        if name == "claude-abort-streaming":
            inst.type_line("STREAM60 please answer at length")
            if not inst.reaches("running", 10)[0]: return False, "never ran"
            time.sleep(4); inst.press("C-c")
            return inst.reaches("free")
        if name == "claude-esc-at-dialog":
            inst.type_line("ASKPERM1 please make a file")
            if not inst.reaches("waiting", 15)[0]: return False, f"no question (state {inst.state()})"
            time.sleep(2); inst.press("Escape")
            return inst.reaches("free")
        if name == "claude-killed":
            inst.type_line("SLOW60 please take your time")
            if not inst.reaches("running", 10)[0]: return False, "never ran"
            time.sleep(2); subprocess.run(["pkill", "-9", "-f", inst.marker], capture_output=True)
            return inst.reaches("error", 10)
    finally:
        inst.close()


def main():
    label, binary, base = sys.argv[1], os.path.abspath(sys.argv[2]), sys.argv[3]
    wanted = sys.argv[4:] or SCENARIOS
    unknown = [w for w in wanted if w not in SCENARIOS]
    if unknown: raise SystemExit(f"unknown scenario(s) {unknown}; choose from {SCENARIOS}")
    base = scratch_root(base)
    results = []
    for name in wanted:
        root = scratch_root(f"{base}/{name}")
        shutil.rmtree(root, ignore_errors=True); os.makedirs(root, exist_ok=True)
        try:
            ok, detail = (shell if name.startswith("shell") else claude)(name, root, binary)
        except SystemExit as e:
            ok, detail = False, str(e)
        results.append((name, ok))
        print(f"[{label}] {'ok  ' if ok else 'FAIL'} {name:24} {detail}", flush=True)
    print(f"[{label}] RESULT: " + "; ".join(f"{n}: {'ok' if ok else 'FAIL'}" for n, ok in results), flush=True)


if __name__ == "__main__":
    main()
