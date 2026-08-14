# Changelog

All notable changes to **Planchette** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Existing users receive each release via the in-app updater (Install & Relaunch).

## [Unreleased]

### Added
- **Pixel-art state icons in Claude's own visual language.** The states are 8x8
  sprites of the spark Claude prints while it works: a dim ember for free, the
  full spark for a finished turn, the spark opened into a question for waiting
  and broken into a bang for an error. They replace the SF Symbols and the plain
  dots in the sidebar, the tabs, the cluster headers, the switcher, the folder
  overview and the notifications panel — so shape carries the state as well as
  colour, which also answers it for anyone who cannot tell red from blue.
- **The running state is a robot, and it runs.** Four frames off a shared
  timeline, arms and legs moving while head and body hold still, so every
  running terminal on screen steps in time and no view holds a timer of its own.
  A still picture cannot say "something is happening right now"; this is the one
  state where that is the whole message. The menu bar keeps the still frame — a
  status item redrawn four times a second is a battery bug, not a feature.
- **The menu bar shows the same sprites** instead of the red and blue circle
  emoji, in the label and in every entry of its menu. It counts and lists
  **unread only**, in urgency order — error, then waiting, then a finished turn
  you have not looked at. A report you have read, or snoozed, is off the menu
  bar entirely.
- **A folder offers a "+" while you point at it**, which adds a project straight
  into that folder instead of at the top level. It takes the place of the folder's
  attention counts while hovered, so the row never changes width.
- **The favourite star is pixel art too**, so the sidebar stops mixing sprites
  with vector glyphs.
- **The active tab is outlined in its state colour.** The tab you are in, and in
  cluster view the header of the pane that has the keyboard, so "which terminal
  am I in" and "what is it doing" are one glance. On the tab, not around the
  terminal: a frame drawn around the content boxes in the text you are reading.

## [0.2.19] — 2026-08-13

### Added
- **Drop a project exactly where you want it.** Dragging now aims at a *gap*, not
  at a row: the upper half of a row means "above this one", the lower half "below
  it", and a line shows which gap you are over while you drag. That is what makes
  the last place in a folder reachable at all — dropping used to always insert
  before the row you hit — so a project can be moved into another folder and put
  in its final position in one gesture.

### Changed
- **The side panels are 256–300 pt wide** instead of 210–400. Wide enough for a
  project name with its badges, narrow enough that two open panels never take the
  window away from the terminal. Both panels use the same bounds, so the window
  stays symmetric however either is dragged.
- **The README is a page you can skim**: what it is, install, features as lists,
  and everything a contributor runs — instead of six screens of prose.

## [0.2.18] — 2026-08-13

### Changed
- **The notifications panel opens on *Only unread*.** Its job is "what needs me",
  and a list that also carries everything already dealt with buries that. Untick
  the box for the full mirror; the choice is remembered.

### Fixed
- **An interrupted install can no longer leave you with no app.** Both the
  in-app updater and `scripts/install.sh` deleted the installed bundle *before*
  the new one was in place; anything failing in that window left nothing behind.
  Both now copy beside the destination, move the old bundle aside, swap, and put
  the old one back if the swap fails.

### Added
- **A demo or test instance restores without asking.** With
  `PLANCHETTE_STATE_DIR` set, the workspace it was handed is opened directly —
  there is nobody to answer a modal in an instance that exists to be driven.

## [0.2.17] — 2026-08-13

### Added
- **Notifications are read or unread.** A report that arrived while you were
  looking somewhere else — a question, an error, a finished turn — is unread
  until you open it. Unread rows carry a ring around their state dot and a bolder
  title (never color alone: the dot's color already means the state), the panel
  header counts them, the new *Only unread* checkbox filters down to them, and
  one button marks everything read. A row can be marked unread again to keep it
  for later. `running` and `free` are not reports and never count: starting the
  work you just gave a terminal is not news.
- **A second instance can run without touching the first.**
  `PLANCHETTE_STATE_DIR` moves everything an instance owns — state, scrollback,
  presets, rule override, tmux config and socket pointer — and gives it its own
  tmux server, so a demo or a test cannot adopt the real workspace's agents.
  Redirecting `$HOME` does not do this: `NSHomeDirectory()` reads the user record
  and ignores the environment, so a "sandboxed" launch silently opened the real
  workspace. This is how the README screenshot was taken.

- **The update dialog says what's new.** It lists the titles of the new version's
  changelog entries — only the titles, and at most five, with "…and 3 more" for
  the rest: a modal that asks whether to restart is the wrong place to read
  twelve paragraphs. The notes come from the release body, which `release.sh` now
  fills from this file, so "what's new" has one source and cannot drift from it.
- **Terminals name themselves.** A tab is now called `NIE-1902 · Add the format
  switch`: the ticket of its checkout plus the task you last sent it, condensed
  to a sidebar-width label that cuts at a word boundary. Two terminals in one
  worktree used to show the identical branch ticket and nothing else; the half
  after the `·` is what tells them apart. The task outranks the title the program
  reports over OSC — a program rewrites that constantly, and to the same string
  in every tab of a repo, while the task is what *you* sent the terminal to do
  and stays until you send it something else. A name set by hand still wins over
  both, and a terminal with neither ticket nor task reads as before ("free" when
  idle, otherwise its folder).

### Fixed
- A project holding one terminal read "1 terminals" in the folder overview.

## [0.2.16] — 2026-08-12

### Added
- **A folder now has an overview page.** Clicking a folder used to leave the main
  area on the "no terminals" hint; it now shows what is inside the box: one card
  per project with the badge for what it is currently doing — the most urgent
  state of its terminals, so an error is never hidden behind a calm green — and
  every one of its tabs with its state, path, tags and current line. Underneath,
  the folder's latest notifications across all its projects, newest first.
  Everything on the page is a way in: a card header opens the project, a tab row
  opens that exact tab, a feed entry jumps to the terminal that reported it.
  A folder and a project can never both own the main area — picking either one
  takes the other down (`WindowModel.selectGroup`), and the selected folder is
  persisted, so the page you were on is still there after a restart.
- **Drag projects into folders**, and **pick several at once.** ⌘/⇧-click builds a
  selection; dragging any of it moves the whole batch as one, and the context
  menu then acts on all of them ("2 projects selected", "Mark 2 projects as
  free", "Close 2 projects"). Drop a project on a folder to file it, on another
  project to land next to it in that project's folder, or on the "No folder" row
  at the bottom of the list to take it back out. One row selected still means
  "show me this project"; with several selected the terminal area stays where it
  is, since switching it to whatever was clicked last is only noise.

### Fixed
- **A project row's click and its drag no longer fight over the gesture.** The
  first cut put `.onDrag` on the row, which swallowed the click that selects a
  project — so a project could be dragged but not opened. Both live on the row
  now via `draggable`/`dropDestination`, which is what those APIs are for; an
  `.onDrag` on a `DisclosureGroup`'s *label* never receives the gesture at all.
- **Dropping a project on itself** appended it to the end of its folder instead
  of doing nothing.

## [0.2.15] — 2026-08-10

### Added
- **Projects can live in named folders.** A folder is a collapsible, colorable box
  over the projects in one window's sidebar ("myposter", "side"), and it carries
  the attention counts of everything inside it — so a closed folder still tells
  you whether something in there needs you. A project moves with *Move to folder*
  in its context menu and can be reordered inside its folder; projects in no
  folder keep the familiar list below, favorites first. Folders belong to the
  window, because the sidebar is a per-window view: moving a project to another
  window means putting it somewhere else there.
- **"Not now" for a terminal or a whole project.** Mark it free, or send it away
  for an hour, two hours, or until 9 in the morning ("Tomorrow 9:00" means the
  *next* 9:00, so a snooze taken at 3 a.m. comes back this morning, not tomorrow).
  A snoozed terminal goes quiet: out of the inbox, the counts, the dock and
  menu-bar badges and every notification, including the ten-minute escalation.
  It is filtered, not frozen — hooks and screen detection keep its color honest,
  it just stops asking for you, and a 🔕 badge says when it comes back. The
  reminder then arrives even if the snooze ran out while Planchette was closed:
  it is checked once on restore, not only on the minute tick.
- **Saved arrangements.** Store a window's folders, projects and terminals — with
  their working directory, name, color, tags, startup command and cluster splits
  — under a name, and rebuild the whole workspace from it with one click. After
  *Start fresh* the welcome screen offers them, which is the point: arrangements
  live in their own `presets.json` and survive throwing the workspace away. An
  arrangement is a template, not a snapshot: it stores no Claude conversation id,
  so opening one twice gives two independent workspaces instead of two terminals
  fighting over the same conversation. Splits are stored by terminal *index*,
  since session ids are minted fresh every time one is opened.

## [0.2.14] — 2026-08-03

### Fixed
- **Durable terminals are opt-in again, and say what they cost.** 0.2.13 made them
  the default; that was wrong. tmux is a terminal emulator, not a transparent
  pipe, and it does not pass the keyboard protocol through: `Shift+Enter` reaches
  an agent as a plain `Enter`, so it submits instead of adding a line. Measured
  against tmux 3.7b with a probe that enables the protocol the way an agent does,
  ghostty sends `ESC [ 1 3 ; 2 u` while tmux delivers `\r` — at both
  `extended-keys on` and `extended-keys always`. `extended-keys` only chooses how
  modified keys are *encoded*; it cannot recover a distinction tmux never made, so
  there is no fix on our side. The setting now states this, and nothing flips it
  in either direction behind you.

### Changed
- **Durable terminals run on their own tmux server** (`-L planchette`) with their
  own config, instead of sharing yours. This is what makes the fidelity settings
  possible at all: `extended-keys`, `set-clipboard` and `escape-time` are *server*
  options, so setting them on a shared server would silently reconfigure your own
  tmux. On our server they are ours alone, and your sessions keep their prefix,
  status bar and theme. The config also declares what ghostty can actually do —
  truecolor, OSC 52 clipboard, focus reporting, cursor shape and colour, underline
  styles, hyperlinks, synchronised output — since tmux otherwise assumes far less,
  and turns off the status bar and prefix key so tmux stays invisible.
  Your `~/.tmux.conf` is deliberately not loaded: it would reintroduce exactly the
  visible behaviour we are trying to avoid.

## [0.2.13] — 2026-08-03

### Changed
- **Durable terminals are on by default**, and tmux no longer shows through.
  Each session is created with `status off` and `prefix None`, so there is no
  status bar taking the bottom row and no prefix swallowing `C-b` — which is
  backward-char in every emacs-mode shell, and bound by agent TUIs. Both are
  scoped to our own sessions; your own tmux keeps its settings. Where tmux is not
  installed nothing changes: the terminal is simply an ordinary one. One trade
  remains, and switching the setting off undoes it — the shell now lives on
  tmux's alternate screen, so the terminal's own scrollback holds repaints rather
  than a linear history. Installs that still carry the old opt-in `false` get the
  new default once; switching it off after that sticks.
- **Updates are checked while the app runs**, not only once at launch. Planchette
  is meant to stay open for days — durable terminals exist so it can — so a
  launch-only check meant a long-lived instance never learned an update existed.
  It now re-checks every 6 hours, which also refreshes detection rules on the
  same schedule. A background check never interrupts twice: declining a version
  silences it until the next launch, and a check is skipped entirely while one is
  already running, installing, or staged.

## [0.2.12] — 2026-08-03

### Fixed
- **Closing a project left its durable agents running.** Closing a single
  terminal ended its agent, but closing a whole project only freed the surfaces —
  every durable session in it kept running headless until some later launch
  reaped it. It now ends them, exactly as closing a tab does.

### Changed
- **Restore no longer asks tmux once per terminal on the main thread.** Deciding
  whether a durable terminal's agent survived used a `has-session` probe per
  terminal — a subprocess each, on the main thread, while the UI was coming up.
  It is now one `list-sessions` call, off-main, resolved as a batch before any
  surface is built (the same shape the Claude conversations already used), and
  only when there is a durable terminal to ask about. Terminals without
  durability keep the synchronous path unchanged.

## [0.2.11] — 2026-08-01

### Fixed
- **A second durable terminal reported as the first one.** tmux runs one server
  for every session and keeps the environment of whichever client happened to
  start it; `update-environment` only refreshes a fixed list that
  `PLANCHETTE_SESSION` is not on. So from the second durable terminal onwards,
  every hook event, task line, notification and "this terminal" CLI default named
  the wrong tab — the attention engine's whole job, done against the wrong
  session. The identity is now passed per session (`new-session -e`), which is
  the only place tmux takes it. Re-attaching leaves an existing session's
  environment alone, as it must: its processes already hold those values.

## [0.2.10] — 2026-07-31

### Added
- **Durable terminals** (Settings → Durable terminals, off by default, needs
  tmux). A durable terminal runs its shell inside tmux, so the agent belongs to
  tmux's process tree instead of ours: quitting Planchette, installing an update
  or even crashing leaves it working. Reopening re-attaches to the live session —
  the running turn, its output and its scrollback are simply still there — rather
  than replaying `claude --resume` against a conversation that lost its work. A
  reboot still ends everything, and the setting only applies to terminals created
  after it is switched on. Closing a terminal on purpose ends its agent, and
  sessions whose terminal is gone are reaped at the next launch — only ones no
  client is attached to, so a second Planchette keeps its own agents.
- **Hooks find the app again after it restarts.** The running instance publishes
  its socket to `~/.planchette/socket`, and both the hook and the `planchette`
  CLI fall back to it when `$PLANCHETTE_SOCKET` points at a dead one — which is
  exactly the case for an agent that outlived the app that started it.
- **Detection rules update live** (see docs/LIVE-UPDATE.md). `screen-rules.json`
  is re-read whenever it changes — by hand or from a release — so a pattern fix
  takes effect on the next 1.5s tick with no restart. Rules now ship as their own
  release asset, checksum-verified, and only replace the running set when they
  are newer for the same engine version. A rejected file leaves the working rules
  in place; `ScreenDetector.builtIn` stays the compiled floor.
- **"Install on quit"** next to "Install & Relaunch". The update is downloaded
  and verified immediately but swapped in at the next quit — one you were going
  to do anyway — so updating never ends a running turn. A staged update survives
  the app being killed instead of quit, and is applied at the following quit.

### Changed
- `rules/screen-rules.json` is generated from `ScreenDetector.builtIn`, with a
  test that fails when the two drift, so detection rules have one
  hand-maintained source.
- The "agents are still working" quit warning ignores durable terminals: their
  work survives the quit, so counting them would train you to click through the
  one dialog that still matters.

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

[0.2.15]: https://github.com/marcello-a/Planchette/releases/tag/v0.2.15
[0.2.14]: https://github.com/marcello-a/Planchette/releases/tag/v0.2.14
[0.2.13]: https://github.com/marcello-a/Planchette/releases/tag/v0.2.13
[0.2.12]: https://github.com/marcello-a/Planchette/releases/tag/v0.2.12
[0.2.11]: https://github.com/marcello-a/Planchette/releases/tag/v0.2.11
[0.2.10]: https://github.com/marcello-a/Planchette/releases/tag/v0.2.10
[0.2.9]: https://github.com/marcello-a/Planchette/releases/tag/v0.2.9
[0.2.8]: https://github.com/marcello-a/Planchette/releases/tag/v0.2.8
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
