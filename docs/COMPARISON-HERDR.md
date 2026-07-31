# Planchette vs. herdr — what to adapt

Analysis of [herdrdev/herdr](https://github.com/herdrdev/herdr) (Apache-2.0, read at
commit `b411274`, 2026-07) against Planchette, and the plan that follows from it.

## What herdr is

An **agent multiplexer in the terminal**: one Rust binary, tmux-style, that runs your
agents in panes and shows which one is blocked / working / done. Not a native app — it
runs inside whatever terminal you already use.

| | Planchette | herdr |
|---|---|---|
| Shape | native macOS app (SwiftUI + libghostty) | single Rust binary, TUI |
| Size | 6.2k LOC Swift, 69 tests | 202k LOC Rust, 17k LOC integration tests, ~3.1k unit tests |
| Agents recognized | Claude Code only | 19 (claude, codex, gemini, cursor, copilot, amp, droid, opencode, …) |
| State signal | Claude Code hooks only | hooks **and** screen detection, arbitrated |
| Survives app quit | no (layout persists, work does not) | yes — client/server, detach + reattach, over SSH |
| Agents can drive it | no | yes — socket API + `herdr` CLI + agent skill |
| Extensibility | none | plugins + marketplace |
| Platforms | macOS (the `linux/` dir is empty) | macOS, Linux, Windows (beta) |
| Git worktrees | none | first-class (`herdr worktree create/open/remove`) |

## Where herdr is genuinely ahead

1. **Layered state detection with arbitration.** herdr installs per-agent hooks *and*
   scrapes the bottom of the screen, then arbitrates: while a full-lifecycle hook
   integration is live it is the authority (`terminal/state.rs:1733`), but a
   **visible blocker on screen overrides a non-blocked hook state**
   (`visible_blocker_overrides_hook`, `state.rs:1737`), with a staleness check so the
   older signal never wins. Our AGENTS.md rules screen-scraping out entirely. That is
   right as a *primary* signal and wrong as a *fallback*: a hook that never fires (not
   installed, agent killed -9, permission prompt outside the hook set) leaves us
   silently wrong, which is exactly the `/clear` class of bug we just fixed.
2. **Detection rules as versioned data, not code.** `src/detect/manifests/*.toml` — one
   file per agent, priority-ordered rules over named screen regions
   (`prompt_box_body`, `after_last_horizontal_rule`, `bottom_non_empty_lines(5)`), each
   manifest carrying `version` / `min_engine_version` / `updated_at` and updatable
   without shipping a binary (`detect/manifest_update.rs`). Agent TUIs change weekly;
   this is the only sane way to keep up.
3. **Agents can drive the multiplexer.** `HERDR_WORKSPACE_ID` / `TAB_ID` / `PANE_ID` are
   injected into every pane, and the CLI exposes `pane split`, `agent start`,
   `agent prompt --wait`, `agent wait --until blocked`, `pane wait-output`,
   `agent read --source recent-unwrapped`. An agent can spawn a reviewer next to itself
   and block on its verdict. Shipped as a skill (`skills/herdr/SKILL.md`) with an
   `HERDR_ENV=1` guard. We inject `PLANCHETTE_SESSION` already and have a socket — but
   ours is inbound-only, so agents are objects in Planchette, never actors.
4. **Work survives everything.** A server owns the PTYs; clients attach and detach
   (`server/headless.rs`, `server/handoff.rs`, `tests/detach_reattach.rs`). We kill every
   terminal on quit and replay `claude --resume` on restore, which loses the running turn.
5. **Sharper done/idle semantics.** `idle` = ready *and* its tab was seen in the focused
   UI; `done` = the same underlying state reached while unseen. Focus marks it seen; CLI
   reads deliberately do not. Our `ready` has no seen-tracking, so green means "finished
   at some point", not "finished and you haven't looked".
6. **Engineering scaffolding.** `just check`, AI review CI, a docs site, product
   announcements in-app, i18n of the README, Homebrew/mise/curl installs, 45× our test
   count on the part that matters most (state).

## Where Planchette is genuinely ahead

Worth being clear about, because most of it should not be traded away:

1. **Hook-driven truth.** For Claude Code we get the state from Claude itself —
   `UserPromptSubmit`, `Notification`, `PermissionRequest`, `Stop`, `SessionEnd` — with
   the message text and the submitted prompt. herdr's regex manifests are guessing at
   the same facts from pixels. Our signal is more accurate *and* carries content theirs
   cannot: the actual question, the task line.
2. **Attention is the product, not a status column.** Favorites, the "needs you" triage
   block ordered errors-before-questions, the inbox, ⌘⇧K to the most urgent session,
   escalation after 10 minutes, dock badge, menu-bar badge. herdr shows state per pane;
   we route your attention across projects.
3. **Real GUI affordances.** Cluster grids, drag-to-arrange, per-session colors and
   custom titles, tags, hover previews, right-click rename, ⌘K fuzzy switcher over
   title/path/branch/tags, and now drag-and-drop of screenshots straight into a prompt.
   A TUI cannot do most of this.
4. **Project semantics.** Groups = projects with auto titles from the git branch,
   ticket extraction, short paths. herdr has workspaces/tabs/panes — spatial, not
   semantic.
5. **AI summaries.** Transcript-based one-line summaries and topic grouping via the
   user's own `claude -p`. No herdr equivalent.
6. **Localization.** 7 languages, enforced by a test. herdr: English + a Chinese README.

## What we should adapt

Ranked by value per unit of work. The first three are the ones that matter.

### 1. Screen detection as a *fallback* layer, with arbitration (high value)

Keep hooks as the authority. Add a cheap periodic read of the bottom of the buffer —
we already have `ghostty_surface_read_text` wired up in `readScrollback()` — and use it
only to:

- flip a session to `waiting` when a permission/question UI is visibly on screen but the
  hook state says otherwise (herdr's `visible_blocker` override),
- drive state at all for terminals with no live hook integration,
- recover when the hook stream is silent but the screen clearly shows an idle prompt.

Rules live in a versioned data file, not in Swift. This is a deliberate reversal of
AGENTS.md rule "Attention signal is hook-driven, not output-parsed" — that rule should
be rewritten as "hooks are the authority; the screen is a bounded fallback that may only
escalate to `waiting` or resolve to `free`, never invent `running`."

### 2. Support the agents Marcello actually runs (high value)

Today a Codex or Gemini terminal is invisible to the attention engine — it sits gray
forever. Codex, Copilot, Kimi, droid and pi all expose hook/extension points that herdr
installs into (`src/integration/`, `CODEX_HOOK_ASSET` and friends); everything else falls
back to layer 1. Concretely: generalize `HookInstaller` from "Claude Code" to a table of
integration targets, and give `TerminalSession` an agent kind.

### 3. Worktree-native projects (high personal value, small)

`herdr worktree create --branch x --base main` creates the checkout and opens it as a
workspace. We work in worktrees daily and Planchette has no idea they exist: each one
looks like an unrelated folder. Add: create-worktree-as-new-group, label from the branch,
group the worktrees of one repo under their parent, and remove the checkout when the
group is closed (with the same "uncommitted changes" guard `ExitWorktree` uses).

### 4. Outbound control API + agent skill (high value, larger)

Turn `HookServer` into a request/response API and ship a `planchette` CLI plus a skill,
mirroring herdr's surface but narrower: `session list`, `session new --group`,
`session prompt --wait`, `session read`, `session wait --until waiting`. This is what
makes the tool a runtime rather than a dashboard, and it composes with what we already
have that herdr lacks — favorites, projects, tags. Do it *after* 1–3.

### 5. Seen-tracking for `ready` (small)

Split "finished" from "finished and unreviewed": mark a session seen when its tab is
focused in a focused window, and let the inbox/badges count only unseen `ready`. Keep the
existing rule that focusing does **not** clear `waiting`/`error` — a glance isn't an
answer.

### 6. Staged-file fallback for image drops (small)

herdr never touches the agent's clipboard: it writes the image into a staging dir with
restrictive permissions, pastes the path, and reaps files older than 24 h
(`server/clipboard_image.rs`). Our ⌃V route is better for Claude Code locally, but for a
non-Claude agent — or a session where ⌃V means nothing — the staged path is the correct
fallback instead of dropping a `~/Desktop/Screen Shot ….png` path with spaces in it.

### 7. Test the state machine like they do (small, ongoing)

69 tests total, of which a handful cover attention state. The `/clear` bug was a pure
state-machine bug that a table-driven test over (event, source, current state) would have
caught. Every hook event × every source × every current state, as data.

## What we should not copy

- **Going terminal-native.** Being a real macOS app is the differentiator, not a defect.
- **Plugins/marketplace.** No user base to extend yet; it would cost the whole quarter.
- **Windows/Linux/SSH.** `linux/` has been empty since day one — either delete the
  directory or stop implying a port exists.
- **Detach/daemon architecture.** The honest assessment: correct, and too expensive for
  now. Do the cheap 80%: warn on quit while any session is `running`, and make the
  restore dialog say plainly what it cannot bring back.

## Plan

Each step has a hard exit criterion, in the style of docs/CONCEPT.md.

**Step 1 — table-driven state tests (½ day).**
Every hook event × SessionStart source × current state as a fixture table.
*Exit: the pre-fix `/clear` behavior fails the suite.*

**Step 2 — agent kind + integration table (2–3 days).**
`TerminalSession.agentKind`, `HookInstaller` driven by a target table, Codex integration
installed alongside Claude's.
*Exit: a Codex session shows running → waiting → ready → free, and the inbox routes it.*

**Step 3 — screen fallback layer (3–4 days).**
Periodic bottom-of-buffer read per session (throttled, only when the session isn't
already authoritative), rules loaded from a versioned JSON in Application Support,
arbitration: hooks win unless a visible blocker contradicts a non-blocked state, or no
hook has been seen for this session at all.
*Exit: with the Planchette hook uninstalled, a Claude terminal still turns blue on a
permission prompt and gray at an empty prompt; with hooks installed, the fallback never
changes a state the hooks set.*

**Step 4 — worktrees (2–3 days).**
Create/open a worktree as a group, branch-derived labels, nest under the parent repo,
guarded removal.
*Exit: "new worktree for `marcello/feat/NIE-123-x`" produces a running terminal in a new
checkout, titled from the branch, grouped under its repo, and closing the group offers to
remove the worktree.*

**Step 5 — seen-tracking + quit guard (1–2 days).**
Unseen `ready` drives inbox/badge; quit warns while anything is `running`.
*Exit: green badge count drops only after you actually look at the tab; ⌘Q during a
running turn asks first.*

**Step 6 — control API + skill (1–2 weeks, only after 1–5).**
`planchette` CLI over the existing socket, `PLANCHETTE_*` env context per terminal, a
skill with an env guard.
*Exit: a Claude session spawns a second terminal in the same project, sends it a prompt,
waits for it to go `ready`, and reads its output — without touching the UI.*

Steps 1–5 are ~2 weeks and close the gaps that actually bite us. Step 6 is the one that
changes what the tool is.
