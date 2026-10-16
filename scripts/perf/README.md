# Measurement scripts

Scripts that **measure the running app** instead of reading its code. They found the bugs behind
the review of October 2026: a dialog that froze every terminal, terminals that stayed dead when
the screens were asleep, and `session.prompt` that never submitted in zsh or Claude Code. A unit
test cannot see any of these, because each one lives in how AppKit, libghostty and the OS behave
together.

They are run by hand, not in CI. They need macOS, Python 3 and Xcode's command-line tools, and
nothing else: standard library only (no new dependency, AGENTS.md rule 1).

## Safety — read this first

1. **Every script runs an isolated instance** (`PLANCHETTE_STATE_DIR=<scratch>/state`) and talks
   to that instance's own socket. They never kill anything by name, only the process they
   started, and they never go near the instance you work in.
2. **`$HOME` does not isolate an instance.** An old build deployed its CLI to the real
   `~/.planchette/planchette` when it started. A build from before the fix "deploy only from a
   packaged `.app`" does that from its build folder too: the file system ignores case, so
   `<build folder>/planchette` *is* the executable `Planchette`, and the build copies itself over
   your CLI (27 MB of binary where agents expect a script). Do not start such a build. Every
   script checks six files in your home folder before and after a run (`perf_common.py`,
   `UserFilesGuard`) and prints a warning with the restore command when one changed.
3. **The instance opens a window and activates itself**, which takes the keyboard from whoever is
   working. `FocusGuard` hands the focus back within about 0.15 s. It needs the Accessibility
   permission for your terminal; without it the guard does nothing.
4. **A terminal needs an awake display** (libghostty cannot start one otherwise). Run GUI
   measurements through `with_displays.sh`: it keeps the displays on and puts them to sleep
   again afterwards, but only when nobody touched the keyboard or mouse for 60 s.
5. **Pass a scratch folder made for the run** (for example `/tmp/plt-run-1`). Scripts stop their
   helper processes by matching that folder on the command line; `scratch_root` refuses a folder
   that is too short, your home folder, or the repository.
6. **Never stress the machine at normal priority.** An earlier run with busy processes at normal
   priority pushed the load average past 200, and the old app's pollers started over 100 `git`
   processes. `slow_machine.sh` keeps the load on the efficiency cores and has a watchdog.

7. **Never script or read a process through System Events without checking which one it means.**
   Asked about a pid it has not registered yet, `first process whose unix id is N` does not fail: it
   answered with the installed Planchette (`build.planchette.app`) once, and the isolated instance
   was a different process. Use `system_events_process(pid)` from `perf_common.py`, which waits
   until the process it names reports that pid, and take pictures with `screencapture -l <window
   id>` of the pid's own windows (`tools/windows.swift`) instead of reading the interface tree.

## Quick start

```sh
cd macos/Planchette && swift build
../../scripts/perf/with_displays.sh 600 \
  python3 ../../scripts/perf/harness.py mine .build/debug/Planchette /tmp/plt-run-1
```

The scripts set `GHOSTTY_RESOURCES_DIR` themselves (`vendor/ghostty/zig-out/share/ghostty`).

Compare two builds by running the same script on each, back to back, in the same session.
Build the older one in a separate checkout and **start it only with a build that has the
deploy fix, or after copying `~/.planchette/planchette` somewhere safe** (rule 2).

## The scripts

| Script | The question | Display | Takes |
|---|---|---|---|
| `harness.py` | One report for one build: hook latency, connection limits, an OSC 52 clipboard read, title storms (CPU and autosave), branch polling and how many `git` processes the app starts. | awake | ~3 min |
| `dialog_freeze.py` | Do terminals and the control API keep working while the update dialog is open? (`autoUpdateCheck` 1 shows the dialog; 0 is the control run.) | awake, network | 45 s |
| `menu_dialog.py` | The same for dialogs a menu opens (`ai-menu`, `quit-menu`). Clicks the real menu bar with System Events, addressed by pid. | awake, Accessibility | 20 s |
| `session_wait.py` | Does a `session.wait` whose caller closed release its connection? Does a half-closed client still get its answer? | not needed | 20 s |
| `dark_display.sh` | Does a terminal that could not start, because every display was asleep, start when a display wakes? | **asleep** at the start | 40 s |
| `prompt_submit.py` | Does `session.prompt` submit in `zsh`, `bash` (3.2) and the real Claude Code? Claude Code runs against `stub_api.py`, a local stand-in for the API, so no login and no cost; `battery` runs repeated, multi-line, special-character and concurrent prompts. The stub can also answer with a tool call (`BGSHELL<n>`, `BGAGENT<n>`), so real background work starts without a model. `SLOW<n>`, `STREAM<n>` and `ASKPERM<n>` hold a turn, stall a half-printed answer and open a permission dialog. | awake | 10 s – 5 min |
| `background_tasks.py` | Does Planchette notice the shells and the agent the real Claude Code runs in the background, count them as they start and say nothing once they ended? Claude Code runs against `stub_api.py`; the hooks come through the repository's own hook script. | awake | ~3 min |
| `state_sync.py` | Does the state icon follow what really happens? A command that asks a question and ends, one aborted with Ctrl+C, one that fails; and the real Claude Code, aborted with Ctrl+C before and during an answer, with Esc at a permission dialog, and killed; a permission granted while the tool (Bash, or an MCP call to `mcp_probe.py`) goes on for 25 s; a shell left running in the background after the turn. Twelve scenarios, each in its own instance. | awake | ~12 min |
| `tab_split.py` | Do tabs, splits and their drag and drop work? Real mouse presses, drags and key presses (`tools/inputs`), elements found by their accessibility frames (`tools/axtree`), the outcome checked in `state.json`: a tab onto a pane's edge, a pane out to the bar, onto a tab, every button and ⌘D, clicking into a pane, closing, a restart, state from before splits, refused drops, and a seeded random walk of 28 drags and clicks that checks the saved project after every one. Moves the pointer and takes the keyboard: do not use the machine. Needs the Accessibility permission. | awake, Accessibility | ~6 min |
| `screenshots.py` | Not a measurement: the pictures in `docs/images`. A made-up workspace in an isolated instance wrapped as a throwaway `.app` (the real icon), brought to life through the control API and hook events, captured window by window: overview, folder page, cluster, search, welcome, Settings → Tabs and the update dialog (the real one — it asks GitHub). The window is seeded to 1440 × 900 on the biggest display. | awake, network for `update` | ~3 min |
| `typed_after_flood.py` | Can a typed command be lost after a flood of connections and a pending clipboard dialog? | awake | ~4 min / 25 rounds |
| `slow_machine.sh` | Does the unit-test suite pass on a slow machine? | not needed | 4–10 min |
| `slow-git/git` | A shim, first on `PATH`: makes `git commit` (or another subcommand) slow, so a deadline fires with no load at all. | not needed | — |
| `tools/*.swift` | Helpers, compiled on first use into `$TMPDIR/planchette-perf-tools`: `windows` lists a process's on-screen windows, `displays` counts the active displays, `screens` prints each display's visible frame. | — | — |

## What they found (October 2026, one run each — read the sizes, not the decimals)

| Measure | Before | After |
|---|---|---|
| Loop iterations in 21 s with the update dialog open | 144, then none; the API never answered | about 15 per second; the API answered 40 of 40 probes |
| Terminal after the displays woke | none in 24 s, ever | running after 4.2 s |
| `session.prompt` in Claude Code 2.1.299 | 0 of 1 submitted | 125 of 125 |
| Clipboard bytes an OSC 52 probe could read | 141 | 0 |
| Connection kept after a `session.wait` caller closed | until the timeout (up to 3600 s) | released in 0.7 s |
| CPU in 5 s of a title spinner | 1.66 s | 0.22 s |
| First autosave in a 14 s title storm | 13.3 s | 9.1 s |
| `git` processes started by the app in 32 s idle | 3 | 0 |
| Unit tests that fail when `git commit` takes 16 s | 18 | 0 |

## Writing a new one

- Isolate: a scratch folder through `scratch_root`, `PLANCHETTE_STATE_DIR`, the instance's own
  socket from `<state>/socket`. Stop only the process you started.
- Start `UserFilesGuard()` and `FocusGuard()` before launching the instance, and call
  `report()` / `stop()` in the `finally` block.
- Measure what a person or an agent sees (a file that keeps growing, an answer on the socket,
  a line on the screen), and say in the output what a pass and a failure look like.
- A run that fails to reproduce a problem is a result. Write down how many times you ran it.
