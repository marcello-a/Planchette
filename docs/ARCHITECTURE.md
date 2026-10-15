# Architecture

How Planchette is put together. Pair this with [../AGENTS.md](../AGENTS.md)
(contributor rules) and [CONCEPT.md](CONCEPT.md) (product vision & roadmap).

## Overview

Planchette is a native SwiftUI/AppKit macOS app that embeds the Ghostty
terminal engine (`libghostty`, via the self-built `GhosttyKit.xcframework`) and
adds a project/attention layer on top. There is no Electron, no server, and no
external runtime dependency beyond Apple frameworks and the user's `claude` CLI.

```
┌────────────────────────────────────────────────────────────┐
│ SwiftUI views (Sidebar, TerminalArea, Inbox, QuickSwitcher) │
│                     observe ▼                                │
│                 AppState  (@MainActor, single source)       │
│   ┌───────────────┬──────────────┬───────────────────────┐  │
│   │ TerminalRegistry│ HookServer  │ AIAssist / Update /   │  │
│   │ (NSView PTYs) │ (unix socket) │ Migration / Notif.    │  │
│   └───────┬───────┴──────┬───────┴───────────────────────┘  │
│           ▼              ▼                                    │
│      libghostty     planchette-hook ◄── Claude Code hooks    │
│      (GhosttyKit)   (settings.json)                          │
└────────────────────────────────────────────────────────────┘
                    ▲ persisted to ▼
        ~/Library/Application Support/Planchette/state.json
```

## State & persistence

`AppState` is the only mutable source of truth (`@MainActor`, `ObservableObject`).
Views read from it and mutate through its methods; every mutation calls
`scheduleSave()` (1s debounce) which writes `PersistedState` to
`state.json` atomically.

`PersistedState` (in `Models.swift`) is `Codable` with **hand-written,
backward-compatible decoding**: every field added after v1 uses
`decodeIfPresent … ?? default`, so an older `state.json` still loads. When you
add a persisted field, wire it through all five spots listed in AGENTS.md rule 4.

Restore is deliberate (a launch dialog: *Restore* vs *Start fresh*). "Start
fresh" archives the previous state to `state-previous.json` instead of deleting
it. Processes can't survive a reboot, so restore re-creates terminals in their
saved `cwd`, resumes Claude via `claude --resume <id>`, and re-runs an optional
per-session startup command.

**Presets live outside `state.json`** (`presets.json`, `Presets.swift`). That
separation is the feature: "Start fresh" throws the workspace away, and the
saved arrangements have to still be there afterwards — the welcome screen offers
them as the way back. A preset is a template, not a snapshot: projects, folders,
terminals (cwd, title, color, tags, startup command) and the cluster splits,
addressed by terminal *index* since session ids are minted fresh on every open.
It deliberately carries no Claude conversation id — opening one twice must not
put two terminals on the same conversation.

## Windows

Multi-window: each `WindowModel` owns a set of group IDs and its own selection.
The main window has a stable UUID (`AppState.mainWindowID`) matching SwiftUI's
default `WindowGroup` value; secondary windows get fresh UUIDs.
`sanitizeWindows()` keeps the invariant "every group lives in exactly one
window" and guarantees a main window exists. Groups can move to a new window or
merge back; `WindowRegistry` maps window IDs to their `NSWindow` for raising and
key-window lookup.

A window also owns its **project folders** (`WindowModel.folders`): named,
collapsible boxes over its projects in the sidebar, each owning the order of the
projects inside it. Per window on purpose — the sidebar is a per-window view, so
moving a project to another window means putting it somewhere else.
`sanitizeFolders()` (called from `sanitizeWindows`) keeps a folder from naming a
project that left the window or already sits in another folder.

## Terminal surfaces

Each terminal is a `GhosttySurfaceView` (an `NSView`) wrapping one libghostty
surface + PTY, created with `PLANCHETTE_SESSION=<uuid>` in its environment.
`TerminalRegistry` (a `@MainActor` singleton) owns these views by session ID so
they survive SwiftUI re-layout (tab switches, view-mode changes, window
moves) — the running shell is never restarted by UI churn. `GhosttyRuntime`
holds the single `ghostty_app_t` and dispatches C-API callbacks
(title, pwd, clipboard) back onto the main actor via `NotificationCenter`.

**A surface needs an awake display.** libghostty's renderer creates a display link
(`CVDisplayLinkCreateWithActiveCGDisplays`), which fails with zero active displays —
a Mac whose screens are asleep — and `ghostty_surface_new` then returns nil (the
library reports `error.OutOfMemory`). That happens when the app launches at login
before the screen is up, and when an agent opens a terminal overnight through the
control API. The view used to log it and stay dead for good. `createSurface()` can be
repeated — the renderer is created *before* the terminal's process, so a failed
attempt starts nothing — and a terminal with no surface checks every 2 s whether a
display is awake (`CGGetActiveDisplayList`, which costs next to nothing, so it can wait
all night) and builds the surface when one is. The system's own wake notifications
(`screensDidWake`, `didChangeScreenParameters`) were not delivered when measured, so
nothing depends on them. If a display is awake and the attempt still fails,
`SurfaceRetry` backs off (1, 2, 4, 5 s … then every 30 s, never giving up). The
control API refuses a terminal without a surface instead of dropping what is typed
into it, and `session.new` leaves no empty tab behind when it cannot start one.

## The attention state machine

The core feature. Per-session state is `working → asking → done → free`, driven
entirely by **Claude Code hooks** (no output scraping):

```
UserPromptSubmit → working
Notification / PermissionRequest → asking   (+ notification for favorites)
Stop / SubagentStop → done
SessionEnd → free
```

Flow: Claude fires a hook → `planchette-hook` reads the event JSON on stdin plus
`$PLANCHETTE_SESSION` from its environment → sends it to the unix socket
(`$PLANCHETTE_SOCKET`, per app instance: `/tmp/planchette-<pid>.sock`; a durable
terminal's environment can name a dead instance, so the hook falls back to
`~/.planchette/socket`, which the live instance publishes) →
`HookServer` decodes it and calls
`AppState.applyHookEvent`, which routes by `PLANCHETTE_SESSION` to the exact
session. The inbox, menu-bar badge, and quick switcher are all just sorted views
over these states (favorites first, `asking` before `done`, longest-waiting
first). Focusing an `asking`/`done` terminal clears it.

**What ends `running` and `waiting`.** Claude's own hooks, first (`Stop`,
`SessionEnd`, the tool events). Two things they cannot say are said by others: the
shell, with OSC 133 `D` right before its prompt (the foreground job is over — a command
that asked a question and ended, an abort with Ctrl+C, an agent that was killed), and
the screen (`claude_interrupted` and an idle prompt over a turn no hook closed — an
abort leaves no hook — each read on its own terms, the second only after two polls).
A restart ends whatever a saved state described. Everything else a screen pattern could
decide it must not: it only applies where a Claude can be.

**Background work.** A finished turn does not mean Claude is done: it may still run
shells (`run_in_background`) or agents it launched without waiting. Claude Code sends
its own list with the `Stop` hook — `background_tasks`, each with `id`, `type`
(`shell` or `subagent`), `status` and a `description`. `BackgroundTasks` turns every
hook into one signal: a snapshot (`Stop`), a start (`PostToolUse` of a background
`Bash` or an agent that answered `isAsync`), an end (a `<task-notification>` prompt) or
a reset (a Claude process begins or ends). `AppState.backgroundTasks` holds the result
per terminal, never persisted — a restart ends the processes the tasks live in. The
sidebar draws it under the state icon, and `session.get` reports the counts.

Install the hooks with `hook/install-hooks.sh` (merges into
`~/.claude/settings.json`, backs it up, and is a no-op outside Planchette
terminals).

### Snooze — the one thing that silences a terminal

A terminal or a whole project can be sent away until a moment (`Snooze.swift`:
in 1 hour, in 2 hours, the next 9:00). Snoozing sets the terminal free straight
away and stores `snoozedUntil`; while it runs, `AppState.isSnoozed` filters that
terminal out of the inbox, the counts, the dock and menu-bar badges and every
notification — including the escalation reminder. It does **not** freeze the
state machine: hooks and screen detection keep the color honest, the terminal
just stops asking for you. `checkSnoozeExpiry()` (every housekeeping tick, and
once after a restore, so a snooze that ran out while the app was closed still
speaks up) clears it and posts the reminder.

## Search

The search (`QuickSwitcherView`) works on a snapshot: `AppState.searchEntries()` copies
what is known about every terminal when the sheet opens, and the ranking runs against
that copy, so a state change while it is open cannot reorder the list under the user's
hand. The ranking is `SearchRanking.swift`, pure and unit-tested: the query is split into
words, every word has to match (AND), and each word scores by the tier it reaches in its
best field — whole word, start of a word, inside a word, initials, letters in order —
times that field's weight: the title counts three times what a summary does, the
project, PR number, branch and tags come next, then the note and the path, and the
task, summary and last message least. A `#number` matches a ticket or PR number. The best match in a field the row does
not already show becomes the hint line.

The keys that open it are `AppState.searchShortcut` (persisted; Settings → General →
Search): a modifier tapped twice, or a chord. `SearchShortcutMonitor` is a *local*
`NSEvent` monitor, because a global one needs the Accessibility permission, and the
shortcut is for the app in front. Chords are consumed; a double tap never costs the
terminal a key. What counts as a double tap is `DoubleTapDetector`, pure: a press and a
release of the modifier alone, each under 0.3 s, the second ending within 0.5 s of the
first; any key, click or scroll in between ends the attempt, and it fires on the
release, so a Shift held to select never opens it. ⌘K stays a menu item whatever Settings
says.

## AI assist (on by default, can be switched off)

Settings explains what it does and has the switch. Stage 1 is deterministic:
`AIAssist`/`TranscriptReader` parse the Claude transcript JSONL for the last
prompt/answer. Stage 2 (only while enabled) shells out to `claude -p --model
haiku` to condense a transcript tail into a one-line summary + one-word topic,
throttled per session. Stage 3 proposes grouping sessions by shared topic —
applied only after explicit confirmation.

The transcript tail is untrusted text (web pages and files the agent opened), so
the summarizer is boxed in: it runs in its own empty directory (`summarizer/` in
the support directory — a GUI app's working directory is `/`, i.e. the whole
disk), with every tool switched off (`--tools ''`; an older `claude` that does not
know the flag is run without it, once, and the directory still applies), and the
prompt tells the model to treat the material as data.

## Robustness & security

The rules the code follows so that a slow tool, a hostile peer or a bad download
cannot hurt the app. Each one has a test in `HardeningTests.swift`.

**Helper processes have a deadline.** `Subprocess.run` is the only way the app
runs `git`, `lsof`, `tmux` or `gh`: it kills the child at its deadline, never
waits on a pipe a grandchild holds open, and closes stdin. A bare `Process` +
`readDataToEndOfFile()` + `waitUntilExit()` has no upper bound, and the pollers
call it from timers — one hung `git` plus a timer is a leak that grows until the
app is starved.

**Pollers are single-flight.** Branches, pull requests, dev servers and context
usage each run in a detached task on a timer. `SingleFlight` keeps a slow run
from being joined by a copy on the next tick; a request that arrives mid-run
(a `Stop` hook asking for a fresh context reading) is remembered and gets exactly
one more run, not dropped.

**The branch is read, not asked.** `Titles.headState` reads `.git/HEAD`;
`Worktrees.currentBranch` asks git only when the file cannot answer: the reftable
layout (whose HEAD is a stub), or a `.git` entry that exists but is unusable (a
worktree whose git dir is gone — git reports an error there, and climbing on into
the repository around it would show *its* branch). The walk starts from the
*physical* path (`realpath`), as git does: a symlinked projects folder
(`~/code -> /Volumes/work/code`) never reaches its repository by way of the logical
path, and an unrelated repository on that path (a dotfiles repo in `$HOME`) must not
be consulted. A subprocess per directory every ten seconds, around the clock, was
the poll's whole cost. A dev server's working directory comes from `proc_pidinfo`,
not a second `lsof`; a scan that timed out publishes nothing, so servers do not
vanish from the sidebar because `lsof` was slow once.

**What counts as a change.** `AppState.update` drops a write that equals what is
stored, so no publish and no save. A terminal title is therefore stored without
its leading status glyph (`TerminalSession.cleanedTitle`): programs animate that
glyph, and every frame used to be a "different" title. `SaveDebounce` caps how
long the oldest unsaved change can wait — a trailing debounce alone never saves
while changes keep arriving less than a second apart.

**The socket trusts the kernel, not the file name.** `HookServer` lives in
`/tmp`. The file is 0600, and every accepted connection is also checked with
`getpeereid`; reads share one 5 s deadline and a 4 MiB cap, at most 64 connections
are *read* at once, descriptors are close-on-exec with `SO_NOSIGPIPE`. A connection
holds its slot only while its request is read: a `session.wait` is answered minutes
later, and 64 of them would otherwise leave no slot for the hook events that keep
every terminal's state true. Requests that wait for an answer are bounded on their
own (64), and a wait ends when its caller closes the connection — detected with
kqueue's `EV_EOF`, because `poll` reports a closed client and one that merely
half-closed (the protocol: "the app answers on EOF") the same way. The hook script,
the CLI and the notification click command check that the socket is owned by the
current user — and is not a symlink, which could be swapped for another listener
between the check and the connect — before they hand it anything; the CLI then asks
the kernel (`LOCAL_PEERCRED`) who is listening. An event carries the prompt you just
typed. See [API.md](API.md#limits).

**Config files are not ours to break.** `HookInstaller` writes to the *resolved*
path of `settings.json`, `hooks.json` and `config.toml`: an atomic write replaces
a symlink with a regular file, and dotfile managers keep these as links. The
backup copies the real file, not the link. A link whose target does not exist yet
(dotfiles not checked out) is followed and the target created; one into a read-only
store (home-manager, nix) fails with a message that says so and is left as it was.
`hook/install-hooks.sh` keeps the file's mode: `settings.json` can hold secrets in
`env`.

**The clipboard asks.** libghostty's protections — confirm before a program reads
the clipboard (OSC 52), confirm before an unsafe paste, and, with
`clipboard-write = ask`, before a program writes it — end in
`confirm_read_clipboard_cb` / `write_clipboard_cb(confirm: true)`. They used to be
answered "yes" (the write's flag was ignored). `ClipboardConfirmation` asks instead.
The dialog is **only ever a sheet on the window of the terminal that asked**: a
terminal in a background tab or a hidden app has no window the user could connect to
the question, so a request a program started there is refused quietly (and that
terminal is quiet for 30 s). One sheet per window — `Gate` — and a program that was
refused is not asked again for 30 s. The safe button is the default and first; the
preview shows what a paste hides: control characters, bidirectional overrides,
zero-width and separator characters appear as `␛` / `⟨U+202E⟩`. Denying completes the
request with an empty string (never leave it open: `state` is owed a completion),
except a denied *write*, which must not complete at all — completing writes the
string, and `""` would clear the clipboard.

**A dialog never stops the app.** `NSAlert.runModal()` spins a nested run loop. Started
from inside a block the main *dispatch queue* is running — every `await`
continuation on the main actor, every `DispatchQueue.main.async` — that loop does not
run the queue's other blocks. libghostty's wake-up (`GhosttyRuntime.tick`), hook
events and control-API replies are such blocks: with the update dialog left open, no
terminal's output was processed, the library's mailbox filled, the IO threads blocked
and the agents behind them stopped on their next write (measured: a loop in a terminal
ran about 140 iterations and stood still; the control API never answered). A timer or
a run-loop source does not have the problem, so `ModalAlert` runs the alert from a
`CFRunLoopPerformBlock` callout and the caller awaits it. Every alert that can appear
from async code goes through it; clipboard dialogs are sheets and need nothing.

**Links that would run something are revealed, not opened.** `GhosttyRuntime.action`
sends a ⌘-clicked `file:` link to Finder when opening it would launch an app, a
`.command` script or anything executable. The decision is made on the *resolved*
target (`realpath`, Finder aliases), checking the extension of the link and of what
it points to, and the content type; document packages (`.xcodeproj`, `.rtfd`) are
folders for this purpose and open. What is opened is the resolved target, so the
file that was judged is the file that is opened.

**tmux not answering is not "nothing is running".** A durable terminal's agent outlives
the app; a restore replays scrollback or `claude --resume` only into a session tmux
reports as gone. `Durable.listSessions()` returns `nil` when tmux did not answer in
time, and `liveIDsForRestore` then assumes every durable session is alive — replaying
into a live TUI would `cat` a stale snapshot over it and start a second agent.

## Packaging & updates

`scripts/package.sh` builds a release binary, assembles `Planchette.app`
(Info.plist, icon, bundled Ghostty resources, ad-hoc codesign) and a `.dmg`.
`scripts/release.sh X.Y.Z` tags `vX.Y.Z` on the default branch and publishes a
GitHub Release with the DMG. `UpdateService` polls `/releases/latest`, compares
the tag to the running `CFBundleShortVersionString` with `Semver`, and offers
the download — so "new stable version on the default branch → offered as update"
is the whole loop. No Sparkle, no appcast server.

What stands between a release and the running app: redirects must stay on
GitHub's hosts over HTTPS, the download must answer 200 and stay under 250 MB, and
the in-app install needs the release's `SHA256SUMS` (a release without one takes
the manual DMG path). The zip is hashed in chunks and unpacked off the main thread
— a main-thread `ditto` froze the window, spinner included. Before anything is
swapped, `UpdateService.verifyBundle` requires the same bundle identifier, a version
equal to the release tag and newer than the running app (no rollback, no update
that offers itself again), and a passing `codesign --verify --deep --strict`.
The app is ad-hoc signed, so that last check proves the bundle is complete and
unmodified, not who signed it; a Developer ID signature (and notarization) would turn it into
proof of origin, and is the one hardening here that needs an account rather than
code. Every file the
updater puts in the temp folder is removed again, in every outcome; leftovers from
older versions are swept at launch. The swap helper only ever receives a directory
that Swift has checked is an extraction of ours (`cleanupDirectory(forStagedBundle:)`:
the path is resolved first — so a symlink cannot aim the cleanup elsewhere — and must
be `<temp>/planchette-update-<id>/<name>.app`), and repeats the name check itself;
whatever fails, the installed app stays in place.

## Platform note

macOS is implemented. A Linux frontend (Zig + GTK4 against libghostty) is
planned but gated on libghostty's embedding API stabilizing; the pure-logic core
(state machine, persistence model, hook protocol) is portable.
