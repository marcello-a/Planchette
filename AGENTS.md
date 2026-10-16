# AGENTS.md — guide for AI contributors

This file orients an AI (or a new engineer) working in Planchette. Read it
before making changes. It complements [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
(how the code is structured) and [CONTRIBUTING.md](CONTRIBUTING.md) (how to
build, test, release).

## What Planchette is

A native macOS terminal IDE for running many AI coding agents at once, built on
the Ghostty engine (libghostty). It shows which session needs attention
(asking / done / free), keeps layouts persistent across restart & reboot, and
groups terminals by project. See [README.md](README.md) and
[docs/CONCEPT.md](docs/CONCEPT.md).

## Ground rules

1. **No new external dependencies without asking.** The app deliberately links
   only Apple frameworks + our self-built `GhosttyKit`. The updater uses the
   GitHub REST API directly instead of Sparkle; AI summaries shell out to the
   user's existing `claude` CLI instead of an SDK. Keep it that way unless the
   user explicitly approves a dependency.
2. **libghostty is pinned.** `vendor/ghostty` is a submodule fixed to a tag
   (currently v1.3.1). Its embedding API is not stable across versions — do not
   bump it casually; a bump is its own reviewed change.
3. **Everything user-facing is localized.** Never hardcode a display string.
   Add an `LKey` case and a value in **all** language tables in
   `Localization.swift` (EN is the required fallback — a test enforces it).
4. **State changes go through `AppState`** and must be persisted. If you add a
   persisted field, update `PersistedState` (both `init`s), `saveNow`,
   `applyRestore`, `startFresh`, and `AppState.init`'s early load.
5. **A user-facing feature is not done until it is in the Help tab.** Every
   feature the user can reach appears in `Help.sections` (`Help.swift`), which
   is what the searchable Help tab in Settings renders. Add the entry in the
   same change as the feature, reusing the `LKey`s you already added for the
   control itself — the catalogue deliberately holds *keys*, not its own copy of
   the text, so help cannot drift from the UI. A test walks every entry and
   fails on an untranslated key. If a feature has no tooltip worth listing, that
   is a sign the control needs one, not that the feature skips the catalogue.
6. **Keep the main thread free.** Subprocess/network work (`claude -p`,
   AppleScript, `lsof`, GitHub API) runs off-main; only touch `@MainActor`
   state after awaiting back.
7. **Verify by driving the app, not just building.** See "Verifying" below.

## Where things live (`macos/Planchette/Sources/Planchette/`)

| File | Responsibility |
|------|----------------|
| `PlanchetteApp.swift` | App entry, `AppDelegate`, windows/menus/toolbar, Settings, restore dialog |
| `AppState.swift` | Single source of truth (`@MainActor`): sessions, groups, windows, attention, persistence, import |
| `Models.swift` | `TerminalSession`, `SessionGroup`, `WindowModel`, `PersistedState` (all `Codable`, backward-compatible decoding) |
| `GhosttyRuntime.swift` | libghostty app instance + C-API callbacks (title/pwd/clipboard) |
| `GhosttySurfaceView.swift` | One PTY-backed terminal surface (`NSView`); `TerminalRegistry` keeps surfaces alive across SwiftUI re-attaches |
| `HookServer.swift` | Unix-socket server receiving Claude Code hook events |
| `AIAssist.swift` | Transcript parsing + `claude -p` summarization (opt-in) |
| `MigrationService.swift` | Import cwds from iTerm2/Terminal.app (AppleScript → `lsof`) |
| `UpdateService.swift` | GitHub-releases update check |
| `NotificationService.swift` | `UserNotifications` wrapper |
| `ScreenDetection.swift` | Screen-based state detection (rules as data) + hook/screen arbitration |
| `BackgroundTasks.swift` | The shells and agents Claude Code runs in the background, read off its hooks (pure, unit-tested) |
| `Durable.swift` | tmux-backed terminals: agents that outlive the app (attach, reap, kill) |
| `Presets.swift` | Saved arrangements (`presets.json`) — a template of folders/projects/terminals, deliberately outside `state.json` |
| `Help.swift` | The Help tab's catalogue: every feature, as `LKey` references to the controls' own strings (ground rule 5) |
| `Semver.swift`, `Titles.swift`, `Shell.swift`, `Drop.swift`, `Snooze.swift` | Pure helpers (unit-tested) |
| `SearchRanking.swift` | What the search matches and how it ranks it: `SearchEntry`, the tiers (whole word, start, inside, initials, letters in order), the field weights, the hint line. Pure, unit-tested |
| `SearchShortcut.swift`, `SearchShortcutMonitor.swift` | The keys that open the search (a modifier tapped twice, or a chord): the value type, the pure `DoubleTapDetector`, and the local event monitor that feeds it |
| `TerminalFind.swift` | What a terminal's find bar knows (`TerminalFind`) and says. The tmux side of the search is `Durable`'s Search extension: pure argument lists, tested |
| `ProjectColorLook.swift` | Where a project's color shows (`ProjectColorScope`: off, label, whole project) and how strong it is (`ProjectColorStrength`: colorful, subtle, faint), persisted as `PersistedState.projectColor`. The numbers behind it are `ProjectWash.strengths` in `Views/ProjectGradient.swift`. Pure, unit-tested |
| `TabLayout.swift` | What names a tab and what else it carries (`TabName`, `TabLayout`, persisted), and the order the name sources give way to each other (`TabNaming`). Pure, unit-tested |
| `Onboarding.swift` | What the app already told the user (`OnboardingState`: the welcome seen, the version that ran last, "don't show again") and when the durable terminals prompt is due. Pure, unit-tested |
| `TagList.swift` | The editable tag list and the rules for renaming or deleting a tag everywhere (`TagBook`) — pure, unit-tested |
| `Localization.swift` | `LKey`, `L10n`, 7 language tables, `AppLanguage`, `AppAppearance` |
| `Views/` | `SidebarView` (+ bottom bar), `ProjectPanelSettings` (Settings → Project panel: three pages and the tag editor), `TerminalAreaView`, `FolderOverviewView` (a folder's page), `InboxView`, `QuickSwitcherView`, `SearchShortcutSetting` (the shortcut row in Settings → General), `TabSettings` (Settings → Tabs), `TerminalFindBar` (⌘F over a terminal), `ProjectGradient` (the wash behind a project's header), `ProjectColorSettings` (Settings → General → Project color), `WheelToHorizontalScroll` (a vertical wheel scrolls the tab bar), `OnboardingViews` (the welcome screen, the durable terminals card and its prompt after an update), `ReleaseNotesView` (the update dialog's expandable list), `TagViews`, `HelpView`, `StateIcon` (pixel sprites) |

The socket API and the `planchette` CLI have their own manual:
[docs/API.md](docs/API.md). It is the contract other programs read, so a command
or a response field that changes has to change there in the same commit.

`hook/planchette-hook` is the tiny shell binary Claude Code invokes; it forwards
the event JSON (wrapped with `$PLANCHETTE_SESSION`) to the socket.

## Non-obvious things that will bite you

- **Hooks are the authority; the screen is a bounded fallback.** State
  transitions come from agent hooks routed by the `PLANCHETTE_SESSION` env var
  injected into each terminal. `ScreenDetection.swift` adds a second, weaker
  signal read off the viewport every 1.5s, and `AttentionState.fromScreen`
  decides who wins: while a full-lifecycle agent (Claude Code) is live, the
  screen may **only** escalate to `waiting` on a visible blocker — a hook can
  miss a permission prompt, the screen cannot. Without hook authority (no
  integration, or an agent that only claims its session) the screen drives every
  state. Never widen that: a scraped pattern must not be able to overrule a hook
  that is talking to us. The one other exception is a turn that ended without any
  hook, which the screen may close because no hook ever will: Claude Code fires
  none for an Esc or Ctrl+C, so the `claude_interrupted` rule ("What should Claude
  do", clipped or wrapped in a narrow pane) frees a `running`/`waiting` terminal,
  and an abort before anything was printed — the prompt text goes back into the
  input, no marker at all — is the idle prompt (`claude_idle_footer`, footer without
  "esc to interrupt") over a `running` terminal. That second reading must hold on two
  polls (`ScreenConfirmation`): a turn that has just begun shows an idle-looking
  prompt for a split second. And the rules only apply where a Claude can be: a live
  agent, or a durable terminal (`AttentionState.screenRulesApply`) — in a plain shell
  that once ran Claude, they read every program's "Do you want to continue?".
- **A finished shell command ends `running` and `waiting`.** OSC 133 `D` is printed
  right before the shell's prompt, so the foreground job is over — a question the
  screen raised, a command you aborted with Ctrl+C, and an agent that hooks still call
  live but that was killed (no `SessionEnd` comes): `commandFinished` ends that session
  and sets the state the exit code names. An agent in the foreground keeps the shell
  from printing a prompt, so there is no overlap to protect. tmux does not forward
  OSC 133 (`allow-passthrough` only carries wrapped sequences), so a durable terminal
  never hears of its commands' results. A restart ends the processes a saved
  `running`/`waiting` described: `AttentionState.afterRestart` frees them, except a
  durable agent that is still alive in tmux.
- **Three hook events do not mean what their names suggest.** `SubagentStop`
  fires while the main agent keeps working, so it must not report a finished
  turn; `PreToolUse`/`PostToolUse` are installed only because granting a
  permission fires no event of its own, and a tool call is the sole proof that an
  answered terminal has stopped asking; and `Notification` is *also* Claude
  Code's "you left me hanging" nudge after a minute of idling, which is not a
  question and must not turn a terminal blue. All three decisions live in
  `AttentionState.forHookEvent`, with a table test in `LogicTests`.
- **A permission that was granted fires no hook, so the screen ends the question.** After the
  dialog that `PermissionRequest` raised, Claude Code runs the tool and sends nothing until it is
  done — for an MCP call that can be minutes — so a terminal stayed blue ("waiting") through the
  whole call. Measured with the real `claude` against the stand-in API (`state_sync.py`,
  `claude-approved-tool` and `claude-mcp-approved`): `waiting` for all 25 s of the tool. The rule
  `claude_working` reads the footer of a live turn ("esc to interrupt"; a dialog's footer is "Esc to
  cancel"), and `AttentionState.fromScreen` lets it move **only a waiting terminal** to running, after
  two polls (`ScreenConfirmation.answered`). It never starts work from idle: that stays the hooks'.
  Waiting terminals are read on every poll tick, the quiet ones in the background included.
- **Background work keeps a terminal `running`, in one place.** `AppState.setState` turns a requested
  `ready` or `free` into `running` while `backgroundTasks[id]` is not empty (`AttentionState.settled`),
  so no writer — a hook, the screen, a finished command — can undo it; only the user's own "Mark as
  done" bypasses it. The control API talks about the *turn*: `heldByBackground` remembers the state
  that was overridden, `turnState(of:)` returns it, and the guard of `session.prompt` and
  `session.wait` use it. The icon follows the same record: `SessionStateIcon` draws the globe
  (`StatePixels.globe`) for `runsInBackground` and the robot otherwise, so a view that draws a
  session's state must use it rather than `StateIcon(state: session.state)`. Without that, a terminal with a dev server in its background could never be
  prompted without `force`, and a worker whose answer is in could never be waited for.
- **Background tasks belong to the Claude *process*, not to the conversation.**
  `BackgroundTasks` reads them off the hooks, and three facts — all observed on
  Claude Code 2.1.299, not documented — decide its rules. `/clear` ends the
  session and starts another (new id), yet the same shell is still listed
  afterwards, so a `SessionEnd`/`SessionStart` for `clear` must not reset the list
  (`startup`, `resume` and any other end do). `SubagentStop` carries
  `background_tasks` too but still lists the agent that is stopping, so only `Stop`
  is a snapshot. And a task's end reaches the hook as a `UserPromptSubmit` whose
  prompt is a `<task-notification>`: Claude's own notice, not something the user
  typed — it must never become the task line.
  `scripts/perf/background_tasks.py` re-checks all of it against the installed `claude`.
- **A durable terminal is searched in tmux, not in libghostty.** The pane sits in the
  alternate screen, so libghostty never holds a line that scrolled off it: its search
  would find only what is on screen. `AppState.startFind`/`updateFind` choose the engine
  per terminal (`searchesInTmux`). The tmux commands go to the pane as `=planchette-<id>:`
  — with the colon, or tmux answers "can't find pane" — the needle after `--` (it may
  start with `-`) and with a trailing `;` escaped, since a bare one ends the command.
  Anything new that reads terminal text has the same two cases to answer for.
- **First launch is "no state file", nothing else.** `AppState.init` sets
  `OnboardingState.firstLaunch` only when `state.json` does not exist: a file that
  fails to decode (a downgrade) is somebody's workspace and reads as seen. A message
  shown once needs a persisted answer (`onboarding`), and it is never shown in an
  isolated instance — a sheet over a demo or a test would stop whatever drives it.
- **A parked project is filtered exactly like a snoozed one.** `AppState.isMuted`
  is THE filter for anything that counts or announces attention — badge, dock
  count, banner, inbox, notifications panel — and it covers both reasons a
  terminal is silent: a snooze (its own or its project's) and
  `SessionGroup.active == false`. `isSnoozed` alone is only for the snooze
  *badge* and the expiry reminder. A new counter that reaches for `isSnoozed`
  starts shouting from a project the user parked.
- **A background on a `DisclosureGroup` is given to every row of it.** The project panel's
  open project is a group, and a `.background` on it came out as one whole gradient *per
  terminal* — a band each, restarting at every row — not one over the body. One wash over
  several rows is drawn row by row: each terminal's `.listRowBackground` paints the slice of
  the fade at its place (`ProjectWash`). Row backgrounds meet without a gap; a background
  inside the row's content does not, because the list's own row padding shows between them.
  Measured in a throwaway window, not guessed — the cheap way to check what a `List` does
  with a modifier is to render it offscreen (`NSHostingView.cacheDisplay`), not to run the app.
- **SwiftUI steals the NSView first responder** on structural updates.
  `GhosttySurfaceView.viewDidMoveToWindow` reclaims it for the active session.
  If keyboard input silently stops working, look there.
- **libghostty needs `GHOSTTY_RESOURCES_DIR`.** Dev runs set it via the env var;
  the packaged `.app` bundles the resources and `GhosttyRuntime` points at them.
- **A live terminal from another app cannot be adopted.** Each app owns its PTY;
  macOS has no reparenting API. "Migrate/import" copies the working directory
  only — never claim it mirrors the process.
- **Persistence is restore-based, no daemon.** Processes don't survive a reboot;
  Claude sessions come back via `claude --resume <id>`, dev servers via a
  per-session startup command.
- **A durable terminal must not be "restored".** With `session.durable` the shell
  runs inside tmux (`Durable.swift`), so after a restart the agent is still there
  and `TerminalRegistry` re-attaches instead of replaying anything. Adding a new
  restore step means guarding it with the same `has-session` probe — replaying
  scrollback or `claude --resume` into a live session `cat`s a stale snapshot over
  a running TUI and starts a *second* agent beside the first.
- **In a `List` row, use `draggable`/`dropDestination`, not `onDrag`/`onDrop`.**
  `.onDrag` on a row swallows the click that drives `List` selection, so the row
  can be dragged but no longer selected — and on a `DisclosureGroup`'s *label* it
  never receives the gesture at all, so it silently does nothing. Both cost a
  full app run to notice; the sidebar's project drag learned it the hard way.
- **`$HOME` does not isolate an instance — `PLANCHETTE_STATE_DIR` does.**
  `NSHomeDirectory()` and the Application Support URL come from the *user record*
  on macOS and ignore the environment, so launching a second copy with a
  redirected HOME silently opens the real `state.json` and re-attaches the live
  durable agents of the running instance. Use `PLANCHETTE_STATE_DIR=/some/dir`
  (see `SupportPaths.swift`): it moves state, scrollback, presets, the rule
  override, the tmux config and the socket pointer together, and switches the
  tmux server name so the isolated instance cannot reap the real one's sessions.
  That is how the README screenshot is taken — a seeded state dir plus the
  packaged app, captured by window id. An isolated instance does not run the hook
  installer either: it would otherwise wire `~/.claude/settings.json` from a test
  run. (And `HookInstaller` deploys only from a packaged `.app` — the file system is
  case-insensitive, so in a dev run `<build folder>/planchette` *is* the executable
  `Planchette`, which used to be copied over the installed CLI on every run.)
- **A snoozed terminal is filtered, not frozen.** `AppState.isSnoozed` keeps it
  out of the inbox, the counts, the badges and every notification, while hooks
  and screen detection keep updating its actual state. Any new place that counts
  or announces attention has to apply the same filter, or a terminal the user
  sent away starts shouting from a corner nobody thought about.
- **A terminal must not inherit the agent that started the app.** Claude Code
  marks its own processes (`CLAUDECODE`, `CLAUDE_CODE_*`, …), and a Claude that
  finds those markers set treats itself as a child session and writes **no
  transcript**. Every dev run starts the app from inside such a terminal, so
  without `AgentEnvironment.scrubInherited()` (called first in
  `applicationDidFinishLaunching`) every PTY inherits them and the context ring,
  the cache timer, the AI summary and the conversation title all go quiet at
  once — for a reason only Claude Code's own output mentions, in one line. Keep
  the list to markers of a *running* session: `ANTHROPIC_*` configures an agent
  rather than identifying one, and a terminal stripped of it cannot reach the
  API at all.
- **Never assume `$PLANCHETTE_SOCKET` is live.** A durable terminal's environment
  is frozen at the moment its tmux session was created, so it names the socket of
  an app instance that may be long dead. Anything talking to us from inside a
  terminal (hook, CLI, click command) must fall back to `~/.planchette/socket`,
  which the running instance publishes.
- **Never run a helper process without a deadline.** Use `Subprocess.run`, not a
  bare `Process` with `readDataToEndOfFile()` / `waitUntilExit()`. The pollers
  start one from a timer; a single hung `git` or `gh` then costs a thread and a
  process *per tick*, forever. `Subprocess` also stops waiting on a pipe a
  grandchild holds open, which killing the child does not close.
- **A poll that works off-main is single-flight.** Wrap it in `SingleFlight`
  (`begin()` before the detached task, `end()` when it lands, rerun if `end()`
  says so). A request that arrives mid-run must be re-run once, not dropped.
- **Equal writes must stay no-ops.** `AppState.update` publishes and saves only a
  real change, and a value that animates (a title's status glyph) has to be
  normalised *before* it is stored — see `TerminalSession.cleanedTitle`.
- **Write agent config through `HookInstaller.realLocation`.** `settings.json`,
  `hooks.json` and `config.toml` are often symlinks into a dotfiles repo, and an
  atomic write replaces the link with a regular file. Back up the resolved file,
  not the link. A link whose target is missing is followed (the target is
  created); one into a read-only store fails and stays — never "repair" it.
- **Never call `runModal()` from async or main-queue code — use `ModalAlert`.**
  A nested run loop started inside a block the main dispatch queue is running
  (every `await` continuation on the main actor, every `DispatchQueue.main.async`)
  does not run the queue's other blocks: libghostty's tick, hook events and the
  control API all stop, and the agents behind the terminals stop on their next
  write. Measured, not guessed — see the comment on `ModalAlert`. Clipboard
  questions are sheets on the asking terminal's window; never app-modal.
- **An unanswered `tmux` is not an empty `tmux`.** `Durable.listSessions()` is
  optional: `nil` means tmux did not answer in time, and restore then assumes
  every durable session is alive. Reading "no answer" as "nothing is running"
  replays scrollback and `claude --resume` into live agents.
- **Complete every libghostty clipboard request exactly once.** `state` is owed a
  completion. Denying a paste or an OSC 52 read completes with `""`; denying an
  OSC 52 *write* must not complete at all (it would write `""` over the user's
  clipboard). Never complete from inside the callback that reported the request —
  hop to the main queue first.
- **Anything that talks to the socket checks who owns it.** The socket is in
  `/tmp`; the hook, the CLI and the click command refuse a socket another user
  owns *and refuse a symlink* (it can be swapped for another listener between the
  check and the connect), the CLI also asks the kernel who is listening
  (`LOCAL_PEERCRED`), and `HookServer` checks every peer with `getpeereid`.
- **`ghostty_surface_new` fails while every display is asleep — and a view with no
  surface must come back to life.** The renderer needs a display link, and there is
  none with zero active displays. `GhosttySurfaceNSView.createSurface()` is repeatable
  and retried by the view itself; never treat `surface == nil` after `init` as final,
  never assume a surface exists in code that types into or reads a terminal (the
  control API goes through `liveView`, which refuses one without), and do not wait for
  the system's wake notifications — they did not arrive when measured. To reproduce:
  launch an isolated instance while the displays are asleep (`pmset displaysleepnow`).
- **`sendText` is a paste, not typing.** `ghostty_surface_text` pastes the text — in
  bracketed-paste markers when the program asked for that (zsh, fish and Claude Code
  do). A `\r` inside the text is a newline in it, never Enter: appending one typed the
  prompt and left it unsent. To submit, paste, wait a beat, then `pressReturn()` (a key
  press through libghostty's encoder). `session.prompt` does exactly that, one prompt at
  a time per terminal (`ControlAPI.deliverPrompt`, `KeyedSerializer`).
- **A connection's slot covers the read, not the answer.** A `session.wait` is
  answered minutes later; counting it against the connection limit lets 64 of them
  starve the hook events. Requests that wait are bounded separately, and
  `HookServer.clientHasGone` (kqueue, not `poll` — `poll` cannot tell a closed
  client from one that half-closed and waits) ends them when the caller leaves.
- **Remote or transcript text is data, never a command.** The AI summarizer runs
  in an empty directory with its tools off for exactly that reason; keep new
  subprocesses that see untrusted text on the same footing.

## Verifying a change

Building is not enough. After a non-trivial change:

```sh
cd macos/Planchette
swift test                 # pure-logic tests must stay green
swift build && GHOSTTY_RESOURCES_DIR=$PWD/../../vendor/ghostty/zig-out/share/ghostty ./.build/debug/Planchette
```

Then exercise the actual path you touched (open a terminal, trigger the hook,
switch language, etc.). The repo history shows end-to-end verification via
AppleScript UI automation for UI-affecting changes.

**Measure what unit tests cannot see.** A freeze, a dead terminal and an unsent prompt each
lived in how AppKit, libghostty and the OS behave together, and each was found by running the
app, not by reading it. `scripts/perf/` (see its README, "Safety" first) runs an isolated
instance and measures: loop iterations while a dialog is open, the control API under abuse,
a prompt in zsh and in the real Claude Code, a terminal started with the screens asleep.
Run the one that matches what you touched. `scripts/perf/screenshots.py` retakes the pictures in `docs/images` after a UI change.

**Tests must survive a slow machine.** A corporate laptop with endpoint security, or a
loaded CI runner, can start a process in seconds. Three rules keep the suite green there:

- Call git in a fixture through `fixtureGit` (`TestSupport.swift`, 300 s deadline), not
  `Worktrees.git` with its 15 s poll deadline.
- A fake server (`FakeApp`) waits for the script generously and is `stop()`ped by a test
  that expects no connection.
- Assert order, overlap and progress, never "done within 0.6 s" or "5 ms apart".

To find what breaks, slow the suite down without touching the rest of the machine: run
the busy processes and `swift test` both under `taskpolicy -b` (efficiency cores only).
A shim named `git` first on `PATH`, which sleeps before `git commit`, reproduces the
deadline failure with no load at all.

## Commit conventions

Conventional-commit style (`feat:`, `fix:`, `chore:`, `docs:`), imperative,
with a short body explaining *why*.

**The type picks the version; the PR checkbox is the switch.** A merge to `main` publishes
only when its PR ticks "Trigger new release" (off by default). Then commits that carry a
`feat:`, `fix:` or `perf:` publish a patch release; `chore:`, `docs:`, `test:`,
`style:` and `refactor:` alone do not (CONTRIBUTING.md, "Releasing"). So pick the type
for what a user sees, and put the user-facing entry under `## [Unreleased]` in
`CHANGELOG.md` in the same change — it becomes the release notes. `[skip release]` in
the head commit's message holds a release back. End with:

```
Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
```
