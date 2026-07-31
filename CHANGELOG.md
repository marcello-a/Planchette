# Changelog

All notable changes to **Planchette** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Existing users receive each release via the in-app updater (Install & Relaunch).

## [0.2.9] — 2026-07-31

### Added
- **More than one agent.** Terminals now carry an agent kind, reported by the
  hook script itself. Codex is wired up (`~/.codex/hooks.json` + the `hooks`
  feature flag) with a session claim; Claude Code keeps its full lifecycle.
- **Screen detection as a fallback signal.** The viewport is read every 1.5s and
  arbitrated against the hooks: while Claude Code is live the screen may only
  escalate to `waiting` on a visible permission prompt, and without hook
  authority it drives every state. Rules are data — override them in
  `screen-rules.json` instead of waiting for a release.
- **Git worktrees as projects** (Session → New worktree, ⌘⇧T). The checkout is
  created beside the repo, opened as its own project named after repo and
  ticket, and offered for removal when the project closes — git refuses while it
  is dirty and that refusal is reported, not forced.
- **Agents can drive Planchette**: a socket control API (`session list/get/new/
  prompt/read/wait`, `project list`) plus a `planchette` CLI handed to every
  terminal as `$PLANCHETTE_CLI`, and a skill documenting it.
- **Unreviewed work is distinguishable.** A turn that finishes while you are
  looking elsewhere is unseen; the sidebar's green badge counts only that, and
  focusing the tab clears it. `waiting`/`error` still persist — a glance isn't
  an answer.
- **⌘Q asks before killing a running turn**, and says what a restore can and
  cannot bring back.

### Fixed
- `session.new` now actually starts a terminal. A session created into a
  background project had no PTY (SwiftUI only builds surfaces for what it
  renders), so the very next `session.prompt` failed — which is exactly the flow
  the skill documents. Surfaces also start at a plausible size instead of 1×1.
- `session.prompt` refuses a terminal whose turn is still running (`force`
  overrides), and sends the text and its newline as one write so a TUI cannot
  submit an empty line first.
- Screen-driven states no longer carry the previous notification's text, which
  showed a stale question next to a new prompt.
- API responses are written off the main thread: a `session.read --scrollback`
  reply can exceed the socket buffer, and `write` would block the UI until the
  client drained it.
- The hook script passes an unrecognized agent label through instead of calling
  it Claude, which would have handed a foreign agent Claude's authority over the
  terminal's state.

### Changed
- The no-scraping rule in AGENTS.md is replaced by the arbitration boundary:
  hooks are the authority, the screen is a bounded fallback that may never
  overrule a hook that is talking to us.

## [0.2.8] — 2026-07-30

### Added
- **Drop a screenshot to paste it** — dropping an image onto a terminal that is
  running Claude Code now behaves like copy/paste: the image goes on the
  clipboard and ⌃V is sent, so Claude attaches it (`[Image #1]`) instead of
  receiving a long `~/Desktop/Screen Shot ….png` path. Works for image files and
  for images dragged straight out of another app (Preview, a browser). Anything
  else — other file types, URLs, text, or a terminal with no live Claude — still
  types the shell-escaped path as before.
- **Clicking a notification jumps to the terminal** that posted it: its window,
  its project, its tab. Banners now also appear while Planchette itself is
  frontmost, since the whole point is that *another* terminal needs you.

### Fixed
- **`/clear` now frees the terminal.** A fresh conversation
  (`SessionStart` with source `startup`, `clear` or `resume`) is gray on its own
  evidence, so `/clear` no longer leaves the old green/blue state behind when the
  paired `SessionEnd` doesn't land. Its task line is dropped too. `compact` and
  `fork` still keep the state — they happen mid-turn.

## [0.2.7] — 2026-07-20

### Added
- **Drop files onto a terminal** — dragging an image (or any file/URL) into a
  terminal types its shell-escaped path at the prompt, so a running `claude`
  can read it directly. Same behavior as Ghostty itself.
- **Notifications 2.0** (see docs/NOTIFICATIONS.md):
  - Every session now shows **what it works on** — the submitted prompt is
    captured as its task line (instant, no AI needed; AI summaries refine it).
  - **"Needs you" triage block** on top of the notifications panel: errors
    before questions, favorites first, longest-waiting on top.
  - **New "free" state (gray)**: green now means *done — result awaits your
    review*; gray means *truly free*. Claude exiting or Ctrl+C frees the
    terminal; "mark as free" does what it says.
  - Hovering a notification row shows the **full question/error**, the task,
    and the path.
  - **Gentle escalation**: a session waiting >10 min triggers one reminder
    notification (favorite projects only) — never more. Dock badge shows the
    needs-attention count.
- **Rename a tab from its right-click menu** (also in the notifications
  panel). The name syncs everywhere a terminal is shown — tabs, sidebar,
  notifications, quick switcher.

### Changed
- State colors come from a single source everywhere: the sidebar's project
  badges now use the same attention palette (and badge style) as the
  notifications panel instead of their own red/blue.
- **Notifications panel mirrors projects and tabs**: one section per project
  (sidebar order, favorites first), one row per tab with its state, current
  notification and waiting time. Click a tab row to jump straight to that tab,
  or a project header to jump to the project. Project headers carry an
  attention badge colored by the most urgent tab.

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

[0.2.7]: https://github.com/marcello-a/Planchette/releases/tag/v0.2.7
[0.2.6]: https://github.com/marcello-a/Planchette/releases/tag/v0.2.6
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
