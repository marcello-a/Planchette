# Updating without a restart

## The part that is impossible

macOS cannot replace the running executable of a signed app. The Mach-O is
mapped into the process, its code signature is validated at load time, and there
is no supported way to swap it underneath a live AppKit process. Every "no
restart" update story on macOS is one of three things:

1. a **plugin architecture** — code in dylibs that can be unloaded and reloaded.
   Swift has no stable ABI guarantee across our own builds, every dylib needs
   signing, and all live state would have to migrate across the swap. For a
   terminal app holding PTYs and Metal layers this is a rewrite, not a feature.
2. a **process split** — the thing that must not die is not the thing being
   replaced (§ Tier C).
3. a **lie** — the app restarts and hides it behind a splash screen.

So "update the app binary without a new process" is off the table. What is
actually painful, though, is not the restart itself: it is that **a restart kills
every running agent**. Planchette owns the PTYs, so Install & Relaunch ends every
turn in flight; restore brings the layout and the conversation back (via
`claude --resume`) but not the work. That is the problem worth solving, and it
splits into three tiers by what the user experiences.

## Tier A — the knowledge updates live (implemented)

The part of Planchette that needs to change most often is not the binary. It is
what it *knows*: how each agent's TUI looks on screen, and the helper scripts.
Agent TUIs change weekly; our release cadence should not have to match. herdr
made exactly this call — its detection rules are versioned TOML manifests updated
independently of the binary (`src/detect/manifest_update.rs`).

Step 3 of the herdr adaptation already made our rules *data*
(`ScreenRuleSet`, overridable via `screen-rules.json`), but they were read once at
launch, so a fix still needed a restart. Tier A closes that:

- **Hot reload.** The detection poll already runs every 1.5s; it now stats the
  override file and reloads when its mtime changes. Editing `screen-rules.json`
  takes effect on the next tick, with no restart. A file that fails to parse or
  targets a different engine version is rejected and the previous rules keep
  running — a bad edit degrades to "no change", never to "no detection".
- **Fetched rules.** The update check also looks for a `screen-rules.json` asset
  on the latest release. If its `engine` matches and its `version` is newer than
  what is installed, it is written to Application Support and picked up live.
  Same trust rules as the binary update: GitHub-only host allowlist plus the
  release checksum when present.
- **Compiled floor.** `ScreenDetector.builtIn` stays in Swift. A failed download
  or a corrupt file can never leave the app with no rules at all.

This is a real no-restart update path — for the component that actually needs it.

## Tier B — the binary updates without interrupting you (implemented)

The binary still needs a new process, but nothing forces that process boundary to
happen *when the update lands*. Instead of "Install & Relaunch", an update can be
**staged**: downloaded, verified and extracted in the background, then swapped in
at the next quit — one the user was going to perform anyway.

- The update offer gains **"Install on quit"** next to "Install & Relaunch".
- Staging writes the verified bundle next to the installed one and records it;
  nothing is swapped while the app runs.
- `applicationShouldTerminate` runs the swap helper with relaunch disabled, after
  the existing "agents are still working" guard. The user quits once, for their
  own reasons, and comes back to the new version.
- If the app is killed rather than quit, the staged bundle is applied on next
  launch instead. Either way the swap is atomic (`ditto` to `.new`, then `mv`) —
  the same helper the immediate path uses.

The update stops costing a restart. It does not stop a restart from costing the
running agents — that is Tier C.

## Tier C — nothing is lost, ever (design only)

Move the PTYs out of the UI process:

```
planchetted (long-lived)          Planchette.app (replaceable)
  owns PTYs, agent processes  <-->  windows, layout, attention UI
  owns the hook socket              attaches over a unix socket
  survives UI restarts              can be swapped and relaunched freely
```

Then a binary update restarts only the UI: agents keep running, terminals
reattach, and a turn in flight never notices. This is herdr's client/server
split, and it is the only design in which "update while my agents keep working"
is literally true. It also subsumes three other things we do not have: detach and
reattach, surviving an app crash, and attaching from a second window on another
machine.

Why it is not in this change:

- The surface it touches is everything: `GhosttySurfaceView` (libghostty's
  renderer runs where the layer is, so the *render* side must stay in the UI while
  the PTY side moves), `TerminalRegistry`, persistence, the hook socket, restore.
- libghostty is embedded per-process. Splitting PTY ownership from rendering means
  either running libghostty in the daemon and streaming cells to the UI (herdr
  does this — 14k lines of `server/` and `render_stream.rs`), or keeping libghostty
  in the UI and having the daemon own only the file descriptors, which needs fd
  passing over the socket and a reattach protocol.
- It is weeks of work with no partial credit: a half-migrated daemon is worse than
  none, because the user believes their work is safe when it is not.

The honest sequencing is: Tier A and B now (they remove most of the pain for a
few hundred lines), Tier C as its own project when the app's shape is settled.
The fd-passing variant is the cheaper of the two — it keeps rendering, fonts and
Metal where they are — and is the one to prototype first.

## What "no restart" means in the UI

Three different promises, and they should read differently in the interface:

| Change | User experience |
|---|---|
| Detection rules, helper scripts | applied silently, no interruption at all |
| App binary, staged | "will be installed when you quit" |
| App binary, now | "Install & Relaunch" — ends running turns, and says so |
