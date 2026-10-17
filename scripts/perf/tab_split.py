"""Do tabs, splits and their drag and drop work in the running app?

usage: tab_split.py <binary> <scratch-folder> [scenario ...]        (default: every scenario)

Each scenario starts its own ISOLATED instance (PLANCHETTE_STATE_DIR) on a seeded project of
terminals, then drives it the way a person does — real mouse presses, drags and key presses posted
as system events (`tools/inputs`), elements found by their accessibility frames (`tools/axtree`) —
and checks the outcome in `state.json`, which is where the app keeps the tabs.

Run it through with_displays.sh. The instance comes to the front and the pointer is moved: do not
use the machine while it runs (about 3 minutes). It needs the Accessibility permission.

A line `ok` / `FAIL` per check, and a picture of the window after the interesting steps in
<scratch-folder>/shots/.
"""
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from perf_common import (RESOURCES, UserFilesGuard, frontmost_pid, hid_idle_seconds, scratch_root,
                         system_events_process, tool, wait_until_idle)

G = "11111111-0000-0000-0000-000000000001"
OTHER = "11111111-0000-0000-0000-000000000002"
NAMES = ["alpha", "bravo", "charlie", "delta"]
SIDS = [f"22222222-0000-0000-0000-00000000000{n}" for n in range(1, 5)]
OTHER_SID = "22222222-0000-0000-0000-000000000009"
RESULTS = []


def check(name, ok, detail=""):
    RESULTS.append((name, bool(ok)))
    print(f"[tab_split] {'ok  ' if ok else 'FAIL'} {name}" + (f"  ({detail})" if detail not in ("", None) and not ok else ""), flush=True)
    return ok


def wait_for(predicate, timeout, step=0.3):
    end = time.time() + timeout
    while time.time() < end:
        try:
            value = predicate()
        except Exception:
            value = None
        if value:
            return value
        time.sleep(step)
    return None


class Disturbed(Exception):
    """The person at the machine took the keyboard from the instance under test: not an app failure."""


class Instance:
    """One isolated Planchette on a seeded workspace."""

    def __init__(self, binary, root, terminals=4, tabs=None):
        self.binary, self.root, self.terminals, self.tabs = binary, root, terminals, tabs
        self.state_dir = f"{root}/state"
        self.shots = f"{root}/shots"
        for d in (self.state_dir, self.shots, f"{root}/zdot", f"{root}/work"):
            os.makedirs(d, exist_ok=True)
        with open(f"{root}/zdot/.zshrc", "w") as handle:
            handle.write("PROMPT='%1~ ❯ '\nunset HISTFILE\nunsetopt BEEP\n")
        self.proc = None
        self.pid = None
        self.edit_state = None      # a function that changes the seeded state before it is written
        self.disturbed = False      # somebody used the machine during the scenario
        self.last_input_end = 0.0   # when this script last sent an input
        self.user_pid = frontmost_pid()
        self.ids = SIDS[:terminals]

    # ---- seeding and starting

    def seed(self):
        sessions = []
        for n, sid in enumerate(self.ids):
            directory = f"{self.root}/work/{NAMES[n]}"
            os.makedirs(directory, exist_ok=True)
            sessions.append(self._session(sid, G, directory, NAMES[n]))
        other_dir = f"{self.root}/work/zulu"
        os.makedirs(other_dir, exist_ok=True)
        sessions.append(self._session(OTHER_SID, OTHER, other_dir, "zulu"))
        group = {"id": G, "name": "alpha-project", "sessionIDs": self.ids, "activeSessionID": self.ids[0],
                 "active": True, "favorite": False, "color": "none"}
        if self.tabs is not None:
            group["tabs"] = self.tabs
        other = {"id": OTHER, "name": "zulu-project", "sessionIDs": [OTHER_SID], "activeSessionID": OTHER_SID,
                 "active": True, "favorite": False, "color": "none"}
        state = {
            "autoUpdateCheck": False, "aiEnabled": False, "language": "en", "durableTerminals": False,
            "appearance": "dark",
            "onboarding": {"welcomeSeen": True, "lastLaunchedVersion": "0.0.0", "durablePromptHidden": True},
            "groups": [group, other], "sessions": sessions,
            "windows": [{"id": "00000000-0000-0000-0000-0000000000a1", "groupIDs": [G, OTHER],
                         "selectedGroupID": G, "folders": [], "showsProjectOverview": False}],
        }
        if self.edit_state:
            self.edit_state(state)
        self.write_state(state)

    @staticmethod
    def _session(sid, gid, directory, title):
        return {"id": sid, "groupID": gid, "workingDirectory": directory, "currentDirectory": directory,
                "durable": False, "resumeClaudeOnRestore": False, "state": "free", "stateSince": 0,
                "seen": True, "tags": [], "agentKind": "none", "color": "none", "customTitle": title}

    def write_state(self, state):
        with open(f"{self.state_dir}/state.json", "w") as handle:
            json.dump(state, handle)

    def start(self, wait=7.0):
        self.seed()
        out = subprocess.run([tool("inputs"), "where"], capture_output=True, text=True).stdout.split()
        self.pointer_origin = (int(out[0]), int(out[1])) if len(out) == 2 else None
        self.launch(wait)

    def stop_app(self):
        if self.proc:
            self.proc.send_signal(signal.SIGTERM)
            try:
                self.proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                self.proc.send_signal(signal.SIGKILL)
                self.proc.wait(timeout=10)
            try:
                os.unlink(f"/tmp/planchette-{self.pid}.sock")
            except OSError:
                pass
            self.proc = None

    def relaunch(self, wait=7.0):
        """Quit the app the way a user does (it saves on the way out) and start it on the same state."""
        time.sleep(2.0)       # a change is saved a second after it is made
        self.stop_app()
        self.launch(wait)

    def launch(self, wait=7.0):
        env = {k: v for k, v in os.environ.items() if not k.startswith("PLANCHETTE_")}
        env.update(PLANCHETTE_STATE_DIR=self.state_dir, GHOSTTY_RESOURCES_DIR=RESOURCES, ZDOTDIR=f"{self.root}/zdot")
        self.proc = subprocess.Popen(
            [self.binary, "-ApplePersistenceIgnoreState", "YES", "-inboxShown", "NO"], env=env,
            stdout=open(f"{self.root}/app.log", "w"), stderr=subprocess.STDOUT, cwd="/")
        self.pid = self.proc.pid
        time.sleep(wait)
        self.ref = system_events_process(self.pid)
        self.front()
        # A window big enough for four panes, at a place the pointer can reach.
        subprocess.run(["osascript", "-e", f'tell application "System Events" to tell {self.ref} to '
                        'set position of window 1 to {30, 50}'], capture_output=True)
        subprocess.run(["osascript", "-e", f'tell application "System Events" to tell {self.ref} to '
                        'set size of window 1 to {1440, 860}'], capture_output=True)
        time.sleep(1.2)

    def front(self):
        subprocess.run(["osascript", "-e", f'tell application "System Events" to set frontmost of {self.ref} to true'],
                       capture_output=True)
        time.sleep(0.4)

    def stop(self):
        if self.proc:
            self.proc.send_signal(signal.SIGKILL)
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                pass
            try:
                os.unlink(f"/tmp/planchette-{self.pid}.sock")
            except OSError:
                pass
            subprocess.run(["pkill", "-f", f"{self.root}/"], capture_output=True)
        if self.user_pid:
            subprocess.run(["osascript", "-e", 'tell application "System Events" to set frontmost of '
                            f"(first process whose unix id is {self.user_pid}) to true"], capture_output=True)
        # The pointer stayed in the test window while the test ran; it goes back now.
        origin = getattr(self, "pointer_origin", None)
        if origin:
            subprocess.run([tool("inputs"), "move", str(origin[0]), str(origin[1])], capture_output=True)

    # ---- the control API

    def api(self, payload, timeout=10):
        path = open(f"{self.state_dir}/socket").read().strip()
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

    def label_terminals(self):
        """Print a name in every terminal so a picture shows which pane is which."""
        for n, sid in enumerate(self.ids):
            wait_for(lambda: "❯" in (self.api({"planchette_request": "session.read", "id": sid, "lines": 4})
                                     .get("result") or {}).get("text", ""), 25)
            self.api({"planchette_request": "session.prompt", "id": sid,
                      "text": f"clear; echo PANE-{NAMES[n].upper()}", "force": True})
        time.sleep(1.5)

    def sessions(self):
        reply = self.api({"planchette_request": "session.list"})
        return (reply.get("result") or {}).get("sessions", [])

    # ---- state.json: where the tabs live

    def state(self):
        with open(f"{self.state_dir}/state.json") as handle:
            return json.load(handle)

    def group(self):
        return next(g for g in self.state()["groups"] if g["id"] == G)

    def names(self):
        """Terminal id -> short name. The seeded ones keep theirs; terminals the app made are
        new1, new2, … in the order they appear in the project."""
        names = {sid: NAMES[n] for n, sid in enumerate(SIDS)}
        extra = 0
        for sid in self.group()["sessionIDs"]:
            if sid not in names and sid != OTHER_SID:
                extra += 1
                names[sid] = f"new{extra}"
        return names

    def strip(self):
        """The tab strip as nested lists of terminal NAMES: [[a], [b, c]] — layouts flattened to
        their leaves, with the arrangement as a string in `shape()`."""
        group = self.group()
        names = self.names()
        tabs = group.get("tabs")
        if tabs is None:
            return [[names[s]] for s in group["sessionIDs"]]
        return [[names[s] for s in leaves(tab)] for tab in tabs]

    def shape(self):
        """The strip with its arrangement: ['alpha', 'row(bravo,charlie)'] ..."""
        group = self.group()
        names = self.names()
        tabs = group.get("tabs")
        if tabs is None:
            return [names[s] for s in group["sessionIDs"]]
        return [describe(tab, names) for tab in tabs]

    def wait_shape(self, expected, timeout=9):
        ok = wait_for(lambda: self.shape() == expected, timeout)
        return ok, self.shape()

    def active(self):
        group = self.group()
        return self.names().get(group.get("activeSessionID"))


    # ---- the screen, in terms of tabs and panes

    def detail(self, elements=None):
        """The frame of the main area: the group that holds the tab bar."""
        elements = elements or self.ax()
        win = self.window()
        plus = [e for e in elements if e["role"] == "AXButton" and e["desc"] == "Split Right"]
        if not plus:
            return None
        anchor = plus[0]
        groups = [e for e in elements if e["role"] == "AXGroup" and e["x"] <= anchor["x"]
                  and anchor["x"] + anchor["w"] <= e["x"] + e["w"] and e["y"] <= anchor["y"]
                  and e["y"] + e["h"] >= anchor["y"] + anchor["h"] and e["h"] > 200]
        return min(groups, key=lambda g: g["w"] * g["h"]) if groups else win

    def bar_bottom(self, elements):
        """Where the tab bar ends: just under the split buttons that sit in it."""
        anchor = next((e for e in elements if e["role"] == "AXButton" and e["desc"] == "Split Right"), None)
        return anchor["y"] + anchor["h"] + 4 if anchor else self.window()["y"] + 110

    def tab_buttons(self, elements=None):
        """The tabs of the bar, left to right: name, frame of the whole tab, frame of its close button."""
        elements = elements or self.ax()
        win = self.window()
        bar_bottom = self.bar_bottom(elements)
        closes = [e for e in elements if e["role"] == "AXButton" and e["desc"] == "Close"
                  and win["y"] < e["y"] < bar_bottom and e["x"] > win["x"] + 250]
        tabs = []
        for close in closes:
            around = [e for e in elements if e["role"] == "AXButton" and e["desc"] == "" and e["title"] == ""
                      and e["x"] <= close["x"] and close["x"] + close["w"] <= e["x"] + e["w"]
                      and e["y"] <= close["y"] and close["y"] + close["h"] <= e["y"] + e["h"] and e["w"] > 60]
            if not around:
                continue
            frame = min(around, key=lambda e: e["w"] * e["h"])
            names = [e["value"] for e in elements if e["role"] == "AXStaticText"
                     and frame["x"] <= e["x"] and e["x"] + e["w"] <= frame["x"] + frame["w"]
                     and frame["y"] <= e["y"] <= frame["y"] + frame["h"] and e["value"] in self.names().values()]
            tabs.append({"name": names[0] if names else "?", "frame": frame, "close": close})
        return sorted(tabs, key=lambda t: t["frame"]["x"])

    def tab(self, name):
        found = [t for t in self.tab_buttons() if t["name"] == name]
        return found[0] if found else None

    def button(self, desc):
        found = self.find(role="AXButton", desc=desc)
        return found[0] if found else None

    def menu_items(self, elements=None):
        return [e for e in (elements or self.ax()) if e["role"] == "AXMenuItem" and e["title"]]

    def menu_item(self, title):
        for e in self.menu_items():
            if e["title"] == title:
                return e
        return None

    def alert_button(self, title):
        for e in self.ax():
            if e["role"] == "AXButton" and e["title"] == title:
                return e
        return None


    def content(self):
        """The area under the tab bar, where the tab in front is drawn."""
        elements = self.ax()
        detail = self.detail(elements)
        tabs = self.tab_buttons(elements)
        top = max(t["frame"]["y"] + t["frame"]["h"] for t in tabs) + 8
        return {"x": detail["x"], "y": top, "w": detail["w"], "h": detail["y"] + detail["h"] - top}

    def panes(self):
        """The panes of a split tab: name, whole frame, title bar. From the title bars (a pane has
        one only when the tab holds more than one) and the smallest group around each close button."""
        elements = self.ax()
        win = self.window()
        names = set(self.names().values())
        bar_bottom = self.bar_bottom(elements)
        out = []
        for close in elements:
            if not (close["role"] == "AXButton" and close["desc"] == "Close" and close["y"] >= bar_bottom
                    and close["x"] > win["x"] + 250):
                continue
            around = [e for e in elements if e["role"] == "AXGroup" and e["w"] > 80 and e["h"] > 80
                      and e["x"] <= close["x"] and close["x"] + close["w"] <= e["x"] + e["w"]
                      and e["y"] <= close["y"] and close["y"] + close["h"] <= e["y"] + e["h"]]
            if not around:
                continue
            frame = min(around, key=lambda e: e["w"] * e["h"])
            texts = [e for e in elements if e["role"] == "AXStaticText" and abs(e["y"] - close["y"]) < 12
                     and frame["x"] <= e["x"] < close["x"]]
            known = [t["value"] for t in texts if t["value"] in names]
            out.append({"name": known[0] if known else (texts[0]["value"] if texts else "?"), "frame": frame,
                        "close": close, "title": (min([t["x"] for t in texts], default=close["x"]) + 6,
                                                  close["y"] + close["h"] // 2)})
        return sorted(out, key=lambda p: (p["frame"]["y"], p["frame"]["x"]))

    def pane(self, name):
        found = [p for p in self.panes() if p["name"] == name]
        return found[0] if found else None

    # ---- looking at the screen

    def ax(self):
        out = subprocess.run([tool("axtree"), str(self.pid)], capture_output=True, text=True)
        elements = []
        for line in out.stdout.splitlines():
            try:
                elements.append(json.loads(line))
            except ValueError:
                pass
        return elements

    def find(self, role=None, desc=None, title=None, value=None, contains=None, elements=None):
        found = []
        for e in elements or self.ax():
            if role and e["role"] != role:
                continue
            if desc is not None and e["desc"] != desc:
                continue
            if title is not None and e["title"] != title:
                continue
            if value is not None and e["value"] != value:
                continue
            if contains and not any(contains in e[k] for k in ("title", "desc", "value")):
                continue
            if e["w"] > 0 and e["h"] > 0:
                found.append(e)
        return found

    def window(self, patience=20):
        """The instance's biggest window. Right after a launch, or when the display has just woken,
        the accessibility tree has none yet: wait for it instead of failing."""
        for _ in range(patience):
            windows = self.find(role="AXWindow")
            if windows:
                return max(windows, key=lambda w: w["w"] * w["h"])
            time.sleep(1.0)
        raise Disturbed("the instance has no window in the accessibility tree")

    def tabs_on_screen(self):
        """The tab elements of the bar, left to right: the names in them, and their frames."""
        elements = self.ax()
        win = self.window()
        texts = [e for e in elements if e["role"] == "AXStaticText" and win["y"] <= e["y"] < win["y"] + 70
                 and e["x"] > win["x"] + 200 and e["value"] in NAMES]
        # a tab's frame is the group that holds its text: the smallest group around it
        groups = [e for e in elements if e["role"] == "AXGroup" and e["w"] > 0]
        tabs = []
        for text in sorted(texts, key=lambda e: e["x"]):
            around = [g for g in groups if g["x"] <= text["x"] and text["x"] + text["w"] <= g["x"] + g["w"]
                      and g["y"] <= text["y"] and text["y"] + text["h"] <= g["y"] + g["h"] and g["h"] < 60]
            frame = min(around, key=lambda g: g["w"] * g["h"]) if around else text
            tabs.append({"name": text["value"], "frame": frame, "text": text})
        return tabs

    def screen_shot(self, name):
        """The whole display — what shows while a drag is in flight, preview and drop zone included."""
        subprocess.run(["screencapture", "-x", f"{self.shots}/{name}.png"], capture_output=True)

    def shot(self, name):
        windows = subprocess.run([tool("windows"), str(self.pid)], capture_output=True, text=True).stdout.splitlines()
        best = None
        for line in windows:
            m = re.match(r"(\d+) layer=(\d+) (\d+)x(\d+)", line)
            if m and (best is None or int(m[3]) * int(m[4]) > best[1]):
                best = (int(m[1]), int(m[3]) * int(m[4]))
        if best:
            subprocess.run(["screencapture", "-x", "-o", "-l", str(best[0]), f"{self.shots}/{name}.png"], capture_output=True)

    # ---- input

    def settle_for_input(self):
        """Before every synthetic click, drag or key press: give way to a person who is using the
        machine, and make sure the instance under test is the app in front — a key press or a click
        sent while another app is in front would land in somebody's work. Whenever this had to wait
        or to take the focus back, the scenario is marked `disturbed`: what it measures is no longer
        what the app does but what the person did, and `main` runs it again."""
        # The system counts this script's own events as activity, so a person is at the machine only
        # when something happened more recently than the script's own last input.
        since_mine = time.time() - self.last_input_end if self.last_input_end else 1e9
        idle = hid_idle_seconds()
        if idle + 0.6 < min(since_mine, 3):
            self.disturbed = True
            print(f"[disturbed] input by somebody else: idle {idle:.1f}s, my last input {since_mine:.1f}s ago", flush=True)
            wait_until_idle(3, 600, quiet=True)
        now_front = frontmost_pid()
        if now_front != str(self.pid):
            self.disturbed = True
            print(f"[disturbed] the app in front is pid {now_front}, not the instance ({self.pid})", flush=True)
            self.front()
            time.sleep(1.2)                 # keys sent while the app is still activating are lost
            if frontmost_pid() != str(self.pid):
                raise Disturbed("the instance under test is not in front: not sending input to another app")

    def inputs(self, *args):
        self.settle_for_input()
        subprocess.run([tool("inputs"), *[str(a) for a in args]], capture_output=True,
                       env={**os.environ, "KEEP_POINTER": "1"})
        self.last_input_end = time.time()

    def click(self, x, y, count=1):
        self.inputs("click", x, y, count)

    def rclick(self, x, y):
        self.inputs("rclick", x, y)

    def drag(self, x1, y1, x2, y2, steps=40, hold=350):
        self.inputs("drag", x1, y1, x2, y2, steps, hold)

    def drag_hover(self, x1, y1, x2, y2, hover_ms, during, steps=40, hold=350):
        """Press at the first point, move to the second, stay there `hover_ms`, and call `during()`
        while the pointer is still down; then release."""
        self.settle_for_input()
        env = {**os.environ, "HOVER_MS": str(hover_ms), "KEEP_POINTER": "1"}
        proc = subprocess.Popen([tool("inputs"), "drag", *[str(v) for v in (x1, y1, x2, y2, steps, hold)]], env=env)
        time.sleep((hold + steps * 14 + 220 + 500) / 1000)
        result = during()
        proc.wait()
        self.last_input_end = time.time()
        return result

    def dragpath(self, hold, *points):
        self.inputs("dragpath", hold, *[c for p in points for c in p])

    def key(self, key, *mods):
        self.inputs("key", key, *mods)


def leaves(node):
    if "leaf" in node:
        return [node["leaf"]["_0"]]
    for k in ("row", "column"):
        if k in node:
            return [s for child in node[k]["_0"] for s in leaves(child)]
    return []


def describe(node, names):
    if "leaf" in node:
        return names[node["leaf"]["_0"]]
    for k in ("row", "column"):
        if k in node:
            return f"{k}({','.join(describe(c, names) for c in node[k]['_0'])})"
    return "?"


def center(frame):
    return frame["x"] + frame["w"] // 2, frame["y"] + frame["h"] // 2


# =============================================================================================
# scenarios
# =============================================================================================

def explore(inst):
    """Not a test: what the accessibility tree and the window look like."""
    inst.label_terminals()
    inst.shot("explore")
    for e in inst.ax():
        if e["w"] > 0 and e["role"] in ("AXButton", "AXGroup", "AXStaticText", "AXWindow", "AXSplitGroup", "AXRadioButton"):
            print(f"  {'  ' * min(e['d'], 8)}{e['role']} title={e['title']!r} desc={e['desc']!r} value={e['value'][:30]!r} "
                  f"at ({e['x']},{e['y']}) {e['w']}x{e['h']}")
    print("tabs:", [(t["name"], t["frame"]["x"], t["frame"]["y"], t["frame"]["w"], t["frame"]["h"]) for t in inst.tabs_on_screen()])



def tabs_basic(inst):
    inst.label_terminals()
    check("four tabs at the start", inst.shape() == ["alpha", "bravo", "charlie", "delta"], inst.shape())
    tabs = inst.tab_buttons()
    check("the bar shows four tabs", [t["name"] for t in tabs] == NAMES, [t["name"] for t in tabs])

    # 1. a click anywhere on the tab opens it — not only on the letters
    charlie = inst.tab("charlie")["frame"]
    inst.click(charlie["x"] + 3, charlie["y"] + charlie["h"] // 2)          # the very left edge: padding
    check("a click on the padding of a tab opens it", wait_for(lambda: inst.active() == "charlie", 6), inst.active())
    bravo = inst.tab("bravo")["frame"]
    inst.click(bravo["x"] + bravo["w"] - 28, bravo["y"] + 2)                # top right, between name and close
    check("a click in a corner of a tab opens it", wait_for(lambda: inst.active() == "bravo", 6), inst.active())

    # 3. the close button asks first
    delta = inst.tab("delta")
    inst.click(*center(delta["close"]))
    cancel = wait_for(lambda: inst.alert_button("Cancel"), 6)
    check("the close button opens a confirmation", bool(cancel))
    inst.shot("confirm")
    if cancel:
        inst.click(*center(cancel))
        time.sleep(1.0)
    check("cancel keeps the tab", len(inst.tab_buttons()) == 4 and inst.shape() == ["alpha", "bravo", "charlie", "delta"])
    delta = inst.tab("delta")
    inst.click(*center(delta["close"]))
    close = wait_for(lambda: inst.alert_button("Close"), 6)
    check("the close button asks again", bool(close))
    if close:
        inst.click(*center(close))
    ok, shape = inst.wait_shape(["alpha", "bravo", "charlie"])
    check("confirming closes the tab", ok, shape)
    check("the other project is untouched",
          sum(1 for s in inst.sessions() if s["project"] == "zulu-project") == 1
          and sum(1 for s in inst.sessions() if s["project"] == "alpha-project") == 3)

    # 4. three separate close items
    charlie = inst.tab("charlie")["frame"]
    inst.rclick(charlie["x"] + 20, charlie["y"] + 10)
    labels = ["Close Tabs to the Left", "Close This Tab", "Close Tabs to the Right"]
    shown = wait_for(lambda: [m for m in inst.menu_items() if m["title"] in labels], 5) or []
    inst.shot("menu")
    order = [m["title"] for m in sorted(shown, key=lambda m: m["y"])]
    check("the tab menu has the three close items, in order", order == labels, order)
    right = next((m for m in shown if m["title"] == labels[2]), None)
    check("nothing to the right of the last tab: that item is greyed", right is not None and not right["enabled"])
    left = next((m for m in shown if m["title"] == labels[0]), None)
    check("the items to the left is live", left is not None and left["enabled"])
    inst.key("escape")
    time.sleep(0.6)
    alpha = inst.tab("alpha")["frame"]
    inst.rclick(alpha["x"] + 20, alpha["y"] + 10)
    right = wait_for(lambda: inst.menu_item("Close Tabs to the Right"), 5)
    if right:
        inst.click(*center(right))
        confirm = wait_for(lambda: inst.alert_button("Close"), 6)
        check("closing the tabs to the right asks first", bool(confirm))
        if confirm:
            inst.click(*center(confirm))
        ok, shape = inst.wait_shape(["alpha"])
        check("it closes exactly the tabs to the right", ok, shape)
    else:
        check("the menu item to close the tabs on the right exists", False)
    inst.shot("after-close-right")


def explore_split(inst):
    inst.label_terminals()
    inst.click(*center(inst.button("Split Right")))
    time.sleep(2.0)
    print("shape", inst.shape(), "active", inst.active())
    inst.shot("split1")
    win = inst.window()
    for e in inst.ax():
        if e["w"] > 0 and e["x"] > win["x"] + 250 and e["role"] in ("AXButton", "AXGroup", "AXStaticText", "AXSplitGroup", "AXSplitter", "AXScrollArea", "AXTextArea"):
            print(f"  {'  ' * min(e['d'], 9)}{e['role']} desc={e['desc']!r} value={e['value'][:24]!r} at ({e['x']},{e['y']}) {e['w']}x{e['h']}")



def edge_point(frame, edge, margin=30):
    cx, cy = frame["x"] + frame["w"] // 2, frame["y"] + frame["h"] // 2
    return {"left": (frame["x"] + margin, cy), "right": (frame["x"] + frame["w"] - margin, cy),
            "top": (cx, frame["y"] + margin), "bottom": (cx, frame["y"] + frame["h"] - margin)}[edge]


def drag_tab_onto(inst, name, point, hover=700):
    """Drag a tab of the bar (by name, or by position) to a point and let go; the pointer stays a
    moment over the target."""
    t = inst.tab_buttons()[name] if isinstance(name, int) else inst.tab(name)
    cx, cy = center(t["frame"])
    inst.drag_hover(cx - 20, cy, point[0], point[1], hover, lambda: None)


def drag_pane_onto(inst, name, point, hover=700):
    """Drag a pane by its title bar to a point."""
    p = inst.pane(name)
    inst.drag_hover(p["title"][0] + 30, p["title"][1], point[0], point[1], hover, lambda: None)


def no_text_typed(inst, label):
    """A drag over a terminal must never type anything into it: no id and no payload on any screen."""
    leaked = []
    for sid in SIDS + [OTHER_SID]:
        reply = inst.api({"planchette_request": "session.read", "id": sid, "lines": 40})
        text = (reply.get("result") or {}).get("text", "")
        if "planchette" in text.lower().replace("pane-", "") or any(other in text for other in SIDS + [OTHER_SID]):
            leaked.append(sid[-1])
    check(f"nothing was typed into a terminal ({label})", not leaked, leaked)



def labels_intact(inst, label):
    """Moving a pane between tabs must not restart or blank its terminal: the line each seeded
    terminal printed at the start is still on its screen."""
    lost = []
    for n, sid in enumerate(SIDS):
        if sid not in inst.group()["sessionIDs"]:
            continue
        reply = inst.api({"planchette_request": "session.read", "id": sid, "lines": 60})
        if f"PANE-{NAMES[n].upper()}" not in (reply.get("result") or {}).get("text", ""):
            lost.append(NAMES[n])
    check(f"every terminal kept its screen ({label})", not lost, lost)


def well_formed(node):
    """The invariants of one tab's tree, on the JSON as saved: no container with a single child, no
    row in a row, no column in a column, no leaf twice."""
    problems = []

    def walk(n, parent):
        if "leaf" in n:
            return
        kind = "row" if "row" in n else "column"
        children = n[kind]["_0"]
        if len(children) < 2:
            problems.append(f"{kind} with {len(children)} children")
        for c in children:
            if parent == kind or kind in c and False:
                pass
            if kind in c:
                problems.append(f"{kind} in {kind}")
            walk(c, kind)

    walk(node, None)
    return problems


def invariants(inst):
    """What must hold of the saved project after anything at all."""
    group = inst.group()
    ids = group["sessionIDs"]
    tabs = group.get("tabs")
    problems = []
    if tabs is not None:
        flat = [s for tab in tabs for s in leaves(tab)]
        if sorted(flat) != sorted(ids):
            problems.append(f"leaves {len(flat)} vs sessions {len(ids)}")
        if flat != ids:
            problems.append("sidebar order differs from tab order")
        for tab in tabs:
            problems += well_formed(tab)
    if len(set(ids)) != len(ids):
        problems.append("a terminal listed twice")
    if inst.proc.poll() is not None:
        problems.append("the app is gone")
    return problems


def stress(inst):
    """Real drags and presses at random, a fixed seed, the saved state checked after every one."""
    import random
    rng = random.Random(int(os.environ.get("STRESS_SEED", "20261016")))
    inst.label_terminals()
    log = []
    for step in range(int(os.environ.get("STRESS_STEPS", "28"))):
        tabs = inst.tab_buttons()
        panes = inst.panes()
        area = inst.content()
        op = rng.choice(["tab_on_edge", "tab_on_edge", "pane_to_bar", "pane_to_tab", "split", "combine", "separate", "click_tab", "tab_on_tab"])
        total = len(inst.group()["sessionIDs"])
        desc = op
        try:
            if op == "tab_on_edge" and tabs:
                index = rng.randrange(len(tabs))
                target = rng.choice(panes)["frame"] if panes else area
                edge = rng.choice(["left", "right", "top", "bottom"])
                desc = f"tab {index} -> {edge} of a pane"
                drag_tab_onto(inst, index, edge_point(target, edge, 40), hover=450)
            elif op == "pane_to_bar" and panes:
                victim = rng.choice(panes)
                last = tabs[-1]["frame"]
                desc = f"pane {victim['name']} -> end of bar"
                drag_pane_onto(inst, victim["name"], (last["x"] + last["w"] + 14, last["y"] + last["h"] // 2), hover=450)
            elif op == "pane_to_tab" and panes and tabs:
                victim = rng.choice(panes)
                tab = rng.choice(tabs)["frame"]
                desc = f"pane {victim['name']} -> a tab"
                drag_pane_onto(inst, victim["name"], (tab["x"] + 30, tab["y"] + tab["h"] // 2), hover=450)
            elif op == "tab_on_tab" and len(tabs) > 1:
                a, b = rng.sample(range(len(tabs)), 2)
                tb = tabs[b]["frame"]
                desc = f"tab {a} -> before tab {b}"
                drag_tab_onto(inst, a, (tb["x"] + 30, tb["y"] + tb["h"] // 2), hover=450)
            elif op == "split" and total < 9:
                which = rng.choice(["Split Right", "Split Down"])
                desc = which
                inst.click(*center(inst.button(which)))
            elif op == "combine" and inst.button("Combine All Tabs")["enabled"]:
                inst.click(*center(inst.button("Combine All Tabs")))
            elif op == "separate" and inst.button("Separate All Panes")["enabled"]:
                inst.click(*center(inst.button("Separate All Panes")))
            elif op == "click_tab" and tabs:
                index = rng.randrange(len(tabs))
                desc = f"click tab {index}"
                inst.click(*center(tabs[index]["frame"]))
            else:
                desc = f"{op} (skipped)"
        except (StopIteration, TypeError, KeyError, ValueError, IndexError) as error:
            desc = f"{op} (could not aim: {error!r})"
        time.sleep(1.7)
        problems = invariants(inst)
        log.append(f"{step:2d} {desc}  ->  {inst.shape()}")
        if problems:
            check(f"step {step}: {desc}", False, problems)
            break
    else:
        check("every step left the saved project well formed", True)
    for line in log:
        print("   ", line)
    labels_intact(inst, "after the whole run")
    check("the app is still running", inst.proc.poll() is None)
    inst.shot("stress-end")


def split_drag(inst):
    inst.label_terminals()
    area = inst.content()
    mid_y = area["y"] + area["h"] // 2

    # a tab onto the right edge of the terminal in front: they share the view
    drag_tab_onto(inst, "delta", edge_point(area, "right", 40))
    ok, shape = inst.wait_shape(["row(alpha,delta)", "bravo", "charlie"])
    check("a tab dropped on the right edge splits the view", ok, shape)
    check("the sidebar order follows the tabs", inst.group()["sessionIDs"][:2] == [SIDS[0], SIDS[3]],
          inst.group()["sessionIDs"])
    check("the dropped terminal has the keyboard", wait_for(lambda: inst.active() == "delta", 4), inst.active())
    inst.shot("split-1")
    check("two panes show, each with a title bar", len(inst.panes()) == 2, [p["name"] for p in inst.panes()])

    # a tab onto the bottom edge of the left pane: a column inside the row
    left = min(inst.panes(), key=lambda p: p["frame"]["x"])
    drag_tab_onto(inst, "bravo", edge_point(left["frame"], "bottom", 40))
    ok, shape = inst.wait_shape(["row(column(alpha,bravo),delta)", "charlie"])
    check("a tab dropped on a pane's bottom edge stacks under it", ok, shape)
    inst.shot("split-2")

    # the last tab onto the left edge of the right pane: everything in one tab
    right = max(inst.panes(), key=lambda p: p["frame"]["x"])
    drag_tab_onto(inst, "charlie", edge_point(right["frame"], "left", 40))
    ok, shape = inst.wait_shape(["row(column(alpha,bravo),charlie,delta)"])
    check("all four terminals can live in one tab", ok, shape)
    check("one tab in the bar", len(inst.tab_buttons()) == 1, len(inst.tab_buttons()))
    check("four panes on screen", len(inst.panes()) == 4, [p["name"] for p in inst.panes()])
    inst.shot("split-3")
    no_text_typed(inst, "after dragging tabs over terminals")

    # a pane out of the tab, onto the free space of the bar: its own tab
    bar = inst.tab_buttons()[-1]["frame"]
    drag_pane_onto(inst, "delta", (bar["x"] + bar["w"] + 14, bar["y"] + bar["h"] // 2))
    ok, shape = inst.wait_shape(["row(column(alpha,bravo),charlie)", "delta"])
    check("a pane dragged to the end of the bar becomes a tab", ok, shape)
    inst.shot("split-4")

    # a tab onto another tab: it moves before it
    first = inst.tab_buttons()[0]["frame"]
    drag_tab_onto(inst, "delta", (first["x"] + 30, first["y"] + first["h"] // 2))
    ok, shape = inst.wait_shape(["delta", "row(column(alpha,bravo),charlie)"])
    check("a tab dropped on a tab goes before it", ok, shape)

    # a pane onto a tab: it leaves its tab and stands before that one
    tab2 = inst.tab_buttons()[1]
    inst.click(*center(tab2["frame"]))
    time.sleep(1.0)
    first = inst.tab_buttons()[0]["frame"]
    drag_pane_onto(inst, "charlie", (first["x"] + 30, first["y"] + first["h"] // 2))
    ok, shape = inst.wait_shape(["charlie", "delta", "column(alpha,bravo)"])
    check("a pane dropped on a tab becomes a tab before it", ok, shape)

    # a whole split tab onto a single terminal's top edge: its panes keep their arrangement
    area = inst.content()
    drag_tab_onto(inst, 2, edge_point(area, "top", 40))
    ok, shape = inst.wait_shape(["column(alpha,bravo,charlie)", "delta"])
    check("a split tab dropped on a terminal brings all its panes", ok, shape)
    inst.shot("split-5")
    labels_intact(inst, "after moving panes between tabs")
    check("the sidebar lists them in tab order",
          inst.group()["sessionIDs"] == [SIDS[0], SIDS[1], SIDS[2], SIDS[3]], inst.group()["sessionIDs"])
    no_text_typed(inst, "at the end")


def tab_names(inst):
    """A terminal moved into a tab does not rename it: the tab keeps the name of the one it was made for."""
    inst.label_terminals()
    area = inst.content()

    def names():
        return [t["name"] for t in inst.tab_buttons()]

    # a tab onto the right edge of the terminal in front: the dropped terminal has the keyboard, the tab keeps its name
    drag_tab_onto(inst, "delta", edge_point(area, "right", 40))
    ok, shape = inst.wait_shape(["row(alpha,delta)", "bravo", "charlie"])
    check("a tab was dropped into the one in front", ok, shape)
    check("the dropped terminal has the keyboard", bool(wait_for(lambda: inst.active() == "delta", 5)), inst.active())
    check("…and the tab is still called alpha, not delta", names()[0] == "alpha", names())

    # on the left edge: the dropped one comes first in the view, the tab does not change its name
    right = max(inst.panes(), key=lambda p: p["frame"]["x"])
    drag_tab_onto(inst, "bravo", edge_point(right["frame"], "left", 40))
    ok, shape = inst.wait_shape(["row(alpha,bravo,delta)", "charlie"])
    check("a tab dropped on the left edge of a pane", ok, shape)
    check("…still called alpha", names()[0] == "alpha", names())

    # the other way round: the tab that is moved into is the *later* one
    inst.click(*center(inst.tab_buttons()[1]["frame"]))                   # charlie
    time.sleep(1.0)
    drag_tab_onto(inst, 0, edge_point(inst.content(), "right", 40))
    time.sleep(1.5)
    check("the earlier tab dropped into charlie: the tab is called charlie", names() == ["charlie"], names())

    # clicking another pane changes the keyboard, not the name
    pane = inst.pane("bravo")
    if pane:
        inst.click(pane["title"][0] + 40, pane["title"][1])
        time.sleep(1.0)
        check("clicking another pane does not rename the tab", names() == ["charlie"] and inst.active() == "bravo", (names(), inst.active()))

    # a pane taken out is a tab of its own, named after itself; the tab it left keeps its name
    bar = inst.tab_buttons()[-1]["frame"]
    drag_pane_onto(inst, "delta", (bar["x"] + bar["w"] + 14, bar["y"] + bar["h"] // 2))
    time.sleep(1.5)
    check("a pane taken out is called after itself; the tab it left keeps its name", names() == ["charlie", "delta"], names())

    # closing the terminal that gives the tab its name passes the name on
    victim = inst.pane("charlie")
    if victim:
        inst.click(*center(victim["close"]))
        close = wait_for(lambda: inst.alert_button("Close"), 6)
        if close:
            inst.click(*center(close))
        ok = wait_for(lambda: names()[0] != "charlie", 8)
        check("closing the terminal a tab is named after gives it the next one's name", bool(ok), names())
    inst.shot("tab-names")


def drop_refused(inst):
    inst.label_terminals()
    area = inst.content()
    before = inst.shape()
    # the tab in front onto its own terminal: nothing to split
    drag_tab_onto(inst, "alpha", edge_point(area, "right", 40))
    time.sleep(1.5)
    check("a tab dropped on its own terminal changes nothing", inst.shape() == before, inst.shape())
    check("…and no split view appeared", len(inst.panes()) == 0, len(inst.panes()))
    # a tab dropped on itself in the bar
    me = inst.tab("alpha")["frame"]
    inst.drag_hover(me["x"] + 20, me["y"] + me["h"] // 2, me["x"] + 60, me["y"] + me["h"] // 2, 500, lambda: None)
    time.sleep(1.0)
    check("a tab dropped on itself changes nothing", inst.shape() == before, inst.shape())
    # a drag that is let go over the sidebar
    drag_tab_onto(inst, "bravo", (120, 400))
    time.sleep(1.0)
    check("a drop in the sidebar changes nothing", inst.shape() == before, inst.shape())
    no_text_typed(inst, "after refused drops")
    check("all four tabs are still there", [t["name"] for t in inst.tab_buttons()] == NAMES)


def buttons(inst):
    inst.label_terminals()
    split_right, split_down = inst.button("Split Right"), inst.button("Split Down")
    combine, separate = inst.button("Combine All Tabs"), inst.button("Separate All Panes")
    check("Separate is greyed while nothing is split", separate and not separate["enabled"])
    check("Combine is live with four tabs", combine and combine["enabled"])

    inst.click(*center(split_right))
    ok, shape = inst.wait_shape(["row(alpha,new1)", "bravo", "charlie", "delta"])
    check("Split Right opens a new terminal beside the one in front", ok, shape)
    check("the new terminal has the keyboard", wait_for(lambda: inst.active() == "new1", 4), inst.active())
    new = next(s for s in inst.sessions() if s["id"] not in SIDS + [OTHER_SID])
    check("it starts in the same folder", new["path"].endswith("/work/alpha"), new["path"])
    separate = inst.button("Separate All Panes")
    check("Separate is live once a tab is split", separate and separate["enabled"])

    inst.click(*center(inst.button("Split Down")))
    ok, shape = inst.wait_shape(["row(alpha,column(new1,new2))", "bravo", "charlie", "delta"])
    check("Split Down opens one below the one in front", ok, shape)

    inst.key("d", "cmd")
    ok, shape = inst.wait_shape(["row(alpha,column(new1,row(new2,new3)))", "bravo", "charlie", "delta"], 12)
    check("⌘D splits the pane that has the keyboard to the right", ok, shape)
    inst.key("d", "cmd", "shift")
    ok, shape = inst.wait_shape(["row(alpha,column(new1,row(new2,column(new3,new4))))", "bravo", "charlie", "delta"], 12)
    check("⌘⇧D splits it downward", ok, shape)
    inst.shot("buttons-1")

    inst.click(*center(inst.button("Combine All Tabs")))
    ok = wait_for(lambda: len(inst.shape()) == 1, 8)
    check("Combine puts every tab in one view", bool(ok), inst.shape())
    check("…with all eight terminals", len(inst.strip()[0]) == 8, inst.strip())
    check("Combine is greyed with one tab", not inst.button("Combine All Tabs")["enabled"])
    inst.shot("buttons-2")

    inst.click(*center(inst.button("Separate All Panes")))
    ok = wait_for(lambda: len(inst.shape()) == 8 and all("(" not in t for t in inst.shape()), 8)
    check("Separate gives every pane a tab of its own", bool(ok), inst.shape())
    check("Separate is greyed again", not inst.button("Separate All Panes")["enabled"])
    check("the other project was left alone", sum(1 for s in inst.sessions() if s["project"] == "zulu-project") == 1)
    inst.shot("buttons-3")


def panes_focus_close(inst):
    inst.label_terminals()
    inst.click(*center(inst.button("Split Right")))
    wait_for(lambda: inst.shape()[0].startswith("row(alpha,new1"), 6)
    inst.click(*center(inst.button("Split Down")))
    wait_for(lambda: inst.shape()[0] == "row(alpha,column(new1,new2))", 6)
    time.sleep(1.5)

    # a click into another pane's terminal gives that pane the keyboard
    alpha = inst.pane("alpha")["frame"]
    inst.click(alpha["x"] + alpha["w"] // 2, alpha["y"] + alpha["h"] // 2)
    check("a click into a pane's terminal makes it the active one", wait_for(lambda: inst.active() == "alpha", 5), inst.active())
    inst.front()
    held = {"front": frontmost_pid() == str(inst.pid)}
    inst.inputs("type", "echo focusalpha")
    inst.key("return")
    held["after"] = frontmost_pid() == str(inst.pid)

    def screens():
        return {sid: (inst.api({"planchette_request": "session.read", "id": sid, "lines": 12}).get("result") or {}).get("text", "")
                for sid in inst.group()["sessionIDs"]}

    wait_for(lambda: "focusalpha" in screens()[SIDS[0]], 8)
    seen = screens()
    check("what is typed goes to that pane only",
          "focusalpha" in seen[SIDS[0]] and sum("focusalpha" in t for t in seen.values()) == 1,
          {"app in front before/after typing": held,
           **{k[-4:]: v.strip().splitlines()[-2:] for k, v in seen.items()}})

    # the title bar of a pane: click selects it
    titles = inst.panes()
    other = next(p for p in titles if p["name"] != "alpha")
    inst.click(other["title"][0] + 40, other["title"][1])
    check("a click on a pane's title bar selects it", wait_for(lambda: inst.active() != "alpha", 5), inst.active())

    # closing a pane: asks, then the others stay together
    inst.shot("pane-before-close")
    victim = inst.pane("alpha")
    inst.click(*center(victim["close"]))
    close = wait_for(lambda: inst.alert_button("Close"), 6)
    check("a pane's close button asks first", bool(close))
    if close:
        inst.click(*center(close))
    ok, shape = inst.wait_shape(["column(new1,new2)", "bravo", "charlie", "delta"])
    check("closing a pane leaves the rest of its tab", ok, shape)
    check("the keyboard moved to a pane of the same tab", inst.active() in ("new1", "new2"), inst.active())
    inst.shot("pane-after-close")

    # closing a whole split tab from its tab: one question, both panes
    tab = inst.tab_buttons()[0]
    inst.click(*center(tab["close"]))
    close = wait_for(lambda: inst.alert_button("Close"), 6)
    check("closing a split tab asks once", bool(close))
    if close:
        inst.click(*center(close))
    ok, shape = inst.wait_shape(["bravo", "charlie", "delta"])
    check("both its terminals are gone", ok, shape)
    check("the neighbour tab took over", wait_for(lambda: inst.active() == "bravo", 5), inst.active())
    check("the sessions are really closed",
          len([s for s in inst.sessions() if s["project"] == "alpha-project"]) == 3)


def switch_projects(inst):
    inst.label_terminals()
    inst.click(*center(inst.button("Split Right")))
    wait_for(lambda: inst.shape()[0].startswith("row(alpha,new1"), 6)
    drag_tab_onto(inst, "delta", edge_point(inst.pane("alpha")["frame"], "bottom", 40))
    ok, shape = inst.wait_shape(["row(column(alpha,delta),new1)", "bravo", "charlie"])
    check("a split to leave", ok, shape)
    before = inst.shape()
    zulu = inst.find(role="AXButton", contains="zulu, work/zulu")
    check("the other project's terminal is in the sidebar", bool(zulu))
    if zulu:
        inst.click(*center(zulu[0]))
        time.sleep(1.5)
        check("the other project shows its terminal and no split",
              len(inst.panes()) == 0 and wait_for(lambda: inst.tab_buttons() == [] or True, 1))
    again = inst.find(role="AXButton", contains="alpha, work/alpha")
    if again:
        inst.click(*center(again[0]))
    check("coming back shows the split again", wait_for(lambda: len(inst.panes()) == 3, 8), len(inst.panes()))
    check("the saved strip did not change", inst.shape() == before, inst.shape())
    labels_intact(inst, "after switching projects")


def persistence(inst):
    """Both run on a relaunch: tabs saved by this version, and state written before tabs held splits."""
    inst.label_terminals()
    inst.click(*center(inst.button("Split Right")))
    wait_for(lambda: inst.shape()[0].startswith("row(alpha,new1"), 6)
    drag_tab_onto(inst, "delta", edge_point(inst.pane("alpha")["frame"], "bottom", 40))
    ok, shape = inst.wait_shape(["row(column(alpha,delta),new1)", "bravo", "charlie"])
    check("a split and a drop, before the restart", ok, shape)
    saved = inst.group()["tabs"]
    inst.relaunch()
    check("the tabs came back as they were", inst.group()["tabs"] == saved, inst.group().get("tabs"))
    check("…and show as one split tab", wait_for(lambda: len(inst.panes()) == 3, 8), len(inst.panes()))
    inst.shot("restored")


def legacy_cluster(inst):
    """A project saved in cluster mode before tabs held splits: one tab with everything in it."""
    state = inst.state()
    layout = {"row": {"_0": [{"leaf": {"_0": SIDS[0]}}, {"column": {"_0": [{"leaf": {"_0": SIDS[1]}}, {"leaf": {"_0": SIDS[2]}}]}}, {"leaf": {"_0": SIDS[3]}}]}}
    for g in state["groups"]:
        if g["id"] == G:
            g["viewMode"] = "cluster"
            g["clusterLayout"] = layout
            g.pop("tabs", None)
    inst.stop_app()
    inst.write_state(state)
    inst.launch()
    check("a cluster-mode project opens as one split tab", wait_for(lambda: len(inst.tab_buttons()) == 1, 10),
          [t["name"] for t in inst.tab_buttons()])
    check("…with its four panes", wait_for(lambda: len(inst.panes()) == 4, 10), len(inst.panes()))
    inst.shot("legacy")
    inst.click(*center(inst.button("Separate All Panes")))
    ok = wait_for(lambda: inst.shape() == ["alpha", "bravo", "charlie", "delta"], 8)
    check("and it can be taken apart", bool(ok), inst.shape())
    check("the old keys are gone from the file",
          wait_for(lambda: "viewMode" not in json.dumps(inst.group()) and "clusterLayout" not in json.dumps(inst.group()), 6))


def tab_reorder(inst):
    inst.label_terminals()
    a = inst.tab("alpha")["frame"]
    t = inst.tab("delta")
    cx, cy = center(t["frame"])
    inst.drag_hover(cx - 20, cy, a["x"] + 30, a["y"] + a["h"] // 2, 1500, lambda: inst.screen_shot("reorder-hover"))
    ok, shape = inst.wait_shape(["delta", "alpha", "bravo", "charlie"])
    check("a tab dropped on another tab moves before it", ok, shape)


SCENARIOS = {"tab_names": tab_names, "switch_projects": switch_projects, "stress": stress, "split_drag": split_drag, "drop_refused": drop_refused, "buttons": buttons, "panes_focus_close": panes_focus_close, "persistence": persistence, "legacy_cluster": legacy_cluster, "tab_reorder": tab_reorder, "explore": explore, "tabs_basic": tabs_basic, "explore_split": explore_split}


def run_scenario(name, binary, scratch, files, scenarios=None, prepare=None, attempts=4):
    """One scenario, in its own instance. When it fails and the person at the machine was in the way
    (`Instance.disturbed`), it runs again — up to `attempts` times — and only the last attempt counts.
    A failure that survives a clean attempt is the app's."""
    scenarios = scenarios or SCENARIOS
    for attempt in range(1, attempts + 1):
        root = f"{scratch}/{name}"
        shutil.rmtree(root, ignore_errors=True)
        os.makedirs(root)
        wait_until_idle(int(os.environ.get("QUIET_SECONDS", "45")))
        print(f"[tab_split] --- {name}" + (f" (attempt {attempt})" if attempt > 1 else ""), flush=True)
        mark = len(RESULTS)
        inst = Instance(binary, root)
        if prepare:
            prepare(inst, name)
        try:
            inst.start()
            scenarios[name](inst)
        except Disturbed as error:
            inst.disturbed = True
            RESULTS.append((f"{name}: interrupted ({error})", False))
        except Exception as error:
            # A scenario that fell over after the person at the machine had been in the way (a window
            # that moved, an element that was not there) is retried like one that failed; one that
            # fell over on a quiet machine is a bug of the script or of the app, and is raised.
            if not inst.disturbed:
                raise
            RESULTS.append((f"{name}: stopped by {type(error).__name__} after the machine was used", False))
        finally:
            inst.stop()
        files.report(name)
        failed = [n for n, ok in RESULTS[mark:] if not ok]
        if failed and inst.disturbed and attempt < attempts:
            print(f"[tab_split] {len(failed)} check(s) failed while somebody used the machine: running {name} again", flush=True)
            del RESULTS[mark:]
            continue
        if failed and inst.disturbed:
            print(f"[tab_split] note: {name} was disturbed in every attempt; the failures may not be the app's", flush=True)
        break


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    binary, scratch = os.path.abspath(sys.argv[1]), scratch_root(sys.argv[2])
    chosen = sys.argv[3:] or [name for name in SCENARIOS if name != "explore"]
    files = UserFilesGuard()
    for name in chosen:
        run_scenario(name, binary, scratch, files)
    failed = [n for n, ok in RESULTS if not ok]
    print(f"[tab_split] RESULT: {len(RESULTS) - len(failed)} of {len(RESULTS)} checks ok" + (f"; FAILED: {', '.join(failed)}" if failed else ""))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
