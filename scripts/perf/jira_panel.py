"""Does the Jira panel work in the running app, and what does its hint show?

usage: jira_panel.py <binary> <scratch-folder> [scenario ...]     (default: off, on)

Same method as notepad.py: an ISOLATED instance on a seeded project, real mouse presses, elements
found by their accessibility frames. An isolated instance asks Jira for nothing; it is given a search
answer as Jira sends it (`-jiraFixture <file>`), so the cards are real cards of the app.

  off   both panels switched off (the default): no ticket button, no to-do button
  on    switched on, notepad and Jira open: the panel right of the pad, cards from the fixture, the
        ticket button closes it and the closed panel is saved
  gif   (by name, not a check) records `hints/jira.gif` for the hint: HINT_GIF_OUT=hints/jira.gif

Run it through with_displays.sh, and do not use the machine while it runs (about a minute).
"""
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tab_split
from tab_split import SIDS, center, check, wait_for
from perf_common import UserFilesGuard, scratch_root

JIRA_HANDLE = "Change the width of the Jira panel"
PAD_HANDLE = "Drag to change the width of the notepad"

TICKETS = [
    # key, type, priority, summary, status, category, assignee, days in the status
    ("SHOP-1234", "Bug", "High", "Checkout button jumps on iOS 18 when the keyboard opens",
     "In Progress", "indeterminate", "Tim Weber", 2),
    ("SHOP-1198", "Story", "Medium", "Discount codes: validate before the payment step",
     "In Review", "indeterminate", "Tim Weber", 5),
    ("SHOP-1170", "Task", "Low", "Newsletter opt-in on the order confirmation",
     "To Do", "new", None, 12),
    ("SHOP-1102", "Bug", "Highest", "Poster preview renders the frame twice",
     "To Do", "new", "Tim Weber", 1),
]


def fixture(path):
    """A search answer as Jira sends it, the status changes dated relative to now."""
    now = datetime.now(timezone.utc)
    stamp = lambda days: (now - timedelta(days=days, hours=1)).strftime("%Y-%m-%dT%H:%M:%S.000+0000")
    issues = []
    for key, kind, priority, summary, status, category, assignee, days in TICKETS:
        issues.append({"key": key, "fields": {
            "summary": summary, "issuetype": {"name": kind}, "priority": {"name": priority},
            "status": {"name": status, "statusCategory": {"key": category}},
            "assignee": {"displayName": assignee} if assignee else None,
            "created": stamp(days + 20)},
            "changelog": {"histories": [{"created": stamp(days), "items": [{"field": "status"}]}]}})
    with open(path, "w") as handle:
        json.dump({"issues": issues, "isLast": True}, handle)


def seed(open_panels):
    def edit(state):
        state["todosEnabled"] = True
        state["jiraEnabled"] = True
        state["jira"] = {"site": "example.atlassian.net", "email": "me@example.com", "open": open_panels,
                         "width": 300, "queries": [
                             {"id": "33333333-0000-0000-0000-000000000001", "name": "My open tickets",
                              "jql": "assignee = currentUser() AND statusCategory != Done", "collapsed": False},
                             {"id": "33333333-0000-0000-0000-000000000002", "name": "Team bugs",
                              "jql": "project = SHOP AND type = Bug", "collapsed": True}]}
        if open_panels:
            state["notepad"] = {"openTerminals": [SIDS[0]], "width": 280}
    return edit


def jira_button(inst, elements=None):
    found = inst.find(role="AXButton", desc="Jira", elements=elements)
    return found[0] if found else None


def has(inst, desc, elements=None):
    return any(e["desc"] == desc for e in (elements or inst.ax()))


def cards_shown(inst):
    return any("SHOP-1234" in (e["value"] + e["title"] + e["desc"]) for e in inst.ax())


# ---- checks

def off(inst):
    inst.window()
    time.sleep(1)
    elements = inst.ax()
    check("off: no ticket button", jira_button(inst, elements) is None)
    check("off: no to-do button", not any("To-dos" in (e["desc"], e["title"]) for e in elements))
    check("off: the notepad button is still there", bool(inst.find(role="AXButton", desc="Notepad", elements=elements)))


def on(inst):
    inst.window()
    time.sleep(1.5)
    elements = inst.ax()
    button, pad = jira_button(inst, elements), inst.find(role="AXButton", desc="Notepad", elements=elements)
    check("on: ticket button", button is not None)
    check("on: to-do button", any("To-dos" in (e["desc"], e["title"]) for e in elements))
    if button and pad:
        check("on: ticket button left of the notepad button", button["x"] < pad[0]["x"])
    pad_handle = next((e for e in elements if e["desc"] == PAD_HANDLE), None)
    jira_handle = next((e for e in elements if e["desc"] == JIRA_HANDLE), None)
    check("on: pad and Jira open", bool(pad_handle and jira_handle))
    if pad_handle and jira_handle:
        check("on: Jira right of the pad", jira_handle["x"] > pad_handle["x"])
    inst.shot("on")
    # Closing and opening again asks again: the fixture's cards come in.
    if button:
        inst.click(*center(button))
        check("on: the button closes the panel", wait_for(lambda: not has(inst, JIRA_HANDLE), 5))
        check("on: the pad stays open", has(inst, PAD_HANDLE))
        check("on: closed is saved", wait_for(lambda: inst.state().get("jira", {}).get("open") is False, 6))
        inst.click(*center(jira_button(inst)))
        check("on: the cards come in", wait_for(lambda: cards_shown(inst), 6))
        inst.shot("cards")


# ---- the hint's picture

GIF_STEPS = [
    # (frame, caption, seconds)
    ("closed", "Your Jira tickets, one click away", 1.8),
    ("open", "Your own JQL queries, as cards", 2.6),
    ("menu", "Right-click: a terminal for the ticket", 2.2),
    ("terminal", "…in the project you pick", 2.4),
]


def gif(inst):
    # At the right edge of the screen, so the project submenu opens to the left, inside the picture.
    # Read through AppKit: asking Finder needs an Automation permission and fails quietly without it.
    screen_w = int(float(subprocess.run(
        ["osascript", "-l", "JavaScript", "-e", 'ObjC.import("AppKit"); $.NSScreen.mainScreen.frame.size.width'],
        capture_output=True, text=True).stdout.strip() or 1470))
    subprocess.run(["osascript", "-e", f'tell application "System Events" to tell {inst.ref} to '
                    f'set position of window 1 to {{{screen_w - 1440}, 50}}'], capture_output=True)
    time.sleep(1.2)
    win = inst.window()
    time.sleep(1.5)
    button = jira_button(inst)
    inst.screen_shot("gif-closed")
    clicks = {"closed": center(button)}
    inst.click(*center(button))
    wait_for(lambda: cards_shown(inst), 8)
    time.sleep(0.8)
    inst.screen_shot("gif-open")

    card = next(e for e in inst.ax() if "SHOP-1198" in (e["value"] + e["title"] + e["desc"]))
    inst.rclick(card["x"] + 40, card["y"] + 30)
    time.sleep(0.8)
    item = next((e for e in inst.ax() if e["title"] == "Open a terminal in"), None)
    if item:
        inst.inputs("move", *center(item))
        time.sleep(0.9)
    inst.screen_shot("gif-menu")
    target = next((e for e in inst.ax() if e["title"] == "zulu-project" and e["role"] == "AXMenuItem"), None)
    check("gif: the project menu lists the projects", target is not None)
    if target:
        clicks["menu"] = center(target)
        inst.click(*center(target))
        time.sleep(2.0)
    # The pointer away from the cards: a tooltip half in the picture would only distract.
    inst.inputs("move", win["x"] + 200, win["y"] + win["h"] // 2)
    time.sleep(1.0)
    inst.screen_shot("gif-terminal")
    check("gif: the frames were taken", all(os.path.exists(f"{inst.shots}/gif-{n}.png") for n, _, _ in GIF_STEPS))

    out = os.environ.get("HINT_GIF_OUT")
    if out:
        # The right part of the window: the tab bar's buttons and the panel, the end of the terminal.
        width, height = 620, 470
        box = {"x": win["x"] + win["w"] - width, "y": win["y"] + 40, "w": width, "h": height}
        build_gif(inst.shots, out, box, clicks)


# ImageMagick has no default font of its own on every machine.
FONT = "/System/Library/Fonts/SFNS.ttf"


def build_gif(shots, out, box, clicks):
    """Crop, ring what was clicked, caption, loop — as notepad.py does."""
    k = 2                                                                  # a retina screenshot
    frames = []
    for name, caption, seconds in GIF_STEPS:
        src, dst = f"{shots}/gif-{name}.png", f"{shots}/gif-{name}-done.png"
        cmd = ["magick", src, "-crop", f"{box['w'] * k}x{box['h'] * k}+{box['x'] * k}+{box['y'] * k}", "+repage"]
        if name in clicks:
            cx, cy = (clicks[name][0] - box["x"]) * k, (clicks[name][1] - box["y"]) * k
            cmd += ["-fill", "none", "-stroke", "#ff453a", "-strokewidth", "4",
                    "-draw", f"circle {cx},{cy} {cx + 22},{cy}"]
        cmd += ["-resize", "960x", "-font", FONT, "-gravity", "South", "-background", "#1d1d1f", "-fill", "white",
                "-stroke", "none", "-pointsize", "34", "-splice", "0x70", "-annotate", "+0+18", caption, dst]
        subprocess.run(cmd, check=True)
        frames += ["-delay", str(int(seconds * 100)), dst]
    subprocess.run(["magick", *frames, "-loop", "0", "+dither", "-colors", "64", "-layers", "Optimize", out], check=True)
    print(f"[jira_panel] wrote {out} ({os.path.getsize(out) // 1024} KB)")


SCENARIOS = {"off": off, "on": on, "gif": gif}


def prepare(inst, name):
    path = f"{inst.root}/fixture.json"
    fixture(path)
    inst.extra_args = ["-jiraFixture", path]
    if name == "on":
        inst.edit_state = seed(True)
    elif name == "gif":
        inst.edit_state = seed(False)


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    binary, scratch = os.path.abspath(sys.argv[1]), scratch_root(sys.argv[2])
    chosen = sys.argv[3:] or ["off", "on"]
    files = UserFilesGuard()
    for name in chosen:
        tab_split.run_scenario(name, binary, scratch, files, scenarios=SCENARIOS, prepare=prepare)
    results = tab_split.RESULTS
    failed = [n for n, ok in results if not ok]
    print(f"[jira_panel] RESULT: {len(results) - len(failed)} of {len(results)} checks ok"
          + (f"; FAILED: {', '.join(failed)}" if failed else ""))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
