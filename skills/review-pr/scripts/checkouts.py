#!/usr/bin/env python3
"""Rank the local checkouts of a GitHub repo for a PR review.

Usage: checkouts.py <owner/repo> [--root <folder>] [--depth 3]

Candidates: the checkouts Planchette's terminals are in (and their worktrees), or, with
--root, every checkout of the repo up to --depth folders below it.

Prints JSON: a list of checkouts, free ones first (best first), each with the
reasons it is busy. The same rules as Planchette's Reviews panel:

  busy  - a Planchette terminal in that path is running, waiting or has an error,
          or Claude still runs a shell or an agent in its background
        - a finished result there is not read yet
        - an agent session is open there on a work branch (a review would switch
          the branch under it)
        - uncommitted changes
        - a dev server listens from that path
  free  - everything else; ranked: trunk or merged branch first, then the
          checkout with the oldest last activity (so the one you used an hour
          ago is not taken)

Read-only: it runs git, lsof and the planchette CLI, and changes nothing.
"""
import json
import os
import re
import subprocess
import sys
import time

TRUNKS = {"master", "main", "develop", "trunk"}


def run(args, cwd=None, timeout=15):
    try:
        out = subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return out.stdout if out.returncode == 0 else None


def repo_slug(url):
    # git@github.com:owner/repo.git, https://github.com/owner/repo(.git)
    m = re.search(r"github\.com[:/]([^/]+/[^/]+?)(?:\.git)?/?$", url.strip())
    return m.group(1).lower() if m else None


def toplevel(path):
    out = run(["git", "rev-parse", "--show-toplevel"], cwd=path)
    return os.path.realpath(out.strip()) if out else None


def planchette_checkouts(slug, sessions):
    """The checkouts Planchette's terminals are in, plus every worktree of those repos."""
    found = set()
    for root in {t for t in (toplevel(s.get("path", "")) for s in sessions if s.get("path")) if t}:
        url = run(["git", "remote", "get-url", "origin"], cwd=root)
        if not url or repo_slug(url) != slug:
            continue
        found.add(root)
        listing = run(["git", "worktree", "list", "--porcelain"], cwd=root) or ""
        found.update(os.path.realpath(line[9:]) for line in listing.splitlines()
                     if line.startswith("worktree ") and os.path.isdir(line[9:]))
    return sorted(found)


def find_checkouts(root, depth, slug):
    found = []
    root = os.path.expanduser(root)
    base_depth = root.rstrip("/").count("/")
    for dirpath, dirnames, filenames in os.walk(root):
        if dirpath.count("/") - base_depth >= depth:
            dirnames[:] = []
        dirnames[:] = [d for d in dirnames if d not in ("node_modules", ".git", ".build", "dist")]
        if ".git" in filenames or os.path.isdir(os.path.join(dirpath, ".git")):
            url = run(["git", "remote", "get-url", "origin"], cwd=dirpath)
            if url and repo_slug(url) == slug:
                found.append(os.path.realpath(dirpath))
            dirnames[:] = [d for d in dirnames if d.endswith(".worktrees")]
    return found


def planchette_sessions():
    cli = os.environ.get("PLANCHETTE_CLI") or os.path.expanduser("~/.planchette/planchette")
    if not os.access(cli, os.X_OK):
        return []
    out = run([cli, "session", "list"])
    if not out:
        return []
    try:
        return json.loads(out)["result"]["sessions"]
    except (ValueError, KeyError):
        return []


def dev_server_dirs():
    out = run(["lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-Fp"])
    if not out:
        return []
    pids = sorted({line[1:] for line in out.splitlines() if line.startswith("p")})
    if not pids:
        return []
    out = run(["lsof", "-a", "-d", "cwd", "-p", ",".join(pids), "-Fn"]) or ""
    return [os.path.realpath(line[1:]) for line in out.splitlines() if line.startswith("n/")]


def inside(path, checkout):
    path = os.path.realpath(path)
    return path == checkout or path.startswith(checkout + "/")


def describe(checkout, sessions, servers):
    busy = []
    branch = (run(["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd=checkout) or "").strip()
    for s in sessions:
        if not inside(s.get("path", ""), checkout):
            continue
        # turn_state is present only when the terminal shows "running" because of
        # background work: then the turn itself is over, and the background is the reason.
        state = s.get("turn_state") or s.get("state")
        if state in ("running", "waiting", "error"):
            task = (s.get("task") or "").strip().splitlines()
            what = f" ({task[0][:40]})" if task else ""
            busy.append({"running": "Claude is running", "waiting": "a terminal waits for an answer",
                         "error": "a terminal has an error"}[state] + what)
        bg = s.get("background_tasks") or {}
        if (bg.get("shells") or 0) + (bg.get("agents") or 0) > 0 and state not in ("running",):
            busy.append("background task running")
        if s.get("state") == "ready" and not s.get("seen", True):
            busy.append("a result is not read yet")
        if s.get("agent") not in (None, "none") and state not in ("running",) \
                and branch not in TRUNKS and branch != "HEAD":
            busy.append(f"Claude is open on {branch}")
    status = run(["git", "status", "--porcelain"], cwd=checkout)
    if status is None:
        busy.append("git status failed")
    elif status.strip():
        n = len(status.strip().splitlines())
        busy.append(f"{n} uncommitted change{'s' if n != 1 else ''}")
    if any(inside(d, checkout) for d in servers):
        busy.append("dev server running")

    merged = branch in TRUNKS or branch == "HEAD"
    if not merged and branch:
        default = (run(["git", "symbolic-ref", "--short", "refs/remotes/origin/HEAD"], cwd=checkout) or "origin/master").strip()
        merged = run(["git", "merge-base", "--is-ancestor", "HEAD", default], cwd=checkout) is not None
        if not merged:
            merged = run(["git", "rev-parse", "--verify", "--quiet", "@{u}"], cwd=checkout) is None \
                and run(["git", "config", f"branch.{branch}.merge"], cwd=checkout) is not None
    stamp = (run(["git", "log", "-g", "-1", "--format=%ct", "HEAD"], cwd=checkout) or "").strip()
    try:
        last = int(stamp)
    except ValueError:
        index = (run(["git", "rev-parse", "--git-path", "index"], cwd=checkout) or "").strip()
        index = os.path.join(checkout, index) if index else ""
        last = int(os.path.getmtime(index)) if os.path.exists(index) else 0
    return {
        "path": checkout,
        "name": os.path.basename(checkout),
        "branch": branch,
        "trunkOrMerged": merged,
        "lastActivity": last,
        "lastActivityDaysAgo": round((time.time() - last) / 86400, 1) if last else None,
        "free": not busy,
        "busyReasons": busy,
    }


def main():
    args = sys.argv[1:]
    if not args or args[0].startswith("-"):
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    slug = args[0].lower()
    depth = int(args[args.index("--depth") + 1]) if "--depth" in args else 3
    sessions = planchette_sessions()
    servers = dev_server_dirs()
    if "--root" in args:
        checkouts = find_checkouts(args[args.index("--root") + 1], depth, slug)
    else:
        checkouts = planchette_checkouts(slug, sessions)
    rows = [describe(c, sessions, servers) for c in checkouts]
    rows.sort(key=lambda r: (not r["free"], not r["trunkOrMerged"], r["lastActivity"]))
    print(json.dumps(rows, indent=2))


if __name__ == "__main__":
    main()
