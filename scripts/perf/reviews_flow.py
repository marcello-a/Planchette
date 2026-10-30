#!/usr/bin/env python3
"""The Reviews panel end to end, in the real app.

usage: reviews_flow.py <path-to-Planchette-binary> <scratch-folder> [ui] [cleanup] [gif]
       (run through with_displays.sh; default: ui and cleanup)

  ui       start a review in a temporary worktree from the panel, let the findings arrive, open the
           row, set all findings to Skip, send. The buttons are pressed through the accessibility
           API (tools/axpress): no mouse, no keyboard, your pointer stays where it is.
  cleanup  a review that was sent: once sent.json is there, the row is "Sent", and the temporary
           worktree, its project and its branch are gone. Seeded, so no button is pressed.
  gif      not a check: records hints/reviews.gif, the loop the Reviews hint shows — the real
           panel, real presses, one frame per step, captioned. Set HINT_GIF_OUT to the file to
           write (needs ImageMagick).

Nothing here reaches GitHub or a real Claude:
- each instance is isolated (PLANCHETTE_STATE_DIR) and does not poll GitHub; its review request
  is seeded, for a repo that does not exist (acme/shop);
- `claude` is a fake on a PATH that the terminals' own zsh profile pins (ZDOTDIR), so the real one
  in ~/.local/bin cannot be reached. It logs its arguments and every line typed into it;
- the skill's two answers (findings.json, sent.json) are written by this script.

A window that is not on screen (the displays asleep) has no accessibility tree, and the presses
then find nothing: run it while the displays are on. `cleanup` does not depend on that.
"""
import json
import os
import signal
import socket
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from perf_common import RESOURCES, FocusGuard, UserFilesGuard, scratch_root, system_events_process, tool

URL = "https://github.com/acme/shop/pull/7"
PR = {"url": URL, "repo": "acme/shop", "number": 7, "title": "SHOP-7 · Round cart totals", "author": "lea",
      "isDraft": False, "additions": 12, "deletions": 3, "changedFiles": 2, "headRef": "lea/round",
      "headSha": "abc7", "baseRef": "main", "checks": "passed", "requestedFromMe": True}
FINDINGS = {"version": 1, "pr": {"url": URL, "repo": "acme/shop", "number": 7, "headSha": "abc7"},
            "summary": "Two things.", "findings": [
                {"id": "f1", "severity": "high", "path": "a.ts", "line": 3, "text": "Off by one cent.",
                 "decision": "comment"},
                {"id": "f2", "severity": "low", "path": "b.ts", "line": 9, "text": "Unused import.",
                 "decision": "skip"}]}
failures = []


def check(name, ok, detail=""):
    print(f"[reviews] {'ok  ' if ok else 'FAIL'} {name}{(' — ' + detail) if detail and not ok else ''}", flush=True)
    if not ok:
        failures.append(name)


def wait(predicate, seconds):
    end = time.time() + seconds
    while time.time() < end:
        try:
            value = predicate()
            if value:
                return value
        except (OSError, KeyError, ValueError, TypeError):
            pass
        time.sleep(0.3)
    return None


class Scene:
    """One isolated instance on a seeded workspace: a git repo `shop`, a fake claude, a pinned PATH."""

    def __init__(self, root):
        self.root = root
        self.state_dir, self.bindir, self.zdot, self.work = (os.path.join(root, d) for d in ("state", "bin", "zdot", "work"))
        for d in (self.state_dir, self.bindir, self.zdot, self.work):
            os.makedirs(d, exist_ok=True)
        os.chmod(self.state_dir, 0o700)
        self.repo = os.path.join(self.work, "shop")
        os.makedirs(self.repo, exist_ok=True)
        self.review_dir = os.path.join(self.state_dir, "reviews", "acme-shop-7")
        self.worktree = os.path.join(self.work, "shop.worktrees", "review-pr-7")
        self.git("init", "-q", "-b", "main")
        self.git("remote", "add", "origin", "git@github.com:acme/shop.git")
        self.git("-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "--allow-empty", "-m", "init")
        self.claude_log = os.path.join(root, "claude-calls.log")
        with open(os.path.join(self.bindir, "claude"), "w") as handle:
            handle.write(f'#!/bin/sh\nprintf "args: %s\\n" "$*" >> "{self.claude_log}"\n'
                         f'while IFS= read -r line; do printf "input: %s\\n" "$line" >> "{self.claude_log}"; done\n')
        os.chmod(os.path.join(self.bindir, "claude"), 0o755)
        self.path = f"{self.bindir}:/usr/bin:/bin:/usr/sbin:/sbin"
        for name in (".zshenv", ".zshrc"):
            with open(os.path.join(self.zdot, name), "w") as handle:
                handle.write(f"export PATH='{self.path}'\nunset HISTFILE\nPROMPT='%1~ ❯ '\n")
        self.app = None

    def git(self, *args):
        return subprocess.run(["/usr/bin/git", *args], cwd=self.repo, capture_output=True, text=True)

    def seed(self, groups, sessions, reviews, appearance="system"):
        with open(os.path.join(self.state_dir, "state.json"), "w") as handle:
            json.dump({
                "autoUpdateCheck": False, "aiEnabled": False, "durableTerminals": False, "language": "en",
                "appearance": appearance,
                "onboarding": {"welcomeSeen": True, "lastLaunchedVersion": "0.0.0", "durablePromptHidden": True},
                "groups": groups, "sessions": sessions,
                "windows": [{"id": "00000000-0000-0000-0000-0000000000a1", "groupIDs": [g["id"] for g in groups],
                             "selectedGroupID": groups[0]["id"], "folders": [], "showsProjectOverview": False}],
                "reviews": reviews,
            }, handle)

    @staticmethod
    def group(gid, name, sid, **extra):
        return {"id": gid, "name": name, "sessionIDs": [sid], "activeSessionID": sid, "active": True,
                "favorite": False, "color": "none", "viewMode": "tabs", **extra}

    @staticmethod
    def session(sid, gid, directory):
        return {"id": sid, "groupID": gid, "workingDirectory": directory, "currentDirectory": directory,
                "durable": False, "resumeClaudeOnRestore": False, "state": "free", "stateSince": 780000000,
                "seen": True, "tags": [], "agentKind": "none", "color": "none"}

    def launch(self, *args):
        env = {k: v for k, v in os.environ.items() if not k.startswith("PLANCHETTE_")}
        env.update(PLANCHETTE_STATE_DIR=self.state_dir, GHOSTTY_RESOURCES_DIR=RESOURCES, ZDOTDIR=self.zdot, PATH=self.path)
        self.focus = FocusGuard()
        self.app = subprocess.Popen(
            [binary, "-ApplePersistenceIgnoreState", "YES", "-inboxShown", "YES", "-inboxMode", "reviews", *args],
            env=env, cwd="/", stdout=open(os.path.join(self.root, "app.log"), "w"), stderr=subprocess.STDOUT)
        self.focus.start(self.app.pid)
        check("socket published", wait(lambda: os.path.exists(os.path.join(self.state_dir, "socket")), 30))

    def stop(self):
        if self.app:
            self.focus.stop()
            self.app.send_signal(signal.SIGKILL)
        subprocess.run(["pkill", "-f", f"{self.root}/"], capture_output=True)

    def rpc(self, payload):
        sock_path = open(os.path.join(self.state_dir, "socket")).read().strip()
        client = socket.socket(socket.AF_UNIX)
        client.settimeout(20)
        client.connect(sock_path)
        client.sendall(json.dumps(payload).encode())
        client.shutdown(socket.SHUT_WR)
        data = b""
        while chunk := client.recv(65536):
            data += chunk
        client.close()
        return json.loads(data)

    def review(self):
        rows = self.rpc({"planchette_request": "review.list"})["result"]["reviews"]
        return next((r for r in rows if r["url"] == URL), None)

    def projects(self):
        return [p["name"] for p in self.rpc({"planchette_request": "project.list"})["result"]["projects"]]

    def log_lines(self):
        try:
            return open(self.claude_log).read().splitlines()
        except OSError:
            return []

    def press(self, label, seconds=40, nth=0):
        """Press a button by its accessibility label. Retried: a row that just opened, or a window
        that is still being built, has no buttons yet."""
        end = time.time() + seconds
        while True:
            out = subprocess.run([tool("axpress"), str(self.app.pid), label, str(nth)], capture_output=True, text=True, timeout=60)
            if out.returncode == 3:
                raise SystemExit("this terminal is not trusted for accessibility: grant it in System Settings → Privacy")
            if out.returncode == 0 or time.time() > end:
                return out.returncode == 0
            time.sleep(0.5)

    def write(self, name, payload):
        os.makedirs(self.review_dir, exist_ok=True)
        with open(os.path.join(self.review_dir, name), "w") as handle:
            json.dump(payload, handle)


def scene_ui(root):
    s = Scene(root)
    G, S = "11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222"
    s.seed([s.group(G, "shop", S)], [s.session(S, G, s.repo)],
           {URL: {"pr": PR, "stage": "requested", "since": 780000000, "unread": True, "updated": False,
                  "temporary": False, "decisions": {}, "sending": False}})
    try:
        s.launch("-reviewFocus", URL)
        system_events_process(s.app.pid)          # never script a pid System Events confuses with another
        row = wait(s.review, 20)
        check("the seeded request is listed", row and row["stage"] == "requested" and row["section"] == "needs_you", str(row))
        check("press Temporary worktree", s.press("Temporary worktree*"))
        check("press Start review", s.press("Start review"))
        row = wait(lambda: (r := s.review()) and r.get("checkout") and r, 30)
        check("stage is reviewing, in a temporary worktree", row and row["stage"] == "reviewing" and row["temporary"], str(row))
        worktree = row and row.get("checkout")
        check("the worktree exists beside the repo",
              bool(worktree) and os.path.isdir(worktree) and worktree.endswith("shop.worktrees/review-pr-7"), str(worktree))
        args = wait(lambda: next((l for l in s.log_lines() if l.startswith("args: ")), None), 20)
        check("claude got the review command", args == f'args: /review-pr {URL} --dir "{s.review_dir}" --keep-checkout', str(args))

        s.write("findings.json", FINDINGS)
        row = wait(lambda: (r := s.review()) and r["stage"] == "findings" and r, 10)
        check("findings arrive, unread", row and row.get("findings") == 2 and row["unread"], str(row))
        check("verdict preselected: request changes", row and row.get("verdict") == "REQUEST_CHANGES", str(row))

        pressed = s.press("SHOP-7 · Round cart totals*", seconds=10)
        if not pressed and os.environ.get("REVIEWS_DEBUG"):
            out = subprocess.run([tool("axtree"), str(s.app.pid)], capture_output=True, text=True, timeout=60).stdout
            for line in out.splitlines():
                r = json.loads(line)
                if r["x"] > 1100 and (r["title"] or r["desc"] or r["value"]):
                    print("   ", r["d"], r["role"], "|", (r["title"] or r["desc"] or r["value"])[:70], r["x"], r["y"], flush=True)
        check("press the row", pressed)
        check("press Skip (Set all)", s.press("Skip"))
        row = wait(lambda: (r := s.review()) and r.get("verdict") == "APPROVE" and r, 5)
        check("all skipped: verdict becomes approve", bool(row), str(s.review()))
        check("press Send review", s.press("Send review"))
        decisions = wait(lambda: json.load(open(os.path.join(s.review_dir, "decisions.json"))), 10)
        check("decisions.json written", decisions and decisions["verdict"] == "APPROVE"
              and decisions["decisions"] == {"f1": "skip", "f2": "skip"}, str(decisions))
        submit = wait(lambda: next((l for l in s.log_lines() if l.startswith("input: /review-pr submit")), None), 15)
        check("the review terminal got the submit prompt", submit == f'input: /review-pr submit "{s.review_dir}"', str(submit))
        row = s.review()
        check("the row says sending", row and row["sending"], str(row))
    finally:
        s.stop()


def scene_cleanup(root):
    s = Scene(root)
    s.git("worktree", "add", "-q", "-b", "review/pr-7", s.worktree)
    G, S = "11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222"
    G2, S2 = "11111111-1111-1111-1111-222222222222", "22222222-2222-2222-2222-333333333333"
    s.seed([s.group(G, "shop", S), s.group(G2, "shop · #7", S2, worktreePath=s.worktree, worktreeRepoRoot=s.repo)],
           [s.session(S, G, s.repo), s.session(S2, G2, s.worktree)],
           {URL: {"pr": PR, "stage": "findings", "since": 780000000, "unread": False, "updated": False,
                  "temporary": True, "checkout": s.worktree, "repoRoot": s.repo, "sessionID": S2, "groupID": G2,
                  "decisions": {"f1": "skip"}, "verdict": "APPROVE", "sending": True}})
    s.write("findings.json", FINDINGS)
    try:
        s.launch()
        check("the sending review is listed", (r := wait(s.review, 20)) and r["stage"] == "findings" and r["sending"], str(r))
        check("its worktree project is open", s.projects() == ["shop", "shop · #7"], str(s.projects()))
        s.write("sent.json", {"version": 1, "verdict": "APPROVE", "reviewUrl": URL + "#review", "errors": []})
        row = wait(lambda: (r := s.review()) and r["stage"] == "sent" and r, 10)
        check("stage is sent, approved", row and row.get("verdict") == "APPROVE" and not row["sending"], str(s.review()))
        check("the temporary worktree is removed", bool(wait(lambda: not os.path.exists(s.worktree), 30)), s.worktree)
        check("the review branch is deleted",
              bool(wait(lambda: s.git("branch", "--list", "review/pr-7").stdout.strip() == "", 10)),
              s.git("branch", "--list", "review/pr-7").stdout)
        check("the review project is closed", wait(lambda: s.projects() == ["shop"], 10), str(s.projects()))
        row = s.review()
        check("the sent row no longer points at the worktree", row and "checkout" not in row and not row["temporary"], str(row))
        check("the user's own project is untouched", os.path.isdir(s.repo) and s.git("status", "--porcelain").stdout == "")
    finally:
        s.stop()


GIF_STEPS = [
    # (frame, caption, seconds)
    ("request", "A PR asks for your review", 1.8),
    ("picker", "Pick a checkout nobody works in", 2.4),
    ("reviewing", "Claude reviews it in its own terminal", 1.8),
    ("findings", "Decide on each finding", 2.4),
    ("decided", "Set all at once, then change single ones", 2.4),
    ("sent", "Nothing is sent before you click Send", 2.6),
]


def other_pr(number, title, author):
    return dict(PR, url=f"https://github.com/acme/shop/pull/{number}", number=number, title=title, author=author,
                headSha=f"sha{number}")


def scene_gif(root):
    s = Scene(root)
    spare = os.path.join(s.work, "shop.worktrees", "spare")
    s.git("worktree", "add", "-q", "--detach", spare)
    open(os.path.join(s.repo, "notes.txt"), "w").write("work in progress\n")     # the main checkout is busy
    G, S = "11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222"
    ago = lambda minutes: time.time() - 978307200 - minutes * 60      # the app counts from 2001
    a = other_pr(5, "SHOP-5 · Retry failed uploads", "tim")
    b = other_pr(9, "SHOP-9 · Format menu as a sheet", "lea")
    s.seed([s.group(G, "shop", S)], [s.session(S, G, s.repo)], {
        URL: {"pr": PR, "stage": "requested", "since": ago(12), "unread": True, "updated": False,
              "temporary": False, "decisions": {}, "sending": False},
        b["url"]: {"pr": b, "stage": "reviewing", "since": ago(6), "unread": False, "updated": False,
                   "temporary": False, "checkout": s.repo, "decisions": {}, "sending": False},
        a["url"]: {"pr": a, "stage": "sent", "since": ago(26 * 60), "unread": False, "updated": False,
                   "temporary": False, "decisions": {}, "sending": False, "verdict": "REQUEST_CHANGES",
                   "reviewedSha": "sha5"},
    }, appearance="dark")
    shots = os.path.join(root, "shots")
    os.makedirs(shots, exist_ok=True)

    def shot(name):
        time.sleep(1.2)
        wins = subprocess.run([tool("windows"), str(s.app.pid)], capture_output=True, text=True).stdout.split()
        check(f"frame {name}", bool(wins))
        if wins:
            subprocess.run(["screencapture", "-x", "-o", "-l", wins[0], os.path.join(shots, f"{name}.png")], capture_output=True)

    try:
        s.launch()
        system_events_process(s.app.pid)
        wait(s.review, 20)
        shot("request")
        check("press the row", s.press("SHOP-7 · Round cart totals*"))
        time.sleep(2)                                          # the checkout scan
        shot("picker")
        check("press Start review", s.press("Start review"))
        wait(lambda: (r := s.review()) and r["stage"] == "reviewing" and r, 20)
        shot("reviewing")
        s.write("findings.json", dict(FINDINGS, summary="Rounds each line before the sum. One place still uses the raw total."))
        wait(lambda: (r := s.review()) and r["stage"] == "findings" and r, 10)
        check("press the row again", s.press("SHOP-7 · Round cart totals*"))
        shot("findings")
        check("press Comment (Set all)", s.press("Comment"))
        shot("decided")
        check("press Send review", s.press("Send review"))
        wait(lambda: os.path.exists(os.path.join(s.review_dir, "decisions.json")), 10)
        s.write("sent.json", {"version": 1, "verdict": "REQUEST_CHANGES", "reviewUrl": URL, "errors": []})
        wait(lambda: (r := s.review()) and r["stage"] == "sent" and r, 10)
        shot("sent")
        # Where the panel is, from the window's corner, in points.
        rows = [json.loads(l) for l in subprocess.run([tool("axtree"), str(s.app.pid)], capture_output=True,
                                                     text=True).stdout.splitlines() if l.startswith("{")]
        win = next(r for r in rows if r["role"] == "AXWindow")
        named = lambda r, role, name: r["role"] == role and name in (r["title"], r["desc"], r["value"])
        box = next(r for r in rows if named(r, "AXCheckBox", "Only mine"))
        refresh = next(r for r in rows if named(r, "AXButton", "Refresh"))
        left, top = box["x"] - 12 - win["x"], refresh["y"] - 12 - win["y"]
        crop = {"x": left, "y": top, "w": win["w"] - left, "h": 400}
    finally:
        s.stop()
    out = os.environ.get("HINT_GIF_OUT")
    if out and all(os.path.exists(os.path.join(shots, f"{n}.png")) for n, _, _ in GIF_STEPS):
        build_gif(shots, out, crop)


def build_gif(shots, out, box):
    """Crop the panel's top, caption every frame, loop."""
    frames = []
    k = 2                                                              # a retina screenshot
    for name, caption, seconds in GIF_STEPS:
        src, dst = os.path.join(shots, f"{name}.png"), os.path.join(shots, f"{name}-done.png")
        subprocess.run(["magick", src, "-crop", f"{box['w'] * k}x{box['h'] * k}+{box['x'] * k}+{box['y'] * k}", "+repage",
                        "-resize", "600x", "-gravity", "South", "-background", "#1d1d1f", "-fill", "white",
                        "-pointsize", "26", "-splice", "0x56", "-annotate", "+0+14", caption, dst], check=True)
        frames += ["-delay", str(int(seconds * 100)), dst]
    subprocess.run(["magick", *frames, "-loop", "0", "+dither", "-colors", "64", "-layers", "Optimize", out], check=True)
    print(f"[reviews] wrote {out} ({os.path.getsize(out) // 1024} KB)", flush=True)


binary = os.path.abspath(sys.argv[1])
base = scratch_root(sys.argv[2])
wanted = sys.argv[3:] or ["ui", "cleanup"]
files = UserFilesGuard()
for name in wanted:
    print(f"[reviews] --- {name}", flush=True)
    {"ui": scene_ui, "cleanup": scene_cleanup, "gif": scene_gif}[name](scratch_root(os.path.join(base, name)))
files.report("reviews")
print(f"[reviews] {'all checks passed' if not failures else 'FAILED: ' + ', '.join(failures)}")
sys.exit(1 if failures else 0)
