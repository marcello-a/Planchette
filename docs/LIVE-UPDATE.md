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

## Tier C — nothing is lost, ever

Tiers A and B stop the *update* from costing a restart. They do nothing about
what a restart costs: our own PTYs. This tier is about surviving that, and it has
two designs — one shipped, one still on paper.

### C1 — durable terminals via tmux (implemented)

The cheap version of the daemon, and it needs no daemon of ours at all. The
insight is that we do not have to make the *PTY* survive; we have to make the
*agent* survive. libghostty forks the shell in our process and holds the PTY
master, and it cannot adopt an existing PTY (there is no fd field in
`ghostty_surface_config_s`) — so instead of owning the agent's process tree, we
hand it to a multiplexer that already outlives us:

```
Planchette.app                tmux server (long-lived)
  libghostty surface   -->      planchette-<session-uuid>
  runs `tmux new-session -A -D`   owns the agent's process tree
```

- **One command for both paths.** `new-session -A` attaches when the session is
  there and creates it when it is not, so first launch and re-attach are the same
  code path. `-D` detaches whatever stale client a crashed Planchette left
  behind, instead of fighting it over the terminal size.
- **The session name is the terminal's persisted id**, which is what makes
  re-attach possible at all: same terminal, same name, across any restart.
- **Restore does nothing when the agent is alive.** `TerminalRegistry` probes
  `has-session` before building the surface; if the agent is still there, no
  scrollback replay and no `claude --resume` — tmux hands back the live screen.
  Replaying would `cat` a stale snapshot over a running TUI and start a *second*
  Claude beside the first.
- **Hooks still reach us.** The surviving agent's environment names the dead
  app's socket, so `HookServer` publishes the live path to `~/.planchette/socket`
  and the hook, the CLI and the click command fall back to it.
- **It ends when you mean it.** Closing a terminal — or a whole project — kills
  its tmux session; sessions whose terminal no longer exists are reaped at the
  next launch. Two guards keep reaping from destroying work: only
  `planchette-<uuid>` names are considered (the user's own tmux sessions are
  never touched), and only sessions **no client is attached to** — an attached
  session belongs to a second Planchette that is running right now, and starting
  this one fresh must not kill its agents.
- **tmux does not show through.** Durability is plumbing, not a feature anyone
  asked for, so each session is created with `status off` (no status bar taking
  the bottom row) and `prefix None` (no key stealing — the default `C-b` is
  backward-char in every emacs-mode shell, and agent TUIs bind it too). Both are
  set with `-t` on our own session; the user's tmux keeps its own settings.

Covers quit, Install & Relaunch and a crash. Does **not** cover a reboot or a
logout, which end tmux's server too.

### Why C1 has to stay opt-in

tmux is not a transparent pipe — it is a terminal emulator, and a durable
terminal is therefore *two* emulators deep. Most of that can be papered over
(the config above does), but one thing cannot:

**tmux does not pass the keyboard protocol through.** Ghostty implements the
kitty keyboard protocol, which is how `Shift+Enter` is distinguishable from
`Enter` at all — it is what lets an agent insert a newline instead of submitting.
Inside tmux the distinction is gone: the key arrives as a plain `\r`. Measured
against tmux 3.7b, with a probe that enables the protocol exactly as an agent TUI
does:

| | bytes delivered for `Shift+Enter` |
|---|---|
| ghostty directly | `ESC [ 1 3 ; 2 u` |
| inside tmux, `extended-keys on` | `\r` |
| inside tmux, `extended-keys always` | `\r` |

`extended-keys` governs how tmux *encodes* modified keys once it has them; it
cannot recover a distinction tmux never made. tmux implements xterm's
`modifyOtherKeys`, not the kitty protocol, so there is no setting that fixes
this from our side. Secondary costs are smaller but real: the shell lives on
tmux's alternate screen, so the terminal's own scrollback holds repaints rather
than a linear history.

So durability is a deliberate trade, not a free upgrade: worth it for an agent
that must outlive the app, wrong as a default for every terminal. 0.2.13 shipped
it on by default and 0.2.14 reverted that.

The way to get durability *without* the trade is either a proxy that does no
terminal emulation at all (`dtach`/`abduco` forward a PTY rather than emulating
it, so the protocol passes through untouched) or § C2 below. Both are their own
change.

### C2 — our own daemon (design only)

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

What C1 buys over C2, honestly: everything except a reboot, for ~200 lines
instead of weeks, using a multiplexer that is already better tested than anything
we would write. What C2 still buys over C1: no tmux dependency, no second key
binding layer inside the terminal, attaching from another machine, and surviving
a reboot. The fd-passing variant is the cheaper of the two — it keeps rendering,
fonts and Metal where they are — and is the one to prototype first, if C1 turns
out not to be enough in daily use.

## What "no restart" means in the UI

Four different promises, and they should read differently in the interface:

| Change | User experience |
|---|---|
| Detection rules, helper scripts | applied silently, no interruption at all |
| App binary, staged | "will be installed when you quit" |
| App binary, now, durable terminals | "Install & Relaunch" — the agents keep working |
| App binary, now, ordinary terminals | "Install & Relaunch" — ends running turns, and says so |
