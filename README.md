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

Current phase: **Phase 0 — Spikes**

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
