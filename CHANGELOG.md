# Changelog

All notable changes to **Planchette** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Existing users receive each release via the in-app updater (Install & Relaunch).

## [0.2.6] — 2026-07-14

### Added
- **Right-click context menu** on the terminal (Copy / Paste / Select All),
  wired to ghostty's native clipboard actions and localized. Right clicks are
  first offered to the running terminal app, exactly like Ghostty itself, so
  TUIs with mouse reporting still receive them.

### Fixed
- **Terminals resize correctly when the window moves to another display**
  (e.g. external monitor → MacBook screen). The surface now tracks screen
  changes directly — AppKit doesn't reliably report the scale change — and
  tells libghostty the new display for correct vsync.
- **Tabs of one project no longer restore into the same Claude conversation.**
  Resume ids are now resolved as one batch across all terminals — every
  conversation can be claimed by exactly one tab; tabs whose records collide
  (e.g. poisoned by an earlier restore) spread onto the project's remaining
  transcripts, newest first. Plain-shell tabs next to a Claude tab no longer
  hijack a conversation on restore.

## [0.2.5] — 2026-07-13

### Added
- Click a notification to bring its terminal to the front (peon-ping integration).

### Fixed
- Commands stopped with Ctrl+C are no longer flagged as errors (red).

## [0.2.4] — 2026-07-10

### Added
- Progress window during **Install & Relaunch**: a live download bar
  ("Downloading update… N%") that switches to an "Installing update…" spinner,
  so updates no longer feel stuck.

## [0.2.3] — 2026-07-10

### Fixed
- **Restore now brings back every terminal** — all projects and sub-tabs resume
  in the background, not just the focused tab.

### Added
- ⌘-click opens links (URLs are reconstructed across soft line wraps).

### Changed
- Welcome screen shows the app icon instead of the 🔮 emoji.

## [0.2.2] — 2026-07-10

### Added
- Auto-install the Claude Code hooks on launch — attention events work with no
  manual setup.
- Reorder terminals by dragging their tabs.
- Idle terminals show "free" instead of the long `user@host:path` shell prompt.

### Fixed
- Claude sessions are essentially always restorable: the resolver finds the
  conversation even when its id was never captured or went stale.
- Native mouse handling (tracking areas) — clicks position correctly and
  selection starts at the click, not the start of the line.
- Hook command path is space-free (`~/.planchette`); the previous
  "Application Support" path broke the shell invocation.

## [0.2.1] — 2026-07-10

### Added
- Restore unsent prompt input on relaunch.
- Control-key shortcuts (⌃C, ⌃U, ⌃A, ⌃E, …) and Alt combos.
- Full-width terminal titles (truncate to the real width instead of a hard cap).

### Changed
- Project sidebar uses the same solid background as the terminal and
  notifications panel.

### Fixed
- CI builds on macOS 15 with the latest Xcode (ghostty needs a newer SDK).

## [0.2.0] — 2026-07-10

### Added
- Font zoom: `⌘+` / `⌘-` / `⌘0` and header buttons.
- AI assist is on by default, with an in-Settings explanation of what it does.
- Reorder projects in the sidebar via drag and drop.
- Build + release automatically via GitHub Actions on merge to `main`.

### Changed
- Cleaner terminal titles and more reliable idle/running/waiting/error colors.

## [0.1.9] — 2026-07-10

### Added
- Persist and restore terminal scrollback across restarts.
- Close a project (right-click or hover-X).
- Terminal background follows the app's light/dark mode (white / black).

### Changed
- Reworked notification rows (folder name, status, ticket/context chip).

### Fixed
- Terminal resizes with the window.
- Paste (⌘V) and the Edit-menu clipboard actions work.
- Restore no longer interferes with other terminals; more durable state saves.

## [0.1.8] — 2026-07-09

### Fixed
- Hardened the self-update swap (stage-then-replace with rollback + logging).

## [0.1.7] — 2026-07-09

### Added
- In-app auto-updater: download, verify, swap the bundle, and relaunch.

## [0.1.6] — 2026-07-09

### Added
- Cluster drag-and-drop rework (arrange terminals top/bottom/left/right).
- Project sidebar rendered as a body panel, aligned with the notifications panel.

## [0.1.5] — 2026-07-09

### Added
- Persistent right-hand notifications sidebar; cleaner minified project rail.

## [0.1.4] — 2026-07-09

### Changed
- Cleaner, more consistent minified rail with a calmer transition.

## [0.1.3] — 2026-07-09

### Changed
- A single top-right toggle drives the minified sidebar rail.

## [0.1.2] — 2026-07-09

### Added
- Color status system (green ready / purple running / blue waiting / red error).

### Fixed
- Terminal input and display, sidebar de-duplication, project rail, and the
  slide-in/out animation.

## [0.1.1] — 2026-07-08

### Fixed
- Security hardening across the hook server, subprocess handling, updater, and
  migration.
- Guard UserNotifications behind a bundle check (dev builds crashed).

## [0.1.0] — 2026-07-08

Initial release.

### Added
- Multi-terminal on a self-built GhosttyKit (Ghostty v1.3.1) engine.
- Sessions, groups, and the attention engine with a notifications inbox.
- Continuous persistence with a restore dialog on launch.
- Multi-window support with merge.
- Tags and AI assist (toggleable summaries, topics, group-by-topic).
- Internationalization (7 languages) and explanatory tooltips.
- Dark mode with System / Light / Dark setting.
- Import terminals from iTerm2 & Terminal.app, plus folder drag-and-drop.
- DMG packaging and the GitHub-releases-based in-app update flow.

[0.2.5]: https://github.com/marcello-a/Planchette/releases/tag/v0.2.5
[0.2.4]: https://github.com/marcello-a/Planchette/releases/tag/v0.2.4
[0.2.3]: https://github.com/marcello-a/Planchette/releases/tag/v0.2.3
[0.2.2]: https://github.com/marcello-a/Planchette/releases/tag/v0.2.2
[0.2.1]: https://github.com/marcello-a/Planchette/releases/tag/v0.2.1
[0.2.0]: https://github.com/marcello-a/Planchette/releases/tag/v0.2.0
[0.1.9]: https://github.com/marcello-a/Planchette/releases/tag/v0.1.9
[0.1.8]: https://github.com/marcello-a/Planchette/releases/tag/v0.1.8
[0.1.7]: https://github.com/marcello-a/Planchette/releases/tag/v0.1.7
[0.1.6]: https://github.com/marcello-a/Planchette/releases/tag/v0.1.6
[0.1.5]: https://github.com/marcello-a/Planchette/releases/tag/v0.1.5
[0.1.4]: https://github.com/marcello-a/Planchette/releases/tag/v0.1.4
[0.1.3]: https://github.com/marcello-a/Planchette/releases/tag/v0.1.3
[0.1.2]: https://github.com/marcello-a/Planchette/releases/tag/v0.1.2
[0.1.1]: https://github.com/marcello-a/Planchette/releases/tag/v0.1.1
[0.1.0]: https://github.com/marcello-a/Planchette/releases/tag/v0.1.0
