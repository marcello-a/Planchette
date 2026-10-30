"""The pictures in docs/images, taken from the running app.

usage: screenshots.py <binary> [--out <folder>] [scene ...]      (run through with_displays.sh)

Scenes: overview folder cluster search welcome settings update reviews reviews-picker settings-panel settings-layout   (default: all)

Every scene starts its own ISOLATED instance (PLANCHETTE_STATE_DIR) on a demo workspace that is
made up here — nothing of yours is in it — waits for the first frame, and captures the window by
id (screencapture -l) at full resolution. The big ones are then scaled and stripped with
ImageMagick (`magick`) when it is installed, to keep the repository small.

Notes
- The build is wrapped in a throwaway .app (the real icon, version 0.0.1, its own bundle id and an
  ad-hoc signature) so the pictures show the icon a user sees, and the update scene is offered a
  release. Nothing is installed; the wrapper is deleted afterwards.
- The first frame is what is captured. A window the app does not draw (hidden behind other
  windows, on a display that is off) keeps its first frame, so every scene is built to be complete
  at launch: the terminals print their text from a startup command, the states are in the seed.
- `update` shows the real dialog: the instance asks GitHub for the latest release and, being an
  unbundled build (version 0.0.0), is offered it. Offline there is no dialog and no picture.
- The window gets a fixed size (1440 x 900) on the biggest display: the frame is written to the
  wrapper's own preferences before every launch (`seed_window_frame`). Without that its size is
  whatever the last run saved. The key names the SwiftUI window by its type; if a change to
  `ContentView`'s modifiers renames it, the seed stops working and the default size comes back.
- Standard library only (AGENTS.md rule 1); `magick` is optional.
"""
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from perf_common import REPO, RESOURCES, FocusGuard, UserFilesGuard, system_events_process, tool

NOW = time.time()
REFERENCE = 978307200  # 2001-01-01 in Unix time: the app stores dates as seconds since then


def ago(seconds):
    return NOW - REFERENCE - seconds


# ---- what the terminals print -------------------------------------------------------------

ESC = "\x1b["
RESET, BOLD, DIM = ESC + "0m", ESC + "1m", ESC + "2m"
GREEN, RED, BLUE, MAGENTA, CYAN = (ESC + f"{n}m" for n in (32, 31, 34, 35, 36))


def visible(text):
    return re.sub(r"\x1b\[[0-9;]*m", "", text)


def box(lines, width=34):
    """A rounded box around lines that may carry colors: padded by what is visible."""
    out = ["╭" + "─" * (width + 2) + "╮"]
    for line in lines:
        out.append("│ " + line + " " * (width - len(visible(line))) + " │")
    out.append("╰" + "─" * (width + 2) + "╯")
    return "\n".join(out)


def tool_line(name, argument):
    return f"  {DIM}{name}{RESET}({argument})"


# Short lines: the terminals of a cluster are narrow, and wrapped text is a messy picture.
OUTPUT = {
    "asks": "\n".join([
        f"{BOLD}● Splitting the cart summary.{RESET}", "",
        tool_line("Read", "src/cart/CartSummary.tsx"),
        tool_line("Update", "src/cart/CartSummary.tsx"),
        f"    {DIM}⎿  +38 −71 lines{RESET}",
        tool_line("Write", "src/cart/useCartTotals.ts"), "",
        f"{BOLD}● Next: the e2e suite.{RESET}", "",
        box([f"Run {BOLD}npm run e2e{RESET}?",
             f"{BLUE}❯ 1. Yes{RESET}",
             "  2. Yes, always",
             "  3. No, tell Claude why"], width=24),
    ]),
    "works": "\n".join([
        f'{BOLD}● Adding the express checkout.{RESET}', "",
        tool_line("Read", "src/cart/CartActions.tsx"),
        tool_line("Update", "src/cart/CartActions.tsx"),
        tool_line("Write", "src/cart/Express.test.tsx"), "",
        f"{MAGENTA}✻ Running the new test…{RESET} {DIM}(12s){RESET}",
    ]),
    "fails": "\n".join([
        "$ npm test -- cart", "",
        f"{RED} FAIL {RESET} src/cart/Cart.test.tsx",
        f"  {RED}●{RESET} keeps quantity after reload", "",
        f"    Expected: {GREEN}3{RESET}",
        f"    Received: {RED}1{RESET}", "",
        f"Tests: {RED}2 failed{RESET}, {GREEN}41 passed{RESET}",
        "npm test exited with 1",
    ]),
    "done": "\n".join([
        f"{BOLD}● Done. Notes for 2.4 written.{RESET}", "",
        "  Changes",
        f"    CHANGELOG.md          {GREEN}+18{RESET}",
        f"    docs/upgrading.md     {GREEN}+6{RESET} {RED}−2{RESET}", "",
        f"  {GREEN}All 43 tests pass.{RESET}",
    ]),
    "quiet": "\n".join([
        f"{DIM}$ git log --oneline -4{RESET}",
        f"{CYAN}d663b8a{RESET} Cover the reducer with tests",
        f"{CYAN}fbeb8ec{RESET} Extract the cart summary",
        f"{CYAN}4d98621{RESET} Set up the skeleton",
        f"{CYAN}09ac7e1{RESET} Initial commit",
    ]),
}

# ---- the demo workspace ---------------------------------------------------------------------

# project, folder, color, favorite, [terminal: summary, state, output, task, message, tags, minutes ago]
# `running` and `waiting` cannot be seeded: a restart resets them, because they describe a live process.
# Nor can the rest: every state comes from what happens in the terminal after launch (see `drive`).
# They are set after launch with the hook events a real agent sends (see `drive`).
PROJECTS = [
    ("storefront", "Storefront", "none", True, [
        ("Cart summary split", "waiting", "asks", "Split the cart summary into its own component",
         "May I run the e2e suite? It restarts the dev server.", [], 3),
        ("Express checkout", "running", "works", "Add the express checkout button and cover it with a test", None, ["review"], 7),
        ("Flaky cart test", "error", "fails", "Make the cart test stop flaking", "npm test exited with 1 — 2 specs failed", ["blocked"], 2),
    ]),
    ("storefront-api", "Storefront", "green", False, [
        ("Rate limiter per key", "error", "fails", "Make the rate limiter respect the per-key window", "npm test exited with 1 — 2 specs failed", [], 2),
        ("API docs", "free", "quiet", "Update the API docs for rate limits", None, [], 240),
    ]),
    ("design-system", "Storefront", "pink", False, [
        ("Spacing tokens, new scale", "ready", "done", "Rename the spacing tokens to the new scale", None, [], 12),
        ("Release notes for 2.4", "ready", "done", "Write the release notes for 2.4", None, [], 31),
        ("Publish 2.0.0-rc.3", "waiting", "asks", "Publish the release candidate", "Publish @acme/design-system@2.0.0-rc.3 to the registry?", ["to test"], 4),
    ]),
    ("infra", "Platform", "teal", False, [
        ("Warm the CDN cache", "running", "works", "Warm the CDN cache after each deploy", None, [], 1),
    ]),
    ("docs-site", "Platform", "orange", False, [
        ("Docs site", "free", "quiet", "Fix the sidebar links", None, [], 180),
    ]),
]

# Most projects hold one terminal: each one is a single row (Settings → Project panel → Layout).
SINGLE_PROJECTS = [
    PROJECTS[0],
    (PROJECTS[1][0], "Storefront", "green", False, PROJECTS[1][4][:1]),
    (PROJECTS[2][0], "Storefront", "pink", False, PROJECTS[2][4][2:3]),
    ("checkout", "Storefront", "none", False, [
        ("Checkout tests", "ready", "done", "Cover the express checkout with an e2e test", None, ["review"], 18),
    ]),
    PROJECTS[3],
    PROJECTS[4],
]

FOLDER_COLORS = {"Storefront": "blue", "Platform": "none"}


def demo_state(root, selected="storefront", active=0, view="tabs", appearance="dark", folder_page=False,
               projects=None, **extra):
    """The workspace as a state.json, plus a plan: what to do in each terminal once its shell is up."""
    work = os.path.join(root, "work")
    groups, sessions, folder_ids, plan = [], [], {}, []
    for index, (name, folder, color, favorite, terminals) in enumerate(projects or PROJECTS):
        gid = f"11111111-0000-0000-0000-{index:012d}"
        directory = os.path.join(work, name)
        os.makedirs(directory, exist_ok=True)
        ids = []
        for t, (summary, state, output, task, message, tags, minutes) in enumerate(terminals):
            sid = f"22222222-0000-0000-{index:04d}-{t:012d}"
            ids.append(sid)
            log = f"{t}.log"
            with open(os.path.join(directory, log), "w") as handle:
                handle.write(OUTPUT[output] + "\n")
            plan.append({"id": sid, "log": log, "state": state, "task": task, "message": message})
            sessions.append({
                "id": sid, "groupID": gid, "workingDirectory": directory, "currentDirectory": directory,
                "durable": False, "resumeClaudeOnRestore": False,
                "state": "free", "stateSince": ago(minutes * 60), "seen": state not in ("error", "ready"),
                "tags": tags, "agentKind": "claude" if output != "quiet" else "none", "color": "none",
                "aiSummary": summary,
                **({"currentTask": task, "firstTask": task} if task else {}),
                **({"lastMessage": message} if message else {}),
            })
        groups.append({
            "id": gid, "name": name, "sessionIDs": ids,
            "activeSessionID": ids[active] if name == selected and active < len(ids) else ids[0],
            "active": True, "favorite": favorite, "color": color,
            "viewMode": view if name == selected else "tabs",
        })
        folder_ids.setdefault(folder, []).append(gid)
    folders = [
        {"id": f"33333333-0000-0000-0000-{n:012d}", "name": name, "color": FOLDER_COLORS[name],
         "collapsed": False, "groupIDs": ids}
        for n, (name, ids) in enumerate(folder_ids.items())
    ]
    selected_id = next(g["id"] for g in groups if g["name"] == selected)
    state = {
        "autoUpdateCheck": False, "aiEnabled": False, "language": "en", "durableTerminals": False,
        "appearance": appearance,
        "onboarding": {"welcomeSeen": True, "lastLaunchedVersion": "0.0.0", "durablePromptHidden": True},
        "groups": groups, "sessions": sessions,
        "windows": [{"id": "00000000-0000-0000-0000-0000000000a1", "groupIDs": [g["id"] for g in groups],
                     "selectedGroupID": selected_id, "folders": folders, "showsProjectOverview": False}],
    }
    if folder_page:   # the first folder's overview page fills the main area
        state["windows"][0]["selectedFolderID"] = folders[0]["id"]
    state.update(extra)
    return state, plan


# ---- the Reviews panel ------------------------------------------------------------------------

REVIEW_REPO = "acme/storefront"


def review_pr(number, title, author, add, delete, files, mine=True, team=None, checks="passed"):
    return {"url": f"https://github.com/{REVIEW_REPO}/pull/{number}", "repo": REVIEW_REPO, "number": number,
            "title": title, "author": author, "isDraft": False, "additions": add, "deletions": delete,
            "changedFiles": files, "headRef": f"{author}/feat-{number}", "headSha": f"sha{number}",
            "baseRef": "main", "checks": checks, "requestedFromMe": mine, **({"team": team} if team else {})}


def review_record(pr, stage, minutes, unread, **extra):
    record = {"pr": pr, "stage": stage, "since": ago(minutes * 60), "unread": unread, "updated": False,
              "temporary": False, "decisions": {}, "sending": False}
    record.update(extra)
    return record


def reviews_state(root):
    """The demo workspace with reviews in every stage. The storefront projects become real git
    checkouts of one repo, plus a worktree nobody works in — so the picker has free and busy ones."""
    state, plan = demo_state(root, selected="storefront", active=0)
    work = os.path.join(root, "work")
    for name in ("storefront", "storefront-api"):
        repo = os.path.join(work, name)
        for args in (["init", "-q", "-b", "main"], ["remote", "add", "origin", f"git@github.com:{REVIEW_REPO}.git"],
                     ["-c", "user.name=demo", "-c", "user.email=demo@example.com", "commit", "-q", "--allow-empty", "-m", "init"]):
            subprocess.run(["git", *args], cwd=repo, capture_output=True)
    subprocess.run(["git", "worktree", "add", "-q", "--detach", os.path.join(work, "storefront.worktrees", "spare")],
                   cwd=os.path.join(work, "storefront"), capture_output=True)
    subprocess.run(["git", "worktree", "add", "-q", "--detach", os.path.join(work, "storefront-api.worktrees", "old-spike")],
                   cwd=os.path.join(work, "storefront-api"), capture_output=True)
    a = review_pr(5612, "SHOP-2093 · Express checkout button in the cart", "lea-m", 142, 38, 9)
    b = review_pr(5620, "SHOP-2101 · Round cart totals per line", "jonas-b", 64, 21, 4)
    c = review_pr(5598, "SHOP-2088 · Format menu as a bottom sheet", "lea-m", 311, 120, 14, checks="pending")
    d = review_pr(5571, "SHOP-2070 · Retry failed uploads", "tim-r", 88, 12, 5)
    reviews = {
        a["url"]: review_record(a, "requested", 12, True),
        b["url"]: review_record(b, "findings", 3, True, checkout=os.path.join(work, "storefront.worktrees", "review-pr-5620"),
                                temporary=True, decisions={"f4": "skip"}),
        c["url"]: review_record(c, "reviewing", 6, False, checkout=os.path.join(work, "storefront-api")),
        d["url"]: review_record(d, "sent", 60 * 26, False, verdict="REQUEST_CHANGES", reviewedSha="sha5571"),
    }
    state["reviews"] = reviews
    findings_dir = os.path.join(root, "state", "reviews", f"{REVIEW_REPO.replace('/', '-')}-5620")
    os.makedirs(findings_dir, exist_ok=True)
    with open(os.path.join(findings_dir, "findings.json"), "w") as handle:
        json.dump({"version": 1, "pr": {"url": b["url"], "repo": REVIEW_REPO, "number": 5620, "headSha": "sha5620"},
                   "summary": "Rounds each cart line before the sum. The idea is right; two places still use the unrounded total.",
                   "findings": [
                       {"id": "f1", "severity": "high", "path": "src/cart/useCartTotals.ts", "line": 41,
                        "text": "Each line is rounded before the sum, but the voucher applies to the unrounded total. Cart and checkout can differ by 1 cent.",
                        "comment": "The voucher still uses the raw total here.", "decision": "comment"},
                       {"id": "f2", "severity": "medium", "path": "src/cart/CartSummary.tsx", "line": 88,
                        "text": "toFixed(2) returns a string, and the template compares it with a number, so the free-shipping hint never shows.",
                        "suggestion": "const total = Math.round(sum * 100) / 100", "decision": "comment"},
                       {"id": "f3", "severity": "low", "path": "src/cart/useCartTotals.ts", "line": 12,
                        "text": "The import formatPrice is not used.", "suggestion": "", "decision": "skip"},
                       {"id": "f4", "severity": "low", "path": "src/cart/cart.test.ts",
                        "text": "No test for a cart with a voucher and three or more lines.", "decision": "comment"},
                   ]}, handle)
    return state, plan


# ---- a build, wrapped as an app ---------------------------------------------------------------

INFO_PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Planchette</string>
    <key>CFBundleDisplayName</key><string>Planchette</string>
    <key>CFBundleIdentifier</key><string>build.planchette.screenshots</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>{version}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>Planchette</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
"""


def make_app(binary, folder, version="0.0.1"):
    """The executable of a throwaway Planchette.app built around `binary`. Its bundle id is not the
    installed app's, so it shares no preferences with it; ad-hoc signed, as the real one is."""
    app = os.path.join(folder, "Planchette.app")
    macos, resources = os.path.join(app, "Contents", "MacOS"), os.path.join(app, "Contents", "Resources")
    os.makedirs(macos)
    os.makedirs(resources)
    shutil.copy2(binary, os.path.join(macos, "Planchette"))
    shutil.copy2(os.path.join(REPO, "macos", "Planchette", "Resources", "AppIcon.icns"), resources)
    shutil.copytree(RESOURCES, os.path.join(resources, "ghostty"))
    terminfo = os.path.join(os.path.dirname(RESOURCES), "terminfo")
    if os.path.isdir(terminfo):
        shutil.copytree(terminfo, os.path.join(resources, "terminfo"))
    with open(os.path.join(app, "Contents", "Info.plist"), "w") as handle:
        handle.write(INFO_PLIST.format(version=version))
    subprocess.run(["codesign", "--force", "--sign", "-", app], check=True, capture_output=True)
    return os.path.join(macos, "Planchette")


BUNDLE_ID = "build.planchette.screenshots"
FRAME_KEY = ("NSWindow Frame SwiftUI.PresentedWindowContent<Foundation.UUID, SwiftUI.ModifiedContent<"
             "SwiftUI.ModifiedContent<Planchette.ContentView, SwiftUI._EnvironmentKeyWritingModifier<"
             "Swift.Optional<Planchette.AppState>>>, SwiftUI._FlexFrameLayout>>-1-AppWindow-1")


def seed_window_frame(width=1440, height=900):
    """Tell the wrapper where its main window goes: centred on the biggest display, at this size."""
    screens = []
    for line in subprocess.run([tool("screens")], capture_output=True, text=True).stdout.splitlines():
        parts = line.split()
        if len(parts) == 5:
            screens.append(tuple(int(p) for p in parts))
    if not screens:
        return
    x, y, w, h, _ = max(screens, key=lambda screen: screen[2] * screen[3])
    width, height = min(width, w), min(height, h)
    frame = f"{x + (w - width) // 2} {y + (h - height) // 2} {width} {height} {x} {y} {w} {h} "
    subprocess.run(["defaults", "write", BUNDLE_ID, FRAME_KEY, "-string", frame], capture_output=True)


def forget_wrapper():
    """The wrapper's preferences and saved window state are nobody's but this script's."""
    subprocess.run(["defaults", "delete", BUNDLE_ID], capture_output=True)
    shutil.rmtree(os.path.expanduser(f"~/Library/Saved Application State/{BUNDLE_ID}.savedState"), ignore_errors=True)


# ---- running a scene ------------------------------------------------------------------------

def request(path, payload, timeout=10):
    client = socket.socket(socket.AF_UNIX)
    client.settimeout(timeout)
    client.connect(path)
    client.sendall(json.dumps(payload).encode())
    client.shutdown(socket.SHUT_WR)
    data = b""
    while True:
        chunk = client.recv(65536)
        if not chunk:
            break
        data += chunk
    client.close()
    return json.loads(data) if data else {}


def drive(state_dir, plan):
    """Bring the demo terminals to life the way daily use does. A terminal prints its text by a
    command typed through the control API once its shell shows a prompt (a startup command is typed
    at a moment the shell may not be reading yet). A command that ends sets the state its exit code
    names — a failing one is the error — and the live states, running and waiting, come from the
    hook events a Claude Code in the terminal would send, through the same socket."""
    if not plan:
        return
    try:
        path = open(os.path.join(state_dir, "socket")).read().strip()
    except OSError:
        return

    def screen(sid):
        reply = request(path, {"planchette_request": "session.read", "id": sid, "lines": 6})
        return (reply.get("result") or {}).get("text", "") if reply.get("ok") else ""

    for item in plan:
        for _ in range(60):
            if "❯" in screen(item["id"]):
                break
            time.sleep(0.5)
        # An agent that is running or asking holds the terminal: no shell prompt under its text.
        ending = {"error": "; false", "running": "; exec sleep 3600", "waiting": "; exec sleep 3600"}.get(item["state"], "")
        command = f"clear; cat {item['log']}{ending}"
        request(path, {"planchette_request": "session.prompt", "id": item["id"], "text": command, "force": True})
        time.sleep(0.3)
    time.sleep(2.5)
    for item in plan:
        sid, events = item["id"], []
        if item["state"] in ("running", "waiting"):
            events.append({"hook_event_name": "UserPromptSubmit", "prompt": item["task"]})
        if item["state"] == "waiting":
            events.append({"hook_event_name": "Notification", "message": item["message"]})
        if item["state"] == "free":
            events.append({"hook_event_name": "SessionStart", "source": "startup"})
        for event in events:
            payload = {"planchette_session": sid, "agent": "claude", "event": {**event, "session_id": "demo-" + sid[-4:]}}
            try:
                request(path, payload, timeout=5)
            except OSError:
                pass
            time.sleep(0.15)
    time.sleep(2)


def windows(pid):
    found = []
    out = subprocess.run([tool("windows"), str(pid)], capture_output=True, text=True).stdout.splitlines()
    for line in out:
        m = re.match(r"(\d+) layer=(\d+) (\d+)x(\d+) alpha=\S+ name=(.*)", line)
        if m:
            found.append({"id": int(m[1]), "layer": int(m[2]), "w": int(m[3]), "h": int(m[4]), "name": m[5]})
    return found


def capture(window_id, path):
    subprocess.run(["screencapture", "-x", "-o", "-l", str(window_id), path], capture_output=True)
    return os.path.exists(path)


def finish(path, scale):
    """Scale and strip a picture, when ImageMagick is there; the full-size one otherwise."""
    magick = shutil.which("magick") or ("/opt/homebrew/bin/magick" if os.path.exists("/opt/homebrew/bin/magick") else None)
    if magick:
        resize = ["-resize", f"{scale}x"] if scale else []
        subprocess.run([magick, path, *resize, "-strip", path], capture_output=True)


def run_scene(binary, name, out_dir, state=None, args=(), menu=None, wait=9.0, pick="main", scale=1800):
    """One instance, one picture. `menu` is (menu, item) to click through System Events once the
    first frame is up; `pick` is which window to capture: main, other (a dialog) or title:<text>."""
    root = tempfile.mkdtemp(prefix=f"plt-shots-{name}-")
    root = os.path.realpath(root)
    state_dir = os.path.join(root, "state")
    os.makedirs(state_dir)
    zdot = os.path.join(root, "zdot")
    os.makedirs(zdot)
    with open(os.path.join(zdot, ".zshrc"), "w") as handle:
        handle.write("PROMPT='%F{blue}%1~%f %F{magenta}❯%f '\nunset HISTFILE\nunsetopt BEEP\n")
    plan = []
    if state is not None:
        state, plan = state(root)
        with open(os.path.join(state_dir, "state.json"), "w") as handle:
            json.dump(state, handle)
    env = {k: v for k, v in os.environ.items() if not k.startswith("PLANCHETTE_")}
    env.update(PLANCHETTE_STATE_DIR=state_dir, GHOSTTY_RESOURCES_DIR=RESOURCES, ZDOTDIR=zdot)
    guard, files = FocusGuard(), UserFilesGuard()
    seed_window_frame()
    # No saved window state: a run that was killed leaves one behind, and the next launch of the same
    # bundle then comes up with no window at all.
    app = subprocess.Popen([binary, "-ApplePersistenceIgnoreState", "YES", *args], env=env, stdout=open(os.path.join(root, "app.log"), "w"),
                           stderr=subprocess.STDOUT, cwd="/")
    guard.start(app.pid)
    result = None
    try:
        time.sleep(wait)
        drive(state_dir, plan)
        proc = system_events_process(app.pid)
        if menu:
            script = (f'tell application "System Events" to tell {proc} to click menu item "{menu[1]}" '
                      f'of menu 1 of menu bar item "{menu[0]}" of menu bar 1')
            subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
            time.sleep(2.5)
        found = windows(app.pid)
        if found:
            main = max(found, key=lambda w: w["w"] * w["h"])
            others = [w for w in found if w is not main and w["w"] > 200]
            if pick == "main":
                chosen = main
            elif pick == "other":
                chosen = max(others, key=lambda w: w["w"] * w["h"]) if others else None
            else:
                chosen = next((w for w in found if w["name"] == pick.split(":", 1)[1]), None)
            if chosen:
                path = os.path.join(out_dir, f"{name}.png")
                if capture(chosen["id"], path):
                    finish(path, scale if chosen is main else None)
                    result = path
        files.report(name)
    finally:
        guard.stop()
        app.send_signal(signal.SIGKILL)
        try:
            app.wait(timeout=10)
        except subprocess.TimeoutExpired:
            pass
        try:
            os.unlink(f"/tmp/planchette-{app.pid}.sock")
        except OSError:
            pass
        subprocess.run(["pkill", "-f", f"{root}/"], capture_output=True)
        shutil.rmtree(root, ignore_errors=True)
    return result


BIG = dict(args=("-inboxShown", "YES"))

SCENES = {
    # Mostly projects of one terminal, as most workspaces are: the README shows the merged rows.
    "overview": dict(state=lambda root: demo_state(root, selected="storefront", active=0,
                                                   projects=SINGLE_PROJECTS), **BIG),
    "folder": dict(state=lambda root: demo_state(root, selected="storefront", active=0, folder_page=True), **BIG),
    "cluster": dict(state=lambda root: demo_state(root, selected="storefront", active=0, view="cluster"), **BIG),
    "search": dict(state=lambda root: demo_state(root, selected="storefront", active=0),
                   menu=("Session", "Quick switcher"), **BIG),
    "welcome": dict(state=None),
    "settings": dict(state=lambda root: demo_state(root), args=("-settingsTab", "tabs"),
                     menu=("Planchette", "Settings…"), pick="title:Tabs"),
    "update": dict(state=lambda root: demo_state(root, autoUpdateCheck=True), wait=14, pick="other"),
    "compact": dict(state=lambda root: demo_state(root, selected="storefront-api", projects=SINGLE_PROJECTS),
                    args=("-inboxShown", "NO")),
    "settings-panel": dict(state=lambda root: demo_state(root),
                           args=("-settingsTab", "projectPanel", "-projectPanelPage", "terminals"),
                           menu=("Planchette", "Settings…"), pick="title:Project panel"),
    "settings-layout": dict(state=lambda root: demo_state(root),
                            args=("-settingsTab", "projectPanel", "-projectPanelPage", "projects"),
                            menu=("Planchette", "Settings…"), pick="title:Project panel"),
    "reviews": dict(state=lambda root: reviews_state(root),
                    args=("-inboxShown", "YES", "-inboxMode", "reviews",
                          "-reviewFocus", f"https://github.com/{REVIEW_REPO}/pull/5620")),
    "reviews-picker": dict(state=lambda root: reviews_state(root),
                           args=("-inboxShown", "YES", "-inboxMode", "reviews",
                                 "-reviewFocus", f"https://github.com/{REVIEW_REPO}/pull/5612")),
}


def main():
    args = sys.argv[1:]
    if not args:
        raise SystemExit(__doc__)
    binary = os.path.abspath(args.pop(0))
    out_dir = os.path.join(REPO, "docs", "images")
    if "--out" in args:
        at = args.index("--out")
        out_dir = os.path.abspath(args[at + 1])
        del args[at:at + 2]
    wanted = args or list(SCENES)
    unknown = [name for name in wanted if name not in SCENES]
    if unknown:
        raise SystemExit(f"unknown scene: {', '.join(unknown)} (known: {', '.join(SCENES)})")
    os.makedirs(out_dir, exist_ok=True)
    holder = os.path.realpath(tempfile.mkdtemp(prefix="plt-shots-app-"))
    try:
        exe = make_app(binary, holder)
        for name in wanted:
            path = run_scene(exe, name, out_dir, **SCENES[name])
            size = f"{os.path.getsize(path) // 1024} KB" if path else "no picture"
            print(f"{name}: {path or '-'} ({size})", flush=True)
    finally:
        shutil.rmtree(holder, ignore_errors=True)
        forget_wrapper()


if __name__ == "__main__":
    main()
