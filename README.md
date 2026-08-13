# Planchette 🔮

> *points you to the session that speaks.*

A native terminal IDE for running many AI coding agents at once, built on the
[Ghostty](https://ghostty.org) engine (libghostty). Planchette keeps your
terminal layouts persistent across restarts and reboots, and always shows you
which session needs your attention — who's asking, who's done, who's free.

## Install

Download `Planchette.dmg` from the [latest release](https://github.com/marcello-a/Planchette/releases/latest)
and drag the app into Applications. macOS 14 or newer, Apple Silicon or Intel.

The app is ad-hoc signed, so the first launch needs *right-click → Open* (or
System Settings → Privacy & Security → "Open anyway"). From then on it updates
itself: it checks GitHub for a newer stable release and offers **Install &
Relaunch**, or stages the update and installs it when you next quit — so a
running agent is never interrupted by an update.

Building from source (needs the pinned Ghostty submodule and Zig) is described
in [CONTRIBUTING.md](CONTRIBUTING.md).

## Why "Planchette"?

The planchette is the pointer on a Ouija board: in a séance with many spirits,
it moves to the one that has something to say. That's exactly what this app
does — many Ghostty sessions ("spirits"), and the pointer always leads you to
the one that speaks.

## Status

The macOS app is released and in daily use; it updates itself from GitHub
releases. See [docs/CONCEPT.md](docs/CONCEPT.md) for the full concept,
architecture and roadmap.

**Working today (macOS, `macos/Planchette`):**
- Multiple libghostty terminals in groups: tab view or cluster grid per group
- **Projects in named folders** — collapsible boxes in the sidebar ("myposter",
  "side"), with the attention counts of everything inside them on the folder row.
  Drag a project onto a folder to file it, onto another project to land beside
  it, or onto "No folder" to take it back out
- **Several projects at once** — ⌘/⇧-click to pick 1…n of them, then drag them
  into a folder as one, or use the context menu on the whole batch (color, main
  project, remind me, close)
- **A folder is a page, not just a box** — click it and the main area shows what
  is inside: every project with the badge for what it is doing (running, waiting,
  free…) and all of its tabs, plus the folder's latest notifications underneath.
  Every line is a way in — click a tab and you land in that terminal
- **"Not now"** on a terminal or a whole project: mark it free, or send it away
  for an hour, two hours or until 9 in the morning. It goes quiet — out of the
  inbox, the badges and every notification — and comes back with a reminder
- **Saved arrangements** — store this window's folders, projects, terminals
  (cwd, names, tags, startup commands) and cluster splits under a name; after a
  fresh start the welcome screen offers them and one click rebuilds the whole
  workspace. A template, not a snapshot: no conversation is claimed twice
- Attention engine driven by agent hooks: running / waiting / done / free,
  inbox, menu-bar badge, per-session idle timers
- **Screen fallback**: where hooks stay silent, the terminal viewport is read
  every 1.5s — a visible permission prompt lights the terminal up even if its
  hook never fired. Hooks stay the authority; the rules live in editable JSON,
  not in the binary
- **More than one agent**: Claude Code (full lifecycle via hooks) and Codex
  (session claim + screen). Each terminal shows which agent it runs
- **Drop a screenshot onto a terminal** — with Claude Code running it is pasted
  as an image (`[Image #1]`), not as a long `~/Desktop/Screen Shot ….png` path.
  Anything else still types the shell-escaped path
- **Git worktrees as projects** (⌘⇧T): create a branch's checkout beside the
  repo and open it as its own project, named after the repo and ticket. Closing
  it offers to remove the checkout — and refuses while it is dirty
- **Agents can drive Planchette** — a socket API plus a `planchette` CLI handed
  to every terminal: list sessions, open one, send a prompt, wait for a state,
  read the output. So an agent can put a reviewer to work beside itself and
  block on its verdict ([skill](skills/planchette/SKILL.md))
- **Unreviewed work is visible**: green counts only what finished while you were
  looking elsewhere; looking at the tab clears it. ⌘Q asks before killing a
  running turn
- **Notifications panel** on the right, mirroring projects and tabs: what each
  terminal is asking, working on or reporting, with a "Needs you" block on top —
  errors before questions, longest-waiting first. Click a row to land there
- **More than one window**, and a way back: pull a project into its own window,
  merge a window back into the main one
- Clicking a notification jumps straight to that window, project and tab
- Favorites (Hauptprojekte) — prioritized in inbox, notifications, switcher
- Quick switcher ⌘K (fuzzy over title/path/branch/tags) and ⌘⇧K (jump to the
  most urgent waiting session)
- Auto titles (ticket from git branch), short paths with full path on hover,
  colors and custom titles for sessions and groups
- **Tags** on terminals ("to test", "review", …) — chips in sidebar/tabs,
  searchable in the switcher
- **AI assist (toggleable)**: transcript-based one-line summaries per agent
  session via headless `claude -p`, topic labels, and opt-in group-by-topic
- **Bring your existing terminals in**: import the working directories of open
  iTerm2 / Terminal.app windows, or drop a folder from Finder onto the sidebar
- **Seven interface languages** (EN, DE, FR, ES, IT, NL, PT), light/dark/system
- Persistence across restart & reboot: layout, colors, titles, cwd, tags,
  Claude session — resumed via `claude --resume`, plus per-session startup
  commands
- **Durable terminals (opt-in, needs tmux)**: the agent runs inside tmux, so
  quitting, updating or crashing leaves it working — reopening re-attaches to the
  live session instead of resuming a conversation that lost its turn. A reboot
  still ends everything. Opt-in because it costs keyboard fidelity: tmux cannot
  pass the terminal's keyboard protocol through, so `Shift+Enter` reaches an agent
  as a plain `Enter` (see docs/LIVE-UPDATE.md § Tier C1)

Current phase: **macOS app shipping, Linux not started**

- [x] Spike A (macOS): GhosttyKit embedded in a SwiftUI app — grown into the app
      that ships today (`macos/Planchette`)
- [x] Spike C: hook → unix socket → in-app notification roundtrip, with per-terminal
      session identity via injected `PLANCHETTE_SESSION` env var
- [ ] Spike B (Linux): libghostty in a Zig + GTK4 widget (needs a Linux machine)

### Simulating a hook event

The attention states come from agent hooks. You can drive one by hand from any
shell to see a terminal light up:

```sh
echo '{"hook_event_name":"Notification","message":"needs permission"}' \
  | PLANCHETTE_SESSION=<uuid of a terminal> hook/planchette-hook
```

## Documentation

- [docs/CONCEPT.md](docs/CONCEPT.md) — product vision, feature set, roadmap
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — how the code fits together
- [CONTRIBUTING.md](CONTRIBUTING.md) — build, test, package, release
- [AGENTS.md](AGENTS.md) — rules & orientation for AI contributors

## Structure

```
vendor/ghostty/   Ghostty submodule, pinned → builds libghostty/GhosttyKit
hook/             planchette-hook — tiny binary forwarding Claude Code hook events
macos/Planchette  Swift/SwiftUI app — everything described above
macos/PlancheSpike  the original two-surface spike, kept for reference
scripts/          package.sh (app + DMG) and release.sh (tag + GitHub release)
skills/           the planchette skill: how an agent drives the app via its CLI
docs/             Concept & architecture docs
core/, linux/     reserved for the shared Zig core and the GTK4 app — both empty
```

## Platforms

macOS today (14+). Linux is the plan, not a promise: the shared Zig core and the
GTK4 app are still empty directories. Native UI on both, no Electron.

## License

MIT
