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

**Add a feature.** After the control and its strings, add one line to
`Help.sections` in `Help.swift` so it appears in the searchable Help tab. The
entry references the `LKey`s of the control's own label and tooltip, so the help
page and the UI cannot drift apart. `HelpTests` fails if an entry points at a key
with no text.

**Claude hooks.** `hook/install-hooks.sh` installs the forwarder into
`~/.claude/settings.json` (merge + backup). The hook is a no-op outside
Planchette terminals, so it's safe to leave installed.

## Packaging

```sh
sh scripts/package.sh            # → dist/Planchette.app and dist/Planchette.dmg
```

`scripts/install.sh` is the user-facing counterpart: it pulls the latest release,
verifies it against `SHA256SUMS`, installs it and clears the quarantine flag.
Keep it working when the release assets change — the README points people at it
as the primary install route.

The app is ad-hoc signed (runs locally). Distributing to other machines needs a
Developer ID identity + notarization — replace the `codesign` line in
`scripts/package.sh`.

## Releasing (versioning)

Releases are cut from the default branch and drive the in-app updater.

**A merge releases when its PR asks for it.** Every push to `main` builds GhosttyKit and
runs the tests. The PR template has a **Trigger new release** checkbox, off by default.
Only when it is ticked does `scripts/auto-release.sh` run and decide
([`.github/workflows/release.yml`](.github/workflows/release.yml)). Unticked, or a push
without a PR, is a build and nothing more. A manual run of the workflow always may release.

- The commits since the last release carry a `feat:`, `fix:` or `perf:` → the patch
  number goes up by one, in a `chore: release vX.Y.Z` commit the workflow pushes, and
  that version is published.
- They carry only `chore:`, `docs:`, `test:`, `style:` or `refactor:` → a build, and
  nothing is published. A merge that changes nothing a user can see offers no update.
- `[skip release]` in the head commit's message → a build, and nothing is published.

So the commit type is the switch: write it for what the change does to a user.

For a minor or major bump, or a release with notes of your own, bump `VERSION` by hand
in the PR and write the version's `CHANGELOG.md` section there. A `VERSION` that names a
version not published yet is released as written, whatever the commits say.

The release body is the version's `CHANGELOG.md` section, and the app reads it back for
"What's new". Put your entries under `## [Unreleased]` in the same PR: the workflow
moves them under the new version. With none there, the notes list the commits instead —
readable, but yours are better.

The workflow pushes the release commit to `main` with its own token, which needs a
`main` that does not block it (a branch protection rule would; the run then fails,
visibly, and nothing is published).

`scripts/test-auto-release.sh` tests these rules in throwaway repositories and runs in
CI before the release step; run it after any change to `scripts/auto-release.sh`.

To cut one by hand instead — the workflow runs the same script, so the result
is identical:

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
