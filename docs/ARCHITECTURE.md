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

## Windows

Multi-window: each `WindowModel` owns a set of group IDs and its own selection.
The main window has a stable UUID (`AppState.mainWindowID`) matching SwiftUI's
default `WindowGroup` value; secondary windows get fresh UUIDs.
`sanitizeWindows()` keeps the invariant "every group lives in exactly one
window" and guarantees a main window exists. Groups can move to a new window or
merge back; `WindowRegistry` maps window IDs to their `NSWindow` for raising and
key-window lookup.

## Terminal surfaces

Each terminal is a `GhosttySurfaceView` (an `NSView`) wrapping one libghostty
surface + PTY, created with `PLANCHETTE_SESSION=<uuid>` in its environment.
`TerminalRegistry` (a `@MainActor` singleton) owns these views by session ID so
they survive SwiftUI re-layout (tab switches, view-mode changes, window
moves) — the running shell is never restarted by UI churn. `GhosttyRuntime`
holds the single `ghostty_app_t` and dispatches C-API callbacks
(title, pwd, clipboard) back onto the main actor via `NotificationCenter`.

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
(`/tmp/planchette.sock`) → `HookServer` decodes it and calls
`AppState.applyHookEvent`, which routes by `PLANCHETTE_SESSION` to the exact
session. The inbox, menu-bar badge, and quick switcher are all just sorted views
over these states (favorites first, `asking` before `done`, longest-waiting
first). Focusing an `asking`/`done` terminal clears it.

The app offers to install the hooks on launch when they're missing
(`HookInstaller`, a Swift port of `hook/install-hooks.sh`): it writes the hook
script to Application Support and merges the entries into
`~/.claude/settings.json` (backed up, existing hooks untouched, a no-op outside
Planchette terminals). `hook/install-hooks.sh` remains for manual installs.

## AI assist (opt-in)

Off by default. Stage 1 is deterministic: `AIAssist`/`TranscriptReader` parse the
Claude transcript JSONL for the last prompt/answer. Stage 2 (only when enabled)
shells out to `claude -p --model haiku` to condense a transcript tail into a
one-line summary + one-word topic, throttled per session. Stage 3 proposes
grouping sessions by shared topic — applied only after explicit confirmation.

## Packaging & updates

`scripts/package.sh` builds a release binary, assembles `Planchette.app`
(Info.plist, icon, bundled Ghostty resources, ad-hoc codesign) and a `.dmg`.
`scripts/release.sh X.Y.Z` tags `vX.Y.Z` on the default branch and publishes a
GitHub Release with the DMG. `UpdateService` polls `/releases/latest`, compares
the tag to the running `CFBundleShortVersionString` with `Semver`, and offers
the download — so "new stable version on the default branch → offered as update"
is the whole loop. No Sparkle, no appcast server.

## Platform note

macOS is implemented. A Linux frontend (Zig + GTK4 against libghostty) is
planned but gated on libghostty's embedding API stabilizing; the pure-logic core
(state machine, persistence model, hook protocol) is portable.
