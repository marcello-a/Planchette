# Planchette 🔮

> *points you to the session that speaks.*

A native terminal IDE for running many AI coding agents at once, built on the
[Ghostty](https://ghostty.org) engine (libghostty). Planchette keeps your
terminal layouts persistent across restarts and reboots, and always shows you
which session needs your attention — who's asking, who's done, who's free.

## Why "Planchette"?

The planchette is the pointer on a Ouija board: in a séance with many spirits,
it moves to the one that has something to say. That's exactly what this app
does — many Ghostty sessions ("spirits"), and the pointer always leads you to
the one that speaks.

## Status

Early development. See [docs/CONCEPT.md](docs/CONCEPT.md) for the full concept,
architecture and roadmap.

**Working today (macOS, `macos/Planchette`):**
- Multiple libghostty terminals in groups: tab view or cluster grid per group
- Attention engine driven by Claude Code hooks: working / asking / done / free,
  inbox, menu-bar badge, per-session idle timers
- Favorites (Hauptprojekte) — prioritized in inbox, notifications, switcher
- Quick switcher ⌘K (fuzzy over title/path/branch/tags) and ⌘⇧K (jump to the
  most urgent waiting session)
- Auto titles (ticket from git branch), short paths with full path on hover,
  colors and custom titles for sessions and groups
- **Tags** on terminals ("to test", "review", …) — chips in sidebar/tabs,
  searchable in the switcher
- **AI assist (toggleable)**: transcript-based one-line summaries per agent
  session via headless `claude -p`, topic labels, and opt-in group-by-topic
- Persistence across restart & reboot: layout, colors, titles, cwd, tags,
  Claude session — resumed via `claude --resume`, plus per-session startup
  commands

Current phase: **Phase 0/1 done, hardening**

- [x] Spike A (macOS): GhosttyKit embedded in a minimal SwiftUI app, 2 interactive surfaces
- [ ] Spike B (Linux): libghostty in a Zig + GTK4 widget (needs a Linux machine)
- [x] Spike C: hook → unix socket → in-app notification roundtrip, with per-terminal
      session identity via injected `PLANCHETTE_SESSION` env var

### Running the spike

```sh
# 1. Build GhosttyKit from the pinned submodule (once; needs Zig 0.15.2 in .tooling/)
cd vendor/ghostty && ../../.tooling/zig/zig build -Demit-macos-app=false -Dxcframework-target=native -Doptimize=ReleaseFast && cd ../..
cp -R vendor/ghostty/macos/GhosttyKit.xcframework macos/PlancheSpike/

# 2. Build & run the app
cd macos/PlancheSpike && swift build
GHOSTTY_RESOURCES_DIR=$PWD/../../vendor/ghostty/zig-out/share/ghostty ./.build/debug/PlancheSpike

# 3. Simulate a Claude Code hook event (from any shell)
echo '{"hook_event_name":"Notification","message":"needs permission"}' \
  | PLANCHETTE_SESSION=term-1 ../../hook/planchette-hook
```

## Documentation

- [docs/CONCEPT.md](docs/CONCEPT.md) — product vision, feature set, roadmap
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — how the code fits together
- [CONTRIBUTING.md](CONTRIBUTING.md) — build, test, package, release
- [AGENTS.md](AGENTS.md) — rules & orientation for AI contributors

## Structure

```
vendor/ghostty/   Ghostty submodule, pinned → builds libghostty/GhosttyKit
core/             Zig: libplanchette — sessions, attention state machine, store, IPC
hook/             planchette-hook — tiny binary forwarding Claude Code hook events
macos/            Swift/SwiftUI app
linux/            Zig + GTK4 app
docs/             Concept & architecture docs
```

## Platforms

macOS and Linux, native UI on both — no Electron.

## License

MIT
