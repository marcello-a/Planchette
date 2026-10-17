"""Does the notepad of a terminal work in the running app?

usage: notepad.py <binary> <scratch-folder> [scenario ...]        (default: every scenario)

Same method as tab_split.py: an ISOLATED instance on a seeded project, real mouse presses and key
presses posted as system events, elements found by their accessibility frames, the outcome read from
`state.json` and from the terminals' screens (the control API's `session.read`).

Run it through with_displays.sh. The instance comes to the front and the pointer moves: do not use
the machine while it runs (about 4 minutes). It needs the Accessibility permission.
"""
import os
import shutil
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tab_split
from tab_split import G, NAMES, SIDS, Instance, center, check, wait_for
from perf_common import UserFilesGuard, frontmost_pid, scratch_root, wait_until_idle

LOAD = "Add prompt to the terminal as a draft"
RUN = "Add prompt to the terminal and run it"


def notepad_button(inst):
    return next((e for e in inst.find(role="AXButton", desc="Notepad")), None)


def pad_text(inst):
    """The text area of the pad: the scroll area at the right of the window."""
    win = inst.window()
    areas = [e for e in inst.ax() if e["role"] == "AXScrollArea" and e["x"] > win["x"] + win["w"] // 2
             and e["h"] > 200]
    return areas[0] if areas else None


def pad_open(inst):
    """Open: its close button or its drag handle is in the accessibility tree."""
    return any(e["desc"] in ("Close the notepad", "Drag to change the width of the notepad")
               for e in inst.ax())


def pad_width(inst):
    """The pad is everything right of its drag handle."""
    handle = next((e for e in inst.ax() if e["desc"] == "Drag to change the width of the notepad"), None)
    if not handle:
        return None
    win = inst.window()
    return win["x"] + win["w"] - (handle["x"] + handle["w"])


def placeholder_shown(inst):
    return any(e["role"] == "AXStaticText" and e["value"].startswith("A prompt ends after")
               for e in inst.ax())


def saved_text(inst, index=0):
    for s in inst.state()["sessions"]:
        if s["id"] == SIDS[index]:
            return s.get("notepad")
    return None


def screen(inst, index=0, lines=14):
    reply = inst.api({"planchette_request": "session.read", "id": SIDS[index], "lines": lines})
    return (reply.get("result") or {}).get("text", "")


def load_buttons(inst):
    return sorted([e for e in inst.ax() if e["role"] == "AXButton" and e["desc"] == LOAD], key=lambda e: e["y"])


def run_buttons(inst):
    return sorted([e for e in inst.ax() if e["role"] == "AXButton" and e["desc"] == RUN], key=lambda e: e["y"])


def type_lines(inst, lines):
    for n, line in enumerate(lines):
        if n:
            inst.key("return")
        if line:
            inst.inputs("type", line)


def open_pad(inst):
    if not pad_open(inst):
        inst.click(*center(notepad_button(inst)))
        wait_for(lambda: pad_open(inst) and pad_text(inst), 6)
    return pad_text(inst)


def click_into_pad(inst):
    area = wait_for(lambda: pad_text(inst), 8)
    if area is None:
        raise tab_split.Disturbed("the notepad is not on screen")
    inst.click(area["x"] + area["w"] - 30, area["y"] + area["h"] - 30)      # empty space under the text
    time.sleep(0.4)


def pad_scenario(inst):
    inst.label_terminals()
    check("the notepad is closed at the start", not pad_open(inst))
    button = notepad_button(inst)
    check("the tab bar has a notepad button", button is not None)
    area = open_pad(inst)
    check("a click on the button opens the notepad", area is not None and pad_open(inst))
    title = [e for e in inst.ax() if e["role"] == "AXStaticText" and e["value"] == "Notepad — alpha"]
    check("it is the notepad of the terminal in front", bool(title))
    check("it says what ends a prompt", any(e["role"] == "AXStaticText" and "after 2 Returns" in e["value"] for e in inst.ax()))
    inst.shot("pad-open")

    # writing: a prompt of two lines, a blank line, a prompt of one
    click_into_pad(inst)
    type_lines(inst, ["echo one", "echo two", "", "echo three"])
    expected = "echo one\necho two\n\necho three"
    ok = wait_for(lambda: saved_text(inst) == expected, 8)
    check("what is typed is saved with the workspace", bool(ok), saved_text(inst))
    check("…and none of it reached the terminal", "echo one" not in screen(inst), screen(inst)[-120:])
    buttons = load_buttons(inst)
    check("one margin button for each prompt, not for each line", len(buttons) == 2, len(buttons))
    inst.shot("pad-text")

    # a click loads the whole prompt — both lines — into the terminal's input and does not run it
    inst.click(*center(buttons[0]))
    ok = wait_for(lambda: "echo one" in screen(inst) and "echo two" in screen(inst), 6)
    shown = screen(inst).strip().splitlines()
    check("a click on the draft button loads the prompt, both lines of it, into the terminal", bool(ok), shown[-4:])
    check("…without pressing Return", not any(l.strip() in ("one", "two") for l in shown), shown[-5:])
    check("the keyboard went to the terminal", wait_for(lambda: frontmost_pid() == str(inst.pid), 3))
    inst.key("return")
    ok = wait_for(lambda: [l.strip() for l in screen(inst).splitlines()].count("one") == 1
                  and [l.strip() for l in screen(inst).splitlines()].count("two") == 1, 6)
    check("Return in the terminal runs what was loaded", bool(ok), screen(inst).strip().splitlines()[-6:])

    # the second button: loaded and run
    check("every prompt has a run button as well", len(run_buttons(inst)) == len(load_buttons(inst)))
    inst.click(*center(run_buttons(inst)[1]))
    ok = wait_for(lambda: any(l.strip() == "three" for l in screen(inst).splitlines()), 6)
    check("the return button loads the prompt and presses Return", bool(ok), screen(inst).strip().splitlines()[-4:])

    # ⌘↩ with the caret in the second line of the first prompt
    area = pad_text(inst)
    first = load_buttons(inst)[0]
    inst.click(area["x"] + area["w"] - 30, first["y"] + first["h"] + first["h"] // 2)
    time.sleep(0.4)
    inst.key("return", "cmd")
    ok = wait_for(lambda: [l.strip() for l in screen(inst, 0, 30).splitlines()].count("one") == 2
                  and [l.strip() for l in screen(inst, 0, 30).splitlines()].count("two") == 2, 6)
    check("⌘↩ inside a prompt loads all of it and presses Return", bool(ok), screen(inst, 0, 30).strip().splitlines()[-6:])
    check("…and the pad kept its text", saved_text(inst) == expected, saved_text(inst))
    # ⌘↩ on the blank line does nothing
    click_into_pad(inst)
    time.sleep(1.5)
    before = screen(inst, 0, 40)
    area = pad_text(inst)
    inst.click(area["x"] + area["w"] - 30, first["y"] + 2 * first["h"] + first["h"] // 2)   # the blank line
    time.sleep(0.4)
    inst.key("return", "cmd")
    time.sleep(1.5)
    after = screen(inst, 0, 40)
    check("⌘↩ on a blank line loads nothing", after == before,
          {"before": before.strip().splitlines()[-4:], "after": after.strip().splitlines()[-4:],
           "front": front_app_name(), "blank line y": first["y"] + 2 * first["h"] + first["h"] // 2,
           "first button": (first["y"], first["h"])})


def seeded_setting(inst):
    """State that already holds notepads, and a setting of one Return: each line is a prompt."""
    def edit(state):
        for s in state["sessions"]:
            if s["id"] == SIDS[0]:
                s["notepad"] = "line a\nline b\n\nline c\n\n\nline d"
        state["notepad"] = {"isOpen": True, "width": 320, "returnsPerPrompt": 1}
    return edit


def setting_one_return(inst):
    inst.label_terminals()
    opened = wait_for(lambda: pad_open(inst), 8)
    inst.shot("one-return")
    check("a notepad saved in the state shows on start", bool(opened),
          {"file": inst.state().get("notepad"), "seen on screen": sorted({e["desc"] for e in inst.ax() if "otepad" in e["desc"]})})
    check("with one Return every line is a prompt: four margin buttons", len(load_buttons(inst)) == 4, len(load_buttons(inst)))
    check("…and the pad has the width that was saved", abs((pad_width(inst) or 0) - 320) < 20, pad_width(inst))
    inst.click(*center(load_buttons(inst)[1]))
    ok = wait_for(lambda: "line b" in screen(inst), 6)
    check("a click loads that one line", bool(ok) and "line a" not in screen(inst), screen(inst)[-80:])


def setting_default(inst):
    inst.label_terminals()
    check("a state from before the setting opens the pad", bool(wait_for(lambda: pad_open(inst), 8)))
    check("with the default, two Returns: 'line a/line b' is one prompt, so three in all", len(load_buttons(inst)) == 3, len(load_buttons(inst)))
    inst.click(*center(load_buttons(inst)[0]))
    ok = wait_for(lambda: "line a" in screen(inst) and "line b" in screen(inst), 6)
    check("…and a click loads both lines", bool(ok), screen(inst)[-100:])


def default_edit(state):
    for s in state["sessions"]:
        if s["id"] == SIDS[0]:
            s["notepad"] = "line a\nline b\n\nline c\n\n\nline d"
    state["notepad"] = {"isOpen": True, "width": 300}      # no returnsPerPrompt: an older file


def front_app_name():
    import subprocess
    out = subprocess.run(["osascript", "-e", 'tell application "System Events" to get name of first process whose frontmost is true'],
                         capture_output=True, text=True)
    return out.stdout.strip()


def close_resize(inst):
    inst.label_terminals()
    open_pad(inst)
    window = inst.window()
    width = pad_width(inst)
    check("the notepad opens at its default width", width is not None and abs(width - 280) < 40, width)

    def handle():
        return next((e for e in inst.ax() if e["desc"] == "Drag to change the width of the notepad"), None)

    check("the pad has a drag handle", handle() is not None)
    h = handle()
    if h:
        cx, cy = center(h)
        inst.drag(cx, cy, cx - 120, cy, steps=30, hold=200)
        ok = wait_for(lambda: pad_width(inst) and abs(pad_width(inst) - (width + 120)) < 20, 6)
        check("dragging the handle left makes the pad wider", bool(ok), pad_width(inst))
        cx, cy = center(handle())
        inst.drag(cx, cy, cx + 600, cy, steps=30, hold=200)
        ok = wait_for(lambda: pad_width(inst) and 170 < pad_width(inst) < 200, 6)
        check("dragged far right it stops at its minimum width", bool(ok), pad_width(inst))
        cx, cy = center(handle())
        inst.drag(cx, cy, cx - 1500, cy, steps=40, hold=200)
        ok = wait_for(lambda: pad_width(inst) and pad_width(inst) > 500, 6)
        wide = pad_width(inst) or 0
        check("dragged far left it stops where the terminal keeps its room",
              bool(ok) and (window["w"] - 300) - wide >= 250, wide)
        cx, cy = center(handle())
        inst.drag(cx, cy, cx + 300, cy, steps=30, hold=200)
        time.sleep(1.2)
    stored = inst.state().get("notepad")
    check("the width is stored", bool(stored) and stored.get("isOpen") is True and stored["width"] >= 180, stored)

    # close with the X, then open with ⌘J
    close = inst.button("Close the notepad")
    check("the notepad has a close button", close is not None)
    if close:
        inst.click(*center(close))
    check("the X closes it", bool(wait_for(lambda: not pad_open(inst), 5)))
    check("…and the state says closed", bool(wait_for(lambda: inst.state().get("notepad", {}).get("isOpen") is False, 6)))
    inst.key("j", "cmd")
    check("⌘J opens it again", bool(wait_for(lambda: pad_open(inst), 5)),
          {"state": inst.state().get("notepad"), "front": frontmost_pid() == str(inst.pid)})
    check("…at the width it had", abs((pad_width(inst) or 0) - stored["width"]) < 20, pad_width(inst))
    inst.shot("pad-resized")


def several_terminals(inst):
    inst.label_terminals()
    open_pad(inst)
    click_into_pad(inst)
    type_lines(inst, ["alpha one", "", "alpha two"])
    wait_for(lambda: saved_text(inst, 0) == "alpha one\n\nalpha two", 6)

    def title(name):
        return any(e["role"] == "AXStaticText" and e["value"] == f"Notepad — {name}" for e in inst.ax())

    inst.click(*center(inst.tab("bravo")["frame"]))
    check("another terminal shows its own pad", bool(wait_for(lambda: title("bravo"), 6)))
    shown = bool(wait_for(lambda: placeholder_shown(inst), 4))
    win = inst.window()
    check("…which is empty", shown and len(load_buttons(inst)) == 0,
          {"placeholder": shown, "buttons": len(load_buttons(inst)),
           "texts right of the middle": [e["value"][:50] for e in inst.ax()
                                         if e["role"] == "AXStaticText" and e["x"] > win["x"] + win["w"] // 2]})
    click_into_pad(inst)
    type_lines(inst, ["bravo only"])
    check("…and is written on its own", bool(wait_for(lambda: saved_text(inst, 1) == "bravo only", 6)), saved_text(inst, 1))
    check("…and leaves the first alone", saved_text(inst, 0) == "alpha one\n\nalpha two", saved_text(inst, 0))

    inst.click(*center(inst.tab("alpha")["frame"]))
    ok = wait_for(lambda: title("alpha") and len(load_buttons(inst)) == 2 and not placeholder_shown(inst), 6)
    check("coming back shows the first text", bool(ok), len(load_buttons(inst)))

    # a line loads into the terminal the pad belongs to
    inst.click(*center(inst.tab("bravo")["frame"]))
    wait_for(lambda: title("bravo") and len(load_buttons(inst)) == 1, 6)
    inst.click(*center(load_buttons(inst)[0]))
    ok = wait_for(lambda: "bravo only" in screen(inst, 1), 6)
    check("a line goes to its own terminal", bool(ok) and "bravo only" not in screen(inst, 0), screen(inst, 1)[-80:])

    # a split tab: the pad follows the pane that has the keyboard
    inst.click(*center(inst.button("Split Right")))
    wait_for(lambda: inst.shape()[1].startswith("row(bravo,new1"), 8)
    time.sleep(1.5)
    check("the pad follows the pane that has the keyboard: the new pane's pad is empty",
          bool(wait_for(lambda: placeholder_shown(inst), 6)))


def keyboard_stays(inst):
    """Typing in the pad is not interrupted by what the terminal does."""
    inst.label_terminals()
    # a terminal that keeps changing: a loop printing a line every 200 ms
    inst.api({"planchette_request": "session.prompt", "id": SIDS[0],
              "text": "while true; do echo tick; sleep 0.2; done", "force": True})
    time.sleep(1.5)
    open_pad(inst)
    click_into_pad(inst)
    text = "the quick brown fox jumps over the lazy dog"
    inst.inputs("type", text)
    ok = wait_for(lambda: saved_text(inst) == text, 8)
    check("a long line typed while the terminal prints arrives whole", bool(ok), saved_text(inst))
    check("none of it went to the terminal", "quick" not in screen(inst, 0, 30))
    # ⌘A, then typing replaces: the shortcut reached the pad, not the terminal
    inst.key("a", "cmd")
    inst.inputs("type", "x")
    check("⌘A in the pad selects the pad's text", bool(wait_for(lambda: saved_text(inst) == "x", 6)), saved_text(inst))
    inst.key("z", "cmd")
    check("⌘Z undoes it", bool(wait_for(lambda: saved_text(inst) == text, 6)), saved_text(inst))
    inst.key("c", "ctrl")          # stop the loop: the keyboard is still in the pad, so first go to the terminal
    inst.click(*center(inst.tab("alpha")["frame"]))


def restart(inst):
    inst.label_terminals()
    open_pad(inst)
    click_into_pad(inst)
    type_lines(inst, ["restart one", "second line", "", "restart two 🙂 \"quoted\""])
    expected = "restart one\nsecond line\n\nrestart two 🙂 \"quoted\""
    wait_for(lambda: saved_text(inst) == expected, 8)
    handle = next(e for e in inst.ax() if e["desc"] == "Drag to change the width of the notepad")
    cx, cy = center(handle)
    inst.drag(cx, cy, cx - 90, cy, steps=30, hold=200)
    time.sleep(1.5)
    width = pad_width(inst)
    inst.relaunch()
    check("the notepad is open after a restart", bool(wait_for(lambda: pad_open(inst), 10)))
    check("…with the same text: two prompts, so two buttons",
          bool(wait_for(lambda: len(load_buttons(inst)) == 2 and not placeholder_shown(inst), 8)), len(load_buttons(inst)))
    check("…saved as it was", saved_text(inst) == expected, saved_text(inst))
    check("…and the same width", abs((pad_width(inst) or 0) - width) < 12, pad_width(inst))
    inst.shot("pad-restored")
    # closing a terminal takes its pad with it
    inst.click(*center(inst.tab_buttons()[0]["close"]))
    close = wait_for(lambda: inst.alert_button("Close"), 6)
    if close:
        inst.click(*center(close))
    wait_for(lambda: len(inst.tab_buttons()) == 3, 8)
    time.sleep(1.5)
    check("a closed terminal's pad is gone from the file",
          SIDS[0] not in [s["id"] for s in inst.state()["sessions"]]
          and "restart one" not in str(inst.state()))


def quit_saves(inst):
    """Quit right after typing — before the save that follows a change has had its second."""
    inst.label_terminals()
    open_pad(inst)
    click_into_pad(inst)
    time.sleep(2.0)                                   # the opening is saved; what follows is not
    text = "typed just before quitting"
    inst.inputs("type", text)
    inst.key("q", "cmd")
    try:
        inst.proc.wait(timeout=15)
        quit_ok = True
    except Exception:
        quit_ok = False
    check("⌘Q quits", quit_ok)
    check("what was typed a moment before is in the saved state", saved_text(inst) == text, saved_text(inst))
    inst.proc = None
    inst.launch()
    check("…and in the pad after the next start",
          bool(wait_for(lambda: pad_open(inst) and len(load_buttons(inst)) == 1 and not placeholder_shown(inst), 10)))


TEXT_AFTER = "first\n\nsecond line a\nsecond line b\n\nthird"


def after_seed(action, default=False):
    def edit(state):
        for session in state["sessions"]:
            if session["id"] == SIDS[0]:
                session["notepad"] = TEXT_AFTER
        state["notepad"] = {"isOpen": True, "width": 300}
        if not default:               # the default: a file that says nothing about it
            state["notepad"]["afterLoading"] = action
    return edit


def after_default(inst):
    """With nothing said, a loaded prompt leaves the pad — and ⌘Z gives it back."""
    inst.label_terminals()
    check("the pad is open with its saved text", bool(wait_for(lambda: pad_open(inst) and len(load_buttons(inst)) == 3, 10)),
          len(load_buttons(inst)))
    inst.click(*center(load_buttons(inst)[1]))                       # the prompt of two lines
    ok = wait_for(lambda: saved_text(inst) == "first\n\nthird", 8)
    check("a prompt that was loaded leaves the pad, and the gap with it", bool(ok), saved_text(inst))
    check("…both of its lines are in the terminal",
          bool(wait_for(lambda: "second line a" in screen(inst) and "second line b" in screen(inst), 6)), screen(inst)[-100:])
    check("…and the margin has one button fewer", bool(wait_for(lambda: len(load_buttons(inst)) == 2, 6)), len(load_buttons(inst)))
    inst.shot("after-removed")

    click_into_pad(inst)
    inst.key("z", "cmd")
    check("⌘Z gives the prompt back", bool(wait_for(lambda: saved_text(inst) == TEXT_AFTER, 8)), saved_text(inst))

    # ⌘↩ inside the first prompt: loaded, run, and gone
    area = pad_text(inst)
    first = load_buttons(inst)[0]
    inst.click(area["x"] + area["w"] - 30, first["y"] + first["h"] // 2)
    time.sleep(0.4)
    inst.key("return", "cmd")
    ok = wait_for(lambda: saved_text(inst) == "second line a\nsecond line b\n\nthird", 8)
    check("⌘↩ removes the prompt it loaded", bool(ok), saved_text(inst))
    check("…and the terminal ran it", bool(wait_for(lambda: any("first" in l for l in screen(inst).splitlines()), 6)))

    # the last prompt: nothing is left behind it
    inst.click(*center(load_buttons(inst)[-1]))
    ok = wait_for(lambda: saved_text(inst) == "second line a\nsecond line b", 8)
    check("the last prompt takes no empty lines with it", bool(ok), saved_text(inst))
    # everything gone: an empty pad shows its hint again
    inst.click(*center(load_buttons(inst)[0]))
    check("the pad ends empty, with its hint", bool(wait_for(lambda: saved_text(inst) in (None, "") and placeholder_shown(inst), 8)),
          saved_text(inst))


def after_strike(inst):
    """With the setting on strike, a loaded prompt stays, marked — and still loads without the marks."""
    inst.label_terminals()
    check("the pad is open with its saved text", bool(wait_for(lambda: pad_open(inst) and len(load_buttons(inst)) == 3, 10)))
    inst.click(*center(load_buttons(inst)[0]))
    ok = wait_for(lambda: saved_text(inst) == "~~first~~\n\nsecond line a\nsecond line b\n\nthird", 8)
    check("a loaded prompt stays, between ~~ marks", bool(ok), saved_text(inst))
    check("…the terminal got the words, not the marks",
          bool(wait_for(lambda: "first" in screen(inst), 6)) and "~~" not in screen(inst), screen(inst)[-80:])
    check("…and the margin still has all its buttons", len(load_buttons(inst)) == 3, len(load_buttons(inst)))
    inst.shot("after-struck")
    # loading a struck prompt again adds nothing to the text
    inst.click(*center(load_buttons(inst)[0]))
    time.sleep(2.0)
    check("loading it again does not mark it twice",
          saved_text(inst) == "~~first~~\n\nsecond line a\nsecond line b\n\nthird", saved_text(inst))
    # ⌘↩ marks the prompt it loaded
    area = pad_text(inst)
    third = load_buttons(inst)[2]
    inst.click(area["x"] + area["w"] - 30, third["y"] + third["h"] // 2)
    time.sleep(0.4)
    inst.key("return", "cmd")
    ok = wait_for(lambda: (saved_text(inst) or "").endswith("~~third~~"), 8)
    check("⌘↩ marks the prompt it loaded", bool(ok), saved_text(inst))


def shortcut(inst):
    """⌘J opens the pad with the cursor in it, and closes it with the keyboard back in the terminal."""
    inst.label_terminals()
    inst.click(*center(inst.tab("alpha")["frame"]))      # the terminal has the keyboard
    time.sleep(1.0)

    def where():
        return {"front": front_app_name(), "pad state": inst.state().get("notepad"), "pad on screen": pad_open(inst)}

    inst.key("j", "cmd")
    check("⌘J opens the notepad", bool(wait_for(lambda: pad_open(inst), 6)), where())
    time.sleep(0.8)
    inst.inputs("type", "typed at once")
    check("…with the cursor in it: typing needs no click", bool(wait_for(lambda: saved_text(inst) == "typed at once", 8)),
          {"saved": saved_text(inst), **where(), "terminal": screen(inst)[-60:]})
    check("…and nothing went to the terminal", "typed at once" not in screen(inst))
    inst.key("j", "cmd")
    check("⌘J closes it", bool(wait_for(lambda: not pad_open(inst), 6)), where())
    time.sleep(1.0)
    inst.inputs("type", "echo back")
    ok = wait_for(lambda: "echo back" in screen(inst), 6)
    check("…and the keyboard is back in the terminal", bool(ok), {**where(), "terminal": screen(inst)[-80:]})
    check("the closed pad kept its text", saved_text(inst) == "typed at once", saved_text(inst))
    inst.key("j", "cmd")
    check("⌘J opens it again", bool(wait_for(lambda: pad_open(inst), 6)), where())
    check("…with the text that was there", bool(wait_for(lambda: len(load_buttons(inst)) == 1, 6)))
    inst.shot("pad-shortcut")


# ---- the picture of the notepad hint ------------------------------------------------------------
# Not a check: it records `hints/notepad.gif`, the loop the first-use hint shows. A stand-in agent
# (a shell loop that answers every line it reads) takes the place of Claude Code, so the picture
# is the real window with real clicks — and nobody's prompts. Run it by name:
#   with_displays.sh 900 python3 scripts/perf/notepad.py <binary> <scratch> gif

GIF_STEPS = [
    # (frame, caption, seconds)
    ("empty", "Write your prompts ahead of time", 1.6),
    ("one", "Markdown shows as you type", 1.6),
    ("three", "One prompt after the other", 1.8),
    ("run", "Return arrow: send it now", 2.2),
    ("draft", "Down arrow: add it as a draft", 2.6),
]


def gif_scenario(inst):
    # Lower case only: the typing tool does not press Shift, and a picture must not show its seams.
    inst.label_terminals()
    open_pad(inst)
    win = inst.window()
    inst.click(win["x"] + win["w"] // 4, win["y"] + win["h"] // 2)             # into the terminal
    time.sleep(0.5)
    inst.inputs("type", 'clear; while read -r l; do echo "agent> $l"; done')
    inst.key("return")
    time.sleep(1.0)
    inst.shot("gif-empty")

    click_into_pad(inst)
    inst.inputs("type", "fix the **cart** crash")
    time.sleep(0.5)
    inst.shot("gif-one")
    inst.key("return")
    inst.key("return")
    inst.inputs("type", "add a test for `total()`")
    inst.key("return")
    inst.key("return")
    inst.inputs("type", "update the readme")
    time.sleep(0.6)
    inst.shot("gif-three")

    area = pad_text(inst)
    run_at, draft_at = center(run_buttons(inst)[0]), center(load_buttons(inst)[0])
    inst.click(*run_at)
    wait_for(lambda: "agent> fix the" in screen(inst), 8)
    time.sleep(0.8)
    inst.shot("gif-run")

    inst.click(*draft_at)
    wait_for(lambda: "add a test for" in screen(inst).split("agent> fix")[-1], 8)
    time.sleep(0.8)
    inst.shot("gif-draft")
    check("the frames of the picture were taken", all(
        os.path.exists(f"{inst.shots}/gif-{name}.png") for name, _, _ in GIF_STEPS), inst.shots)
    out = os.environ.get("HINT_GIF_OUT")
    if out:
        # In points, from the window's corner: what to crop, and where the clicked buttons are.
        left, top = win["x"], win["y"]
        # The terminal starts where the first tab does (the project list is at its left).
        tabs = [e for e in inst.ax() if e.get("value") == "alpha" or e.get("desc") == "alpha"]
        tabs = [e for e in tabs if e["y"] < area["y"] - 10]
        term_left = min((e["x"] for e in tabs), default=left + 420) - left - 60      # a tab's text sits inside the tab
        margin = 44                                                          # the margin's two buttons
        box = {"x": area["x"] - margin - left, "y": area["y"] - 34 - top, "w": area["w"] + margin, "h": 300,
               "term": term_left}
        build_gif(inst.shots, out, box, {"run": (run_at[0] - left, run_at[1] - top),
                                         "draft": (draft_at[0] - left, draft_at[1] - top)})


def build_gif(shots, out, box, clicks):
    """Crop the terminal's end and the pad, ring the button that was clicked, caption, loop."""
    import subprocess
    frames = []
    for name, caption, seconds in GIF_STEPS:
        src, dst = f"{shots}/gif-{name}.png", f"{shots}/gif-{name}-done.png"
        k = 2                                                              # a retina screenshot
        # Two pieces side by side: where the terminal's text is (its top left corner) and the pad.
        # The terminal is far wider than its text, so the stretch between them is left out.
        lead = 300
        cmd = ["magick", "(", src, "-crop", f"{lead * k}x{box['h'] * k}+{box['term'] * k}+{box['y'] * k}", "+repage", ")",
               "(", src, "-crop", f"{box['w'] * k}x{box['h'] * k}+{box['x'] * k}+{box['y'] * k}", "+repage", ")",
               "+append"]
        if name in clicks:
            cx, cy = (lead + clicks[name][0] - box["x"]) * k, (clicks[name][1] - box["y"]) * k
            cmd += ["-fill", "none", "-stroke", "#ff453a", "-strokewidth", "4",
                    "-draw", f"circle {cx},{cy} {cx + 22},{cy}"]
        cmd += ["-resize", "960x", "-gravity", "South", "-background", "#1d1d1f", "-fill", "white",
                "-stroke", "none", "-pointsize", "34", "-splice", "0x70", "-annotate", "+0+18", caption, dst]
        subprocess.run(cmd, check=True)
        frames += ["-delay", str(int(seconds * 100)), dst]
    subprocess.run(["magick", *frames, "-loop", "0", "+dither", "-colors", "48", "-layers", "Optimize", out], check=True)
    print(f"[notepad] wrote {out} ({os.path.getsize(out) // 1024} KB)")


SCENARIOS = {"after_default": after_default, "after_strike": after_strike, "shortcut": shortcut, "quit_saves": quit_saves, "pad": pad_scenario, "one_return": setting_one_return, "default_returns": setting_default, "close_resize": close_resize, "several": several_terminals,
             "keyboard": keyboard_stays, "restart": restart, "gif": gif_scenario}


AFTER_SCENARIOS = ("after_default", "after_strike")


def with_after(edit, action):
    """An edit of the seeded state, and the setting for what happens after a prompt was loaded."""
    def both(state):
        if edit:
            edit(state)
        state.setdefault("notepad", {})["afterLoading"] = action
    return both


def prepare(inst, name):
    if name == "one_return":
        inst.edit_state = with_after(seeded_setting(inst), "keep")
    elif name == "default_returns":
        inst.edit_state = with_after(default_edit, "keep")
    elif name == "after_default":
        inst.edit_state = after_seed("remove", default=True)
    elif name == "after_strike":
        inst.edit_state = after_seed("strike")
    elif name == "gif":
        inst.edit_state = with_after(None, "remove")
    else:
        # What the older scenarios check is what the pad says; they do not want it to shrink.
        inst.edit_state = with_after(None, "keep")


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    binary, scratch = os.path.abspath(sys.argv[1]), scratch_root(sys.argv[2])
    chosen = sys.argv[3:] or [n for n in SCENARIOS if n != "gif"]
    files = UserFilesGuard()
    for name in chosen:
        tab_split.run_scenario(name, binary, scratch, files, scenarios=SCENARIOS, prepare=prepare)
    results = tab_split.RESULTS
    failed = [n for n, ok in results if not ok]
    print(f"[notepad] RESULT: {len(results) - len(failed)} of {len(results)} checks ok"
          + (f"; FAILED: {', '.join(failed)}" if failed else ""))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
