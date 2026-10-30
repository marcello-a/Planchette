"""Does drag and drop in the project panel work in the running app?

usage: sidebar_drag.py <binary> <scratch-folder>        (run through with_displays.sh)

One ISOLATED instance on two folders and a loose project, driven with real mouse drags
(`tools/inputs`, rows found by their accessibility frames) the way a person does it, the outcome
read back from `state.json` and the control API:

  1. a project into another folder (dropped on the folder row)
  2. a project from one folder next to a project in another folder
  3. a terminal into another project (dropped on the project row)
  4. a terminal to another place in its own project (dropped on a terminal row)
  5. a folder above another folder
  6. a project dropped on a terminal types nothing into it (the drag is JSON, never text)

The instance comes to the front and the pointer is moved: do not use the machine while it runs
(about a minute; it waits for you to stop first). It needs the Accessibility permission.
"""
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from perf_common import UserFilesGuard, scratch_root, wait_until_idle
from tab_split import Disturbed, Instance, center, wait_for

RESULTS = []


def check(name, ok, detail=""):
    RESULTS.append((name, bool(ok)))
    print(f"[sidebar_drag] {'ok  ' if ok else 'FAIL'} {name}" + (f"  ({detail})" if detail and not ok else ""), flush=True)


W = "00000000-0000-0000-0000-0000000000a1"
F_ALPHA, F_BETA = "33333333-0000-0000-0000-0000000000a1", "33333333-0000-0000-0000-0000000000b1"
P = {name: f"11111111-0000-0000-0000-00000000000{n}" for n, name in enumerate(["one", "two", "three", "four"], 1)}
T = {name: f"22222222-0000-0000-0000-0000000000{n:02d}" for n, name in enumerate(
    ["t-one", "t-two-a", "t-two-b", "t-three", "t-four-a", "t-four-b", "t-four-c"], 1)}
TERMINALS = {"one": ["t-one"], "two": ["t-two-a", "t-two-b"], "three": ["t-three"],
             "four": ["t-four-a", "t-four-b", "t-four-c"]}


def seed(root):
    def edit(state):
        groups, sessions = [], []
        for name, gid in P.items():
            ids = [T[t] for t in TERMINALS[name]]
            groups.append({"id": gid, "name": name, "sessionIDs": ids, "activeSessionID": ids[0],
                           "active": True, "favorite": False, "color": "none"})
            for t in TERMINALS[name]:
                directory = f"{root}/work/{t}"
                os.makedirs(directory, exist_ok=True)
                sessions.append(Instance._session(T[t], gid, directory, t))
        state["groups"], state["sessions"] = groups, sessions
        state["windows"] = [{
            "id": W, "groupIDs": [P["one"], P["two"], P["three"], P["four"]], "selectedGroupID": P["four"],
            "showsProjectOverview": False,
            "folders": [
                {"id": F_ALPHA, "name": "Alpha", "color": "blue", "collapsed": False, "groupIDs": [P["one"], P["two"]]},
                {"id": F_BETA, "name": "Beta", "color": "green", "collapsed": False, "groupIDs": [P["three"]]},
            ]}]
    return edit


def saved(inst):
    time.sleep(2.0)                  # a change is saved a second after it is made
    return json.load(open(f"{inst.state_dir}/state.json"))


def folders(inst):
    return {f["name"]: [i.lower() for i in f["groupIDs"]] for f in saved(inst)["windows"][0]["folders"]}


def folder_order(inst):
    return [f["name"] for f in saved(inst)["windows"][0]["folders"]]


def project_terminals(inst, name):
    for p in inst.api({"planchette_request": "project.list"})["result"]["projects"]:
        if p["id"].lower() == P[name]:
            return p["sessions"]
    return None


def arrow_owners(inst):
    """Whose disclosure arrow each one is, top to bottom: a folder, then its projects of several
    terminals (one terminal is a merged row without an arrow), then the loose ones. The tree has
    no text for a disclosure row's label — only its arrow — so the arrows are matched to the order
    the saved state gives."""
    state = saved(inst)
    window = state["windows"][0]
    counts = {g["id"].lower(): len(g["sessionIDs"]) for g in state["groups"]}
    names = {g["id"].lower(): g["name"] for g in state["groups"]}
    owners, filed = [], set()
    for folder in window["folders"]:
        owners.append(folder["name"])
        for gid in (i.lower() for i in folder["groupIDs"]):
            filed.add(gid)
            if not folder.get("collapsed") and counts.get(gid, 0) > 1:
                owners.append(names[gid])
    owners += [names[g.lower()] for g in window["groupIDs"] if g.lower() not in filed and counts.get(g.lower(), 0) > 1]
    return owners


def row(inst, name):
    """The frame of a row in the project panel: a terminal (its button), a merged project (its
    name), or a folder or a project of several terminals (its arrow, widened to the row)."""
    win = inst.window()
    panel = [e for e in inst.ax() if e["x"] < win["x"] + 320 and e["w"] > 0 and e["h"] > 0]
    for e in panel:
        # A terminal row: one element whose label is "state, name, path".
        if f", {name}," in (e["desc"] or e["title"]):
            return e
    for e in panel:
        if e["role"] == "AXStaticText" and e["value"] == name:
            return e
    arrows = sorted((e for e in panel if e["role"] == "AXDisclosureTriangle"), key=lambda e: e["y"])
    owners = arrow_owners(inst)
    if name in owners and owners.index(name) < len(arrows):
        a = arrows[owners.index(name)]
        return {"x": a["x"] + 20, "y": a["y"] - 4, "w": 120, "h": a["h"] + 8, "arrow": True}
    raise Disturbed(f"no row '{name}' in the project panel")


def drag(inst, source, target, where="middle"):
    """Drag the row `source` onto the row `target`: its upper edge, its middle, or its lower part."""
    s, t = row(inst, source), row(inst, target)
    sx, sy = center(s)
    tx, ty = center(t)
    # An arrow row's frame is only an estimate around its arrow: its upper half is a little
    # above the arrow's middle, not at the estimate's edge (which may be the row above).
    upper = ty - 4 if t.get("arrow") else t["y"] + 2
    ty = {"upper": upper, "middle": ty, "lower": t["y"] + t["h"] + 6}[where]
    inst.drag_hover(sx, sy, tx, ty, 700, lambda: None)
    time.sleep(1.0)


def scenario(inst):
    inst.window()
    # 1. a project into another folder
    drag(inst, "one", "Beta")
    f = folders(inst)
    check("a project moves into another folder (dropped on its row)", P["one"] in f["Beta"] and P["one"] not in f["Alpha"], f)
    inst.shot("1-into-folder")

    # 2. a project from one folder next to a project in another
    drag(inst, "three", "two", "lower")
    f = folders(inst)
    check("a project lands next to a project of another folder", f["Alpha"][-1] == P["three"] and P["three"] not in f["Beta"], f)

    # 3. a terminal into another project
    drag(inst, "t-two-b", "four")
    four = wait_for(lambda: (s := project_terminals(inst, "four")) and T["t-two-b"].upper() in s and s, 6)
    check("a terminal moves into another project", four and four[-1] == T["t-two-b"].upper(), four)
    two = project_terminals(inst, "two")
    check("its old project keeps the rest", two == [T["t-two-a"].upper()], two)
    inst.shot("3-terminal-moved")

    # 4. a terminal to another place in its project
    drag(inst, "t-four-c", "t-four-a", "upper")
    order = wait_for(lambda: (s := project_terminals(inst, "four")) and s[0] == T["t-four-c"].upper() and s, 6)
    check("a terminal moves above another terminal of its project",
          order == [T[t].upper() for t in ["t-four-c", "t-four-a", "t-four-b", "t-two-b"]], project_terminals(inst, "four"))

    # 5. a folder above another folder
    drag(inst, "Beta", "Alpha", "upper")
    check("a folder moves above another folder", folder_order(inst) == ["Beta", "Alpha"], folder_order(inst))
    inst.shot("5-folders")

    # 6. a project dropped on a terminal types nothing
    win = inst.window()
    s = row(inst, "one")
    inst.drag_hover(*center(s), win["x"] + win["w"] // 2, win["y"] + win["h"] // 2, 700, lambda: None)
    time.sleep(1.5)
    screen = inst.api({"planchette_request": "session.read", "lines": 40,
                       "id": project_terminals(inst, "four")[0]})["result"]["text"]
    check("a project dropped on a terminal types nothing into it",
          "planchette" not in screen.lower() and P["one"] not in screen.lower(), screen[-200:])


def main():
    binary = os.path.abspath(sys.argv[1])
    base = scratch_root(sys.argv[2])
    files = UserFilesGuard()
    for attempt in range(3):
        RESULTS.clear()
        wait_until_idle(20, 1800)
        root = scratch_root(os.path.join(base, f"run-{attempt}"))
        inst = Instance(binary, root)
        inst.edit_state = seed(root)
        try:
            inst.start()
            scenario(inst)
        except Disturbed as why:
            print(f"[sidebar_drag] disturbed: {why}", flush=True)
            inst.disturbed = True
        finally:
            inst.stop()
        if not inst.disturbed:
            break
        print("[sidebar_drag] somebody used the machine: once more", flush=True)
    files.report("sidebar_drag")
    failed = [name for name, ok in RESULTS if not ok]
    print(f"[sidebar_drag] {'all checks passed' if RESULTS and not failed else 'FAILED: ' + ', '.join(failed) or 'no result'}")
    sys.exit(1 if failed or not RESULTS else 0)


if __name__ == "__main__":
    main()
