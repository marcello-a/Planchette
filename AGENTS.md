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
5. **Keep the main thread free.** Subprocess/network work (`claude -p`,
   AppleScript, `lsof`, GitHub API) runs off-main; only touch `@MainActor`
   state after awaiting back.
6. **Verify by driving the app, not just building.** See "Verifying" below.

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
| `Semver.swift`, `Titles.swift` | Pure helpers (unit-tested) |
| `Localization.swift` | `LKey`, `L10n`, 7 language tables, `AppLanguage`, `AppAppearance` |
| `Views/` | `SidebarView` (+ bottom bar), `TerminalAreaView`, `InboxView`, `QuickSwitcherView`, `TagViews` |

`hook/planchette-hook` is the tiny shell binary Claude Code invokes; it forwards
the event JSON (wrapped with `$PLANCHETTE_SESSION`) to the socket.

## Non-obvious things that will bite you

- **Attention signal is hook-driven, not output-parsed.** State transitions
  (`working/asking/done/free`) come from Claude Code hooks routed by the
  `PLANCHETTE_SESSION` env var injected into each terminal. Don't try to scrape
  the terminal buffer.
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
