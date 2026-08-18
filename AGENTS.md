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
| `Durable.swift` | tmux-backed terminals: agents that outlive the app (attach, reap, kill) |
| `Presets.swift` | Saved arrangements (`presets.json`) — a template of folders/projects/terminals, deliberately outside `state.json` |
| `Help.swift` | The Help tab's catalogue: every feature, as `LKey` references to the controls' own strings (ground rule 5) |
| `Semver.swift`, `Titles.swift`, `Shell.swift`, `Drop.swift`, `Snooze.swift` | Pure helpers (unit-tested) |
| `Localization.swift` | `LKey`, `L10n`, 7 language tables, `AppLanguage`, `AppAppearance` |
| `Views/` | `SidebarView` (+ bottom bar), `TerminalAreaView`, `FolderOverviewView` (a folder's page), `InboxView`, `QuickSwitcherView`, `TagViews`, `HelpView`, `StateIcon` (pixel sprites) |

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
  that is talking to us.
- **Three hook events do not mean what their names suggest.** `SubagentStop`
  fires while the main agent keeps working, so it must not report a finished
  turn; `PreToolUse`/`PostToolUse` are installed only because granting a
  permission fires no event of its own, and a tool call is the sole proof that an
  answered terminal has stopped asking; and `Notification` is *also* Claude
  Code's "you left me hanging" nudge after a minute of idling, which is not a
  question and must not turn a terminal blue. All three decisions live in
  `AttentionState.forHookEvent`, with a table test in `LogicTests`.
- **A parked project is filtered exactly like a snoozed one.** `AppState.isMuted`
  is THE filter for anything that counts or announces attention — badge, dock
  count, banner, inbox, notifications panel — and it covers both reasons a
  terminal is silent: a snooze (its own or its project's) and
  `SessionGroup.active == false`. `isSnoozed` alone is only for the snooze
  *badge* and the expiry reminder. A new counter that reaches for `isSnoozed`
  starts shouting from a project the user parked.
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
  packaged app, captured by window id.
- **A snoozed terminal is filtered, not frozen.** `AppState.isSnoozed` keeps it
  out of the inbox, the counts, the badges and every notification, while hooks
  and screen detection keep updating its actual state. Any new place that counts
  or announces attention has to apply the same filter, or a terminal the user
  sent away starts shouting from a corner nobody thought about.
- **Never assume `$PLANCHETTE_SOCKET` is live.** A durable terminal's environment
  is frozen at the moment its tmux session was created, so it names the socket of
  an app instance that may be long dead. Anything talking to us from inside a
  terminal (hook, CLI, click command) must fall back to `~/.planchette/socket`,
  which the running instance publishes.

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

## Commit conventions

Conventional-commit style (`feat:`, `fix:`, `chore:`, `docs:`), imperative,
with a short body explaining *why*. End with:

```
Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
```
