# Contributing to Planchette

Thanks for helping build Planchette. This covers building, testing, the common
tasks, and releasing. For the code map and design rationale see
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md); for the rules AI/agents follow see
[AGENTS.md](AGENTS.md).

## Prerequisites

- macOS 14+ with Xcode 16+ (Swift 5.9+) and the Metal Toolchain
  (`xcodebuild -downloadComponent MetalToolchain` if a build complains).
- The Ghostty submodule and a matching Zig toolchain (pinned; see below).

## First-time setup

```sh
git clone --recurse-submodules https://github.com/marcello-a/Planchette.git
cd Planchette
# If you cloned without --recurse-submodules:
git submodule update --init

# Zig 0.15.2 is used to build GhosttyKit (the app's terminal engine).
# The project keeps a local copy under .tooling/ (gitignored):
mkdir -p .tooling && curl -sL https://ziglang.org/download/0.15.2/zig-aarch64-macos-0.15.2.tar.xz \
  | tar xJ -C .tooling && mv .tooling/zig-* .tooling/zig

# Build GhosttyKit from the pinned submodule (once, ~a few minutes):
cd vendor/ghostty
../../.tooling/zig/zig build -Demit-macos-app=false -Dxcframework-target=native -Doptimize=ReleaseFast
cp -R macos/GhosttyKit.xcframework ../../macos/Planchette/
cd ../..
```

## Build & run (dev)

```sh
cd macos/Planchette
swift build
GHOSTTY_RESOURCES_DIR=$PWD/../../vendor/ghostty/zig-out/share/ghostty ./.build/debug/Planchette
```

The env var points libghostty at its resources during development; the packaged
`.app` bundles them instead.

## Test

```sh
cd macos/Planchette
swift test
```

Tests cover pure logic (`Semver`, `Titles`, attention state, localization
completeness). Add a test with any new pure helper. UI-affecting changes should
also be verified by driving the running app (see AGENTS.md → "Verifying").

## Common tasks

**Add a user-facing string.** Add a case to `LKey` in `Localization.swift` and a
value in **every** language table (English is mandatory — a test fails
otherwise). Use `L10n.t(.yourKey)`; never hardcode display text.

**Add a language.** Add a case to `AppLanguage`, a `displayName`, and a full
table in `Localization.swift`. The English table is the fallback for any missing
key.

**Add a persisted setting.** Add the field to `PersistedState` (both `init`s) and
to `AppState`; wire it through `saveNow`, `applyRestore`, `startFresh`, and the
early load in `AppState.init`. Give it a default via `decodeIfPresent` so old
state files keep loading.

**Add a control.** Give it a `.help(...)` tooltip (localized) — every control
has one.

**Claude hooks.** `hook/install-hooks.sh` installs the forwarder into
`~/.claude/settings.json` (merge + backup). The hook is a no-op outside
Planchette terminals, so it's safe to leave installed.

## Packaging

```sh
sh scripts/package.sh            # → dist/Planchette.app and dist/Planchette.dmg
```

The app is ad-hoc signed (runs locally). Distributing to other machines needs a
Developer ID identity + notarization — replace the `codesign` line in
`scripts/package.sh`.

## Releasing (versioning)

Releases are cut from the default branch and drive the in-app updater.

```sh
scripts/release.sh 0.2.0
```

This tags `v0.2.0`, builds the DMG, and creates a GitHub Release with it.
`UpdateService` compares the latest release tag to the running version and
offers the update. Requirements: a clean tree on `main`, and `gh` authenticated.

Version numbers follow semantic versioning. The build's version comes from the
git tag (`git describe`); an untagged build reports `0.0.0-dev`.

## Coding style

- Swift API Design Guidelines; match the surrounding code.
- Comments explain *why*, not *what*. Keep them where the constraint isn't
  obvious from the code.
- Keep the main thread free: subprocess/network work goes off-main, then hops
  back to `@MainActor` for state.
- No new external dependencies without maintainer sign-off.
- Conventional-commit messages (`feat:`, `fix:`, `chore:`, `docs:`).
