# Architecture

How Planchette is put together. Pair this with [../AGENTS.md](../AGENTS.md)
(contributor rules) and [CONCEPT.md](CONCEPT.md) (product vision & roadmap).

## Overview

Planchette is a native SwiftUI/AppKit macOS app that embeds the Ghostty
terminal engine (`libghostty`, via the self-built `GhosttyKit.xcframework`) and
adds a project/attention layer on top. There is no Electron, no server, and no
external runtime dependency beyond Apple frameworks and the user's `claude` CLI.

```
┌────────────────────────────────────────────────────────────┐
│ SwiftUI views (Sidebar, TerminalArea, Inbox, QuickSwitcher) │
│                     observe ▼                                │
│                 AppState  (@MainActor, single source)       │
│   ┌───────────────┬──────────────┬───────────────────────┐  │
│   │ TerminalRegistry│ HookServer  │ AIAssist / Update /   │  │
│   │ (NSView PTYs) │ (unix socket) │ Migration / Notif.    │  │
│   └───────┬───────┴──────┬───────┴───────────────────────┘  │
│           ▼              ▼                                    │
│      libghostty     planchette-hook ◄── Claude Code hooks    │
│      (GhosttyKit)   (settings.json)                          │
└────────────────────────────────────────────────────────────┘
                    ▲ persisted to ▼
        ~/Library/Application Support/Planchette/state.json
```

## State & persistence

`AppState` is the only mutable source of truth (`@MainActor`, `ObservableObject`).
Views read from it and mutate through its methods; every mutation calls
`scheduleSave()` (1s debounce) which writes `PersistedState` to
`state.json` atomically.

`PersistedState` (in `Models.swift`) is `Codable` with **hand-written,
backward-compatible decoding**: every field added after v1 uses
`decodeIfPresent … ?? default`, so an older `state.json` still loads. When you
add a persisted field, wire it through all five spots listed in AGENTS.md rule 4.

Restore is deliberate (a launch dialog: *Restore* vs *Start fresh*). "Start
fresh" archives the previous state to `state-previous.json` instead of deleting
it. Processes can't survive a reboot, so restore re-creates terminals in their
saved `cwd`, resumes Claude via `claude --resume <id>`, and re-runs an optional
per-session startup command.

**Presets live outside `state.json`** (`presets.json`, `Presets.swift`). That
separation is the feature: "Start fresh" throws the workspace away, and the
saved arrangements have to still be there afterwards — the welcome screen offers
them as the way back. A preset is a template, not a snapshot: projects, folders,
terminals (cwd, title, color, tags, startup command) and the tabs' splits,
addressed by terminal *index* since session ids are minted fresh on every open.
It deliberately carries no Claude conversation id — opening one twice must not
put two terminals on the same conversation.

**A tab is a split tree** (`TabSplit.swift`). A project keeps `tabs: [SplitLayout]`, one tree of
terminals per tab, and `sessionIDs` in the order the tabs show them (pane by pane), so the
sidebar, the overview and the control API need no idea of splits. `TabStrip` is the whole
model, pure and unit-tested: `synced` repairs a stored strip against the project's terminals
(a closed terminal leaves its tab, a new one gets a tab at the end, one that is in two places
stays in the first), and every drop — a tab onto a pane's edge, a pane onto a pane, a pane out
to its own tab, combine all, separate all — answers a new strip or `nil` when nothing would
change, which is also how the drop zones know not to light up. `AppState.tabs(of:)` is the
strip as the views read it; `applyTabs` is the one place it is written, and refuses a strip that
does not hold exactly the project's terminals. A project saved in cluster mode (`viewMode`,
`clusterLayout`) is migrated when it is decoded: one tab holding the cluster's layout.

**The notepad** (`Notepad.swift`, `Views/NotepadView.swift`). Each terminal has one text, written to
`TerminalSession.notepad` only when the state is saved: while the app runs it lives in
`AppState.notepadText`, which is deliberately not `@Published`, because a keystroke in the pad must
not redraw the window. `NotepadLook` (open, width, how many Returns end a prompt) is persisted as
`PersistedState.notepad` and read from a state that has none. `NotepadPrompts` is the pure part: it
cuts the text into prompts — by hand, since `NSString` paragraphs miss U+2028 — and answers the
prompt under the caret. The pad is an `NSTextView` that reports where each prompt starts; the
margin buttons are SwiftUI buttons laid over those positions, because an `NSScrollView` inside
a SwiftUI view exposed no children to accessibility, and buttons that are not in the accessibility
tree cannot be used with VoiceOver or driven by `scripts/perf/notepad.py`. Loading goes through
the same `ControlAPI.deliverPrompt` as `session.prompt`: a paste, and — for the second margin button and ⌘↩ — Return after it, one
prompt at a time per terminal. `AppState.notepadEditing` keeps `focusIfActive` from taking the
keyboard back while you type in the pad.

What happens to a prompt after it was loaded is `NotepadAfterLoading` (`remove` by default, `strike`,
`keep`), and `NotepadPrompts.edit(afterLoading:…)` is the pure answer: the range to delete (the prompt
and the blank lines that separated it from the next one; the last prompt takes the gap before it
instead) or the text with the mark `~~…~~` around it. The text view applies it after the delivery
finished (`AppState.loadPrompt(…, onLoaded:)`), through its own editing methods, so ⌘Z works, and
finds the prompt again by its words, nearest to where it was. A struck prompt is plain text with
the marks — a restart keeps text, not attributes — and `restyle()` draws the line through it.

Return, Tab and a click go to the pad's Markdown rules first (`NotepadEditing`, pure): a list goes
on and the numbered items below are numbered again, an empty item ends the list, Tab moves an item,
a click on `[ ]` ticks it, ```` ``` ```` and Return writes the closing fence, code keeps its indent.
⌘B, ⌘I, ⌘E and a backtick over a selection toggle marks (`NotepadEditing.toggleMarks`), and a web
address pasted over words becomes a link (`NotepadEditing.link`); the text view's `paste(_:)`,
`insertText` and `performKeyEquivalent` ask the pad first. Each answer is one change through the
text view, so ⌘Z takes it back. Code is `NotepadCode` (pure):
which lines look like code (the bar under the pad offers to fence them), the fenced blocks, and the
colours of their tokens. A block longer than two lines folds while the insertion point is not in
it. The text is never shortened for that: the text view is TextKit 1, built by hand, and the layout
manager's delegate (`NotepadFolding`) gives the hidden characters null glyphs and their line breaks
zero advancement, so the closing fence row follows the second line; the text view draws the box
behind a block and the "more lines" label over the closing fence, which is made transparent by a
temporary attribute. What left the pad — prompts sent, deletions worth keeping, the text before
"Format with AI" — is `NotepadHistory`, kept like the text: `AppState.notepadHistory`, not
`@Published`, written to `TerminalSession.notepadHistory` on save. Single deleted characters are
gathered into one run and weighed when it ends; the pad's own edits, undo and redo are not recorded.
"Format with AI" is `AIAssist.formatNotepad`: the same `claude -p` as the summaries, on their queue,
in their empty directory with no tools, and an answer whose letters differ much from the pad's is
turned down (`NotepadFormat.isPlausible`). The context menu's "Format code with AI" sends one block's
code (`AIAssist.formatCode`) and puts the answer back only where that code still stands.

Markdown is drawn, never stored. `NotepadMarkdown.spans(in:)` (pure) finds headlines, fenced and
inline code, bold, italic, quotes and list items; `NotepadStyle.apply` turns the spans into attributes
and keeps the marks (`#`, `**`, backticks) in the text, dimmed — what is loaded into the terminal is
what was typed. The body size follows the width of the pad (`bodySize(forWidth:)`, 12–14 pt), and
headline scale is damped when the pad is narrow.

A key draws only what it made stale (`NotepadStyle.swift`): drawing the whole pad on every key cost
10–17 ms at 16 KB. `NotepadStyler` is the text storage's delegate. In `willProcessEditing` it notes
every change of characters (typing, paste, undo, a composition), keeps the list of fence lines
current, and draws the stale lines in that same round of editing. Drawn in a round of its own after
the key's, the same few attributes made TextKit 1 lay out everything below them again (39 ms per key
at 64 KB instead of 1). What an edit makes stale: its lines and one line on each side (`\r` and `\n`
that meet or part); every line below when a fence came or went, or up to the closing fence when only
the language changed; the whole prompt around it when a prompt there is, or was, struck through
(`~~…~~` strikes all of it); and whole lines until no composed character sequence is cut, because
AppKit picks one font for a line break and a combining mark after it. A new width or another number of
Returns per prompt draws everything. Nothing is drawn while an input method composes (`hasMarkedText`,
or `NotepadTextView.isSettingMarkedText`); the edits are kept and drawn when it ends. The folds and the
code boxes read the blocks off the same fence list (`NotepadStyler.blocks()`), not off a scan of the
text. The margin buttons and the code bar read the prompts the same way (`NotepadStyler.prompts`):
cut once, then kept with every edit — the prompts above the edit stay, those below move, and only
the prompts around it are cut again (`NotepadStyle.promptExtent` finds edges in text the edit did
not touch). Before, each key cut the whole text into prompts three times (4 ms each at 16 KB). The
code bar asks the fence list which lines are code already (`NotepadStyle.isFenced`). `NotepadStyleTests` holds the old full restyle verbatim and checks, after each of thousands of
seeded random edits, that the pad is attribute for attribute that full restyle.

**The Jira panel** (`JiraTickets.swift`, `Jira.swift`, `Keychain.swift`, `Views/JiraPanel.swift`). One
panel for the whole app, right of the tab and of the notepad, switched on in Settings (off by default,
like the to-do board's button: `todosEnabled`, `jiraEnabled`). `JiraLook` (site, e-mail, the saved JQL
queries, open, width) is persisted as `PersistedState.jira`; the API token is in the login Keychain
(`Keychain`, service `app.planchette.jira`), never in `state.json`, and an isolated instance touches
neither the Keychain nor Jira. The token is read from the Keychain once per launch and kept in memory
(`KeychainCache`; a write updates it, a Deny is kept too): the release is signed ad hoc, so each build
is a new app to the Keychain, and each read it was not "Always Allow"ed for asks for the login password. `JiraTickets` is the pure part: the site normalised to https, the
`/rest/api/3/search/jql` request (a `+` in the JQL is escaped, or Jira reads a space), the parse and the
errors. `Jira.swift` polls every five minutes and when the panel opens, single-flight, on its own
`URLSession` that follows a redirect only on the same host (the token is in the header). The answers
(`jiraResults`) are not in `state.json`: the last answer of each query is kept in `jira-cache.json`
beside it (`JiraCache`, only for the site, e-mail and JQL it was asked with) and shown as offline data
after a launch and while Jira cannot be reached (`JiraTickets.merge`: out of reach keeps the last
tickets, every other error replaces them). Switching the panel off or changing the site or e-mail
drops the cache. A poll that brings the same tickets publishes nothing (`JiraResult.sameContent`).
`AppState.init` calls `updateJiraPolling()` itself, since Swift runs no `didSet` there. The query editor's fields set `jiraEditing`, which keeps
`focusIfActive` from taking the keyboard back, and carry no Return/Esc shortcuts: a window-wide one
would take those keys from the terminal.

**The name of a tab** is the name of one terminal of it, kept in `SessionGroup.tabAnchors` (one per
tab) — not of the terminal that has the keyboard, which would rename the tab every time a pane is
clicked or a terminal is dropped into it. `TabStrip.speaker` answers the stored one, else the
first terminal; `TabStrip.carriedAnchors` carries the names over every change of the strip: a tab keeps
its own, two tabs that became one keep the one of the tab that was dropped *into*, and a tab
whose terminal left or was closed takes its first terminal. A click on a tab still brings the keyboard
to the pane it was last in.

A drag carries a `TabDragItem` (a tab, by its first terminal, or a pane) as **JSON**, never as
text: a terminal accepts dropped text and types it at the prompt. An undeclared type of our own
would be cleaner, but it never reaches a drop target in an unbundled build. The drop zones
(`SplitTabView`, `TerminalAreaView`) work over the terminal itself: the nearest edge of the pane
under the pointer decides where it splits.

**Messages shown once.** `OnboardingState` (inside `state.json`) remembers what the user
was told: the welcome screen of a first launch (no state file at all), the version that
ran last, and the "don't show this again" of the durable terminals prompt. After an
update, `AppState.evaluateOnboarding()` offers that prompt once per version to somebody
without durable terminals; the rules are `OnboardingState.durablePromptDue`, pure and
tested. A state file from before the key existed reads as a user who has seen it all.

## Windows

Multi-window: each `WindowModel` owns a set of group IDs and its own selection.
The main window has a stable UUID (`AppState.mainWindowID`) matching SwiftUI's
default `WindowGroup` value; secondary windows get fresh UUIDs.
`sanitizeWindows()` keeps the invariant "every group lives in exactly one
window" and guarantees a main window exists. Groups can move to a new window or
merge back; `WindowRegistry` maps window IDs to their `NSWindow` for raising and
key-window lookup.

A window also owns its **project folders** (`WindowModel.folders`): named,
collapsible boxes over its projects in the sidebar, each owning the order of the
projects inside it. Per window on purpose — the sidebar is a per-window view, so
moving a project to another window means putting it somewhere else.
`sanitizeFolders()` (called from `sanitizeWindows`) keeps a folder from naming a
project that left the window or already sits in another folder.

## Terminal surfaces

Each terminal is a `GhosttySurfaceView` (an `NSView`) wrapping one libghostty
surface + PTY, created with `PLANCHETTE_SESSION=<uuid>` in its environment.
`TerminalRegistry` (a `@MainActor` singleton) owns these views by session ID so
they survive SwiftUI re-layout (tab switches, view-mode changes, window
moves) — the running shell is never restarted by UI churn. `GhosttyRuntime`
holds the single `ghostty_app_t` and dispatches C-API callbacks
(title, pwd, clipboard) back onto the main actor via `NotificationCenter`.

**A hidden surface does no renderer work.** `syncOcclusion` tells libghostty whether a
surface can be seen (in a window, and that window visible). Stock libghostty v1.3.1 then
skips the draw but still rebuilds the frame (`updateFrame`: the cells, under the terminal
lock) on every wakeup of the renderer thread — each time a program in a background tab
prints — and keeps one screen-sized render target per frame of its swap chain. Our patch
(`vendor/patches/ghostty/0001-…`) skips `updateFrame` while hidden (once a first frame
exists) and marks the frame stale; a stale frame is not drawn — not even from the layer's
`display` callback on a resize — so the layer keeps what it showed until the first render
after the surface is visible again updates and draws. After 5 s hidden, the targets shrink
to 1×1 (Metal only; after waiting for the frames the GPU still draws): a tab switch or a
re-attach, which hides and shows within a frame, frees nothing.

**A surface needs an awake display.** libghostty's renderer creates a display link
(`CVDisplayLinkCreateWithActiveCGDisplays`), which fails with zero active displays —
a Mac whose screens are asleep — and `ghostty_surface_new` then returns nil (the
library reports `error.OutOfMemory`). That happens when the app launches at login
before the screen is up, and when an agent opens a terminal overnight through the
control API. The view used to log it and stay dead for good. `createSurface()` can be
repeated — the renderer is created *before* the terminal's process, so a failed
attempt starts nothing — and a terminal with no surface checks every 2 s whether a
display is awake (`CGGetActiveDisplayList`, which costs next to nothing, so it can wait
all night) and builds the surface when one is. The system's own wake notifications
(`screensDidWake`, `didChangeScreenParameters`) were not delivered when measured, so
nothing depends on them. If a display is awake and the attempt still fails,
`SurfaceRetry` backs off (1, 2, 4, 5 s … then every 30 s, never giving up). The
control API refuses a terminal without a surface instead of dropping what is typed
into it, and `session.new` leaves no empty tab behind when it cannot start one.

## The attention state machine

The core feature. Per-session state is `working → asking → done → free`, driven
entirely by **Claude Code hooks** (no output scraping):

```
UserPromptSubmit → working
Notification / PermissionRequest → asking   (+ notification for favorites)
Stop / SubagentStop → done
SessionEnd → free
```

Flow: Claude fires a hook → `planchette-hook` reads the event JSON on stdin plus
`$PLANCHETTE_SESSION` from its environment → sends it to the unix socket
(`$PLANCHETTE_SOCKET`, per app instance: `/tmp/planchette-<pid>.sock`; a durable
terminal's environment can name a dead instance, so the hook falls back to
`~/.planchette/socket`, which the live instance publishes) →
`HookServer` decodes it and calls
`AppState.applyHookEvent`, which routes by `PLANCHETTE_SESSION` to the exact
session. The inbox, menu-bar badge, and quick switcher are all just sorted views
over these states (favorites first, `asking` before `done`, longest-waiting
first). Focusing an `asking`/`done` terminal clears it.

**The forwarder is native; the script is its fallback.** Claude Code runs
`~/.planchette/planchette-hook` on every hook event of every agent — each tool call
twice — so its cost is paid thousands of times a day. The shell script started a shell,
`cat` and `nc` for each event (15–17 ms of CPU); `hook/planchette-hook.c` does the
same in one process (about 2.4 ms). The packaged app carries both, the helper universal
and signed in `Contents/Helpers`. At launch `HookInstaller.deployHook` writes the helper
beside the installed forwarder, runs it once (with no session it must exit 0 — a binary
macOS will not start fails that), and renames it into place; where it fails, the script
is installed. An installed helper is run again at every launch, so one that a later
policy or signature cache kills gives way to the script at once, not at the next
release; a staged copy a crash left behind is removed after a minute. Both under the
same name, so the command in the agents' configs never changes: an update rewrites no
config, and an older app after a downgrade finds its own command and puts its script
back. A `/bin/sh` wrapper choosing at every event would start a shell each time: about
6.4 ms, a third of the saving given back. The two must send the same bytes:
`scripts/test-hook-helper.sh` runs them side by side against fake sockets (every event,
binary-ish and 5 MB payloads, the pointer variants, stalled and closing apps), and the
fake apps check that each event ends with a half-close — the app answers on EOF, so a
forwarder that only closed would hold every tool call for the 5 s deadline. Two
differences are deliberate: the script's `nc` does not bound a write the app never
drains, the helper does, with the same 5 s deadline; and the helper also asks the kernel
who listens (`getpeereid`) and refuses another user, which the script cannot.

**What ends `running` and `waiting`.** Claude's own hooks, first (`Stop`,
`StopFailure`, `SessionEnd`, the tool events — a question only by the tool that asked it,
`AttentionState.questionStands`). Two things they cannot say are said by others: the
shell, with OSC 133 `D` right before its prompt (the foreground job is over — a command
that asked a question and ended, an abort with Ctrl+C, an agent that was killed), and
the screen (`claude_interrupted` and an idle prompt over a turn no hook closed — an
abort leaves no hook — each read on its own terms, the second only after two polls).
In a durable terminal the shell's marks come from Planchette's own zsh hooks, wrapped
for tmux's passthrough (`Durable.zshenvContents`): tmux keeps a raw OSC 133 to itself,
and Ghostty's integration loads only in a shell Ghostty starts. Its `exit` is seen through
`SHOW_CHILD_EXITED` and closes the terminal once tmux says the session is gone
(`Durable.sessionEnded`).
A shell reports when a command ends, never when it starts, so in a durable terminal the tmux
pane says the rest: every dev-server tick reads what runs in front of each shell
(`AppState.applyForegroundPrograms`). A program that appears there (`k9s`, a port-forward)
raises `running`; back at the prompt, a `running` this rule raised becomes `free` again —
for a shell that sends no `D` (`AttentionState.forForegroundProgram`). A live agent speaks
through its hooks and is never taken for a program.
A restart ends whatever a saved state described. Everything else a screen pattern could
decide it must not: it only applies where a Claude can be.

**Background work.** A finished turn does not mean Claude is done: it may still run
shells (`run_in_background`) or agents it launched without waiting. Claude Code sends
its own list with the `Stop` hook — `background_tasks`, each with `id`, `type`
(`shell` or `subagent`), `status` and a `description`. `BackgroundTasks` turns every
hook into one signal: a snapshot (`Stop`), a start (`PostToolUse` of a background
`Bash` or an agent that answered `isAsync`), an end (a `<task-notification>` prompt) or
a reset (a Claude process begins or ends). `AppState.backgroundTasks` holds the result
per terminal, never persisted — a restart ends the processes the tasks live in. The
sidebar draws it under the state icon, and `session.get` reports the counts.

A terminal that has any is shown as `running`: `AppState.setState` turns a requested `ready`
or `free` into `running` while the list is not empty (`AttentionState.settled`), whoever asked
— a hook, the screen, a finished command — and only the user's own "Mark as done" passes. The
turn is still known: `heldByBackground` keeps the state that was overridden, and the control
API goes by it (`turn_state`; the guard of `session.prompt`, `session.wait`). The icon is a
globe (`StatePixels.globe`, 13×13, still) instead of the robot while the turn is over
(`SessionStateIcon`). Settings → Terminals → Status turns the mark off.

**A granted permission.** Granting a permission fires no hook: Claude Code runs the tool and
says nothing until it is done, and an MCP call can take minutes. The screen is the only witness
— the dialog is gone and the footer of a live turn ("esc to interrupt") is there — so the rule
`claude_working` lets `AttentionState.fromScreen` move a `waiting` terminal back to `running`,
after two polls, and nothing else: starting work from idle stays the hooks' job.

**The status line, not the footer, says a turn is live.** Claude Code 2.1.301 prints no
"esc to interrupt" in the footer of a working turn in auto mode, so that footer
("auto mode on · ← for agents") looked like an idle prompt and freed a terminal that was
working. `claude_spinner` reads the status line instead ("✢ Whisking… (3m 59s · ↓ 4.9k
tokens)": an ellipsis, then the elapsed time in a parenthesis) and outranks the idle footer. A
finished turn prints "✻ Cooked for 1m 32s · done", which has neither.

The packaged app installs the hooks itself at launch (`HookInstaller`). For a dev run,
install them with `hook/install-hooks.sh` (merges into `~/.claude/settings.json`,
backs it up, and is a no-op outside Planchette terminals); it points the hooks at the
repository's shell script, not at the native helper.

### Snooze — the one thing that silences a terminal

A terminal or a whole project can be sent away until a moment (`Snooze.swift`:
in 1 hour, in 2 hours, the next 9:00). Snoozing sets the terminal free straight
away and stores `snoozedUntil`; while it runs, `AppState.isSnoozed` filters that
terminal out of the inbox, the counts, the dock and menu-bar badges and every
notification — including the escalation reminder. It does **not** freeze the
state machine: hooks and screen detection keep the color honest, the terminal
just stops asking for you. `checkSnoozeExpiry()` (every housekeeping tick, and
once after a restore, so a snooze that ran out while the app was closed still
speaks up) clears it and posts the reminder.

## Search

The search (`QuickSwitcherView`) works on a snapshot: `AppState.searchEntries()` copies
what is known about every terminal when the sheet opens, and the ranking runs against
that copy, so a state change while it is open cannot reorder the list under the user's
hand. The ranking is `SearchRanking.swift`, pure and unit-tested: the query is split into
words, every word has to match (AND), and each word scores by the tier it reaches in its
best field — whole word, start of a word, inside a word, initials, letters in order —
times that field's weight: the title counts three times what a summary does, the
project, PR number, branch and tags come next, then the note and the path, and the
task, summary and last message least. A `#number` matches a ticket or PR number. The best match in a field the row does
not already show becomes the hint line.

The keys that open it are `AppState.searchShortcut` (persisted; Settings → Shortcuts →
Search): a modifier tapped twice, or a chord. `SearchShortcutMonitor` is a *local*
`NSEvent` monitor, because a global one needs the Accessibility permission, and the
shortcut is for the app in front. Chords are consumed; a double tap never costs the
terminal a key. What counts as a double tap is `DoubleTapDetector`, pure: a press and a
release of the modifier alone, each under 0.3 s, the second ending within 0.5 s of the
first; any key, click or scroll in between ends the attempt, and it fires on the
release, so a Shift held to select never opens it. ⌘K stays a menu item whatever Settings
says.

## Tabs

A tab's name is `AppState.tabName(for:)`, from the source Settings → Tabs picks
(`TabLayout.name`; `TabNaming` holds the order the sources give way to each other, pure
and tested): the summary — the conversation title Claude Code writes into its transcript
(`AgentTitle`, in `agentTitles`), else the AI summary, else the last prompt — the last
prompt, the first prompt, or the classic ticket and prompt. A manual name beats all of
them. The split panes' title bars and the project overview use it too. The control API's `title`
does not: it is `displayTitle`, a contract other programs read, and a setting here must
not change it. The transcript sweep (`refreshContextUsage`) runs for the summary name as
it does for the context ring, and for nothing else.

The strip of tabs is a plain row while it fits (`ViewThatFits`) and a horizontal
`ScrollView` once it does not, with the + outside it so it never scrolls away. A mouse
wheel only turns vertically, so `WheelToHorizontalScroll` finds the `NSScrollView`
behind the strip and turns a mostly vertical wheel event into a sideways offset
(`WheelScroll.offset`, pure). A project is washed by `ProjectGradient` — its header, its label
in the project panel — in the color it was given; a project with no color is not tinted at
all. Settings → General → Project color (`ProjectColorLook`, persisted) decides where the
wash shows (off, the label, the whole project) and how strong it is (`ProjectColorStrength`:
colorful is the look 0.2.36 shipped, subtle the default, faint the quietest, off no gradient
at all — as does scope off, `ProjectColorLook.showsLabel` and `showsBody` say so); the numbers
are `ProjectWash.strengths`, pure and tested. Under an open label the terminals share one
softer fade. The list gives every terminal row a background of its own
(`.listRowBackground`), so each row paints the slice of the fade that lies at its place
(`ProjectWash.slice`, pure): a row ends exactly as strong as the next one starts. A background
on the project's `DisclosureGroup` would not do: it is handed to every row of the group, and
each row runs the whole fade.

## Feature hints

A big feature introduces itself once, at the moment it is useful (AGENTS.md, ground rule 8). A hint is
a `FeatureHint` case; `HintBook` (inside `OnboardingState`, persisted) knows which are switched off
("Don't show tips again", for all) and which feature was used (`completeHint`). `AppState.offerHint`
is the one gate: quiet before the window is up, over the durable terminals prompt, while another hint
is open, in an isolated instance, once per launch for each hint, and for a feature that was used.
It is called from user actions only (`userOpenedTerminal`), never from restore code — restoring a
workspace calls `addSession` for every terminal, and a hint offered there was gone before anybody
looked. `.featureHint(_:)` opens the card as a popover at its anchor half a second after
`hintShowing` names it (a popover requested while its anchor is being created is dropped). The card
shows `hints/<name>.gif` — in the bundle's `Resources/hints`, in a dev run in the repository — with
`NSImageView.animates`, then a title, one line and the way to try it. The GIFs are recorded from the
real app: `scripts/perf/notepad.py <binary> <scratch> gif` (with `HINT_GIF_OUT=hints/notepad.gif`).

## Find in a terminal

⌘F (Edit → Find…, Find Next, Find Previous) opens `TerminalFindBar` over the terminal in
front; `AppState.finds` holds what each open bar knows (`TerminalFind`). Two engines
answer, chosen per terminal. A plain one is searched by libghostty (`start_search`,
`search:<text>`, `navigate_search:next|previous`, `end_search` as binding actions on the
surface), which highlights the matches and reports the count and the selected match
back as actions (`GhosttyRuntime` turns them into `planchetteSurfaceSearch` events).
A durable terminal is searched in tmux, because its history lives there and libghostty
never sees it: the bar enters copy mode, goes to the newest line and runs
`search-backward-text`, one tmux call per pause in the typing (`Durable`'s Search
extension, pure argument lists), reads `#{search_count}` for the number, and leaves copy
mode on close. While the bar is open the terminal's surface does not take the keyboard
back (`TerminalSurfaceRepresentable.focusIfActive`).

## AI assist (on by default, can be switched off)

Settings explains what it does and has the switch. Stage 1 is deterministic:
`AIAssist`/`TranscriptReader` parse the Claude transcript JSONL for the last
prompt/answer. Stage 2 (only while enabled) shells out to `claude -p --model
haiku` to condense a transcript tail into a one-line summary + one-word topic,
throttled per session. Stage 3 proposes grouping sessions by shared topic —
applied only after explicit confirmation.

The transcript tail is untrusted text (web pages and files the agent opened), so
the summarizer is boxed in: it runs in its own empty directory (`summarizer/` in
the support directory — a GUI app's working directory is `/`, i.e. the whole
disk), with every tool switched off (`--tools ''`), and the prompt tells the model
to treat the material as data.

It also loads nothing of the user's Claude Code setup: no MCP server
(`--strict-mcp-config`), no skill or command (`--disable-slash-commands`), no hook
(`--settings '{"disableAllHooks":true}'`, a layer over the user's settings, so their
`env` and login still apply — never `--bare`, which skips the login), no saved session
(`--no-session-persistence`) and a short system prompt of its own. A plain `claude -p`
sent about 387,000 tokens per summary (every MCP tool and skill), ran every hook of the
user (seven per run) and wrote a 2.5 MB transcript; measured on Claude Code 2.1.332,
$0.39 against $0.002 a summary. An older `claude` that rejects a flag steps down a level
(`AIAssist.CommandLevel`: lean → tools off → plain), remembered for the session, and the
directory still applies. A summary runs on `Stop`, on a question and on a failed turn (`StopFailure`), not on
`SubagentStop` (the turn goes on), never for a transcript that did not change since the last one, and not at all for 15
minutes after three failed runs in a row (`SummaryBreaker`); every failure logs its exit
status and the start of stderr. A run that answered with something other than JSON is not
a failure — the setup works, one transcript did not summarize — and its transcript is not
sent again until it changes; an empty answer is. One run waits per terminal at most, with
the newest transcript path and folder.

## Robustness & security

The rules the code follows so that a slow tool, a hostile peer or a bad download
cannot hurt the app. Each one has a test in `HardeningTests.swift`.

**Helper processes have a deadline.** `Subprocess.run` is the only way the app
runs `git`, `lsof`, `tmux` or `gh`: it kills the child at its deadline, never
waits on a pipe a grandchild holds open, and closes stdin. A bare `Process` +
`readDataToEndOfFile()` + `waitUntilExit()` has no upper bound, and the pollers
call it from timers — one hung `git` plus a timer is a leak that grows until the
app is starved.

**Pollers are single-flight.** Branches, pull requests, dev servers and context
usage each run in a detached task on a timer. `SingleFlight` keeps a slow run
from being joined by a copy on the next tick; a request that arrives mid-run
(a `Stop` hook asking for a fresh context reading) is remembered and gets exactly
one more run, not dropped.

**A PR is asked about when git may have changed.** A hook asks `gh` about its own
terminal's checkout only: after a shell command that runs `gh` or a `git` that is
not only a read (`PullRequests.toolMayChangeGit`), and at the end of a turn unless
every tool call of it left git alone (`TurnGitRecord`; a shell command counts unless
all of it is a git read, since `make pr` can push). One checkout and branch is asked
at most once per `PullRequests.eagerGap`; a terminal that asks inside the gap waits
for its end, together with every other terminal that asks meanwhile (`EagerLookups`).

**A sweep asks GitHub once.** `PullRequests.lookup(_:)` sends the checkouts of a sweep as
one `gh api graphql --hostname github.com` call (`PullRequestBatch`: one aliased
`repository { pullRequests(headRefName:) }` per checkout, every owner, name and branch a
GraphQL variable, at most `PullRequestBatch.cap` per call) instead of one `gh pr list` process
each, and picks each answer by the same rule as `PullRequests.parse`. The repository must be
the one `gh pr list` asks in that folder, and gh's choice (remote order, `gh-resolved`,
`ssh -G`, `insteadOf`, the hosts it is logged in to) changes between gh releases, so the app
does not rebuild it: `gh repo view --json nameWithOwner,url` names it, run like `gh pr list`
in the checkout. `RepoCache` keeps that answer per checkout root while the files that decide
it keep their `stat` (the `.git` entry, the repository's `config` and `config.worktree`, the
user's git configs, `~/.ssh/config`, gh's `hosts.yml` and `config.yml`), for 24 hours, a
failure for 10 minutes. Only a github.com answer joins the batch; another host, a failure,
`GH_REPO` (which `gh repo view` ignores) and a checkout outside a repository keep their own
`gh pr list`. A root the cache does not know is answered by its own `gh pr list` while its
`gh repo view` runs beside it, so a first sweep is never slower than the old one-by-one
lookups: everything runs in one pool of at most four `gh` processes. An alias GitHub answers
with an error (a repository that is gone or hidden), or a `data` object of the wrong shape,
is looked up alone; a call without `data` (no network, bad credentials, a rate limit) fails
its checkouts, since lookups alone share the token and the limit. Fallbacks are logged once
per checkout and reason (`Log.debug`). `PLANCHETTE_LIVE_GH=1` runs a test that compares the
batch with `gh pr list` against GitHub.

**The branch is read, not asked.** `Titles.headState` reads `.git/HEAD`;
`Worktrees.currentBranch` asks git only when the file cannot answer: the reftable
layout (whose HEAD is a stub), or a `.git` entry that exists but is unusable (a
worktree whose git dir is gone — git reports an error there, and climbing on into
the repository around it would show *its* branch). The walk starts from the
*physical* path (`realpath`), as git does: a symlinked projects folder
(`~/code -> /Volumes/work/code`) never reaches its repository by way of the logical
path, and an unrelated repository on that path (a dotfiles repo in `$HOME`) must not
be consulted. A subprocess per directory every ten seconds, around the clock, was
the poll's whole cost. The `HEAD` and a worktree's `.git` file are read again only when
a `stat` says they changed (`StatCachedText`). A dev server's listening socket and working directory come
from libproc (`DevServerScanner.listeningSockets`, `proc_pidinfo`), not from `lsof`,
which is only the fallback when the process list cannot be read; a scan that failed
publishes nothing, so servers do not vanish from the sidebar because one read failed.
A database tunnel's command line comes from the kernel too (`Durable.kernelChildArguments`),
with `ps` as the fallback.

**What counts as a change.** `AppState.update` drops a write that equals what is
stored, so no publish and no save. A terminal title is therefore stored without
its leading status glyph (`TerminalSession.cleanedTitle`): programs animate that
glyph, and every frame used to be a "different" title. `SaveDebounce` caps how
long the oldest unsaved change can wait — a trailing debounce alone never saves
while changes keep arriving less than a second apart. `saveNow` writes nothing when the encoded state equals the bytes
it wrote last (it is asked on every resign and hide), and a scrollback snapshot is
written only for a terminal whose text changed since its last one, whose file is
missing, or at quit (a synchronous save always writes). A screen reading
whose viewport and rules are unchanged gives the kept verdict (`ScreenReadings`);
everything after the verdict — `fromScreen`, `ScreenConfirmation` — still runs.

**The socket trusts the kernel, not the file name.** `HookServer` lives in
`/tmp`. The file is 0600, and every accepted connection is also checked with
`getpeereid`; reads share one 5 s deadline and a 4 MiB cap, at most 64 connections
are *read* at once, descriptors are close-on-exec with `SO_NOSIGPIPE`. A connection
holds its slot only while its request is read: a `session.wait` is answered minutes
later, and 64 of them would otherwise leave no slot for the hook events that keep
every terminal's state true. Requests that wait for an answer are bounded on their
own (64), and a wait ends when its caller closes the connection — detected with
kqueue's `EV_EOF`, because `poll` reports a closed client and one that merely
half-closed (the protocol: "the app answers on EOF") the same way. The hook forwarder,
the CLI and the notification click command check that the socket is owned by the
current user — and is not a symlink, which could be swapped for another listener
between the check and the connect — before they hand it anything; the CLI and the
native hook helper then ask the kernel (`LOCAL_PEERCRED`, `getpeereid`) who is listening. An event carries the prompt you just
typed. See [API.md](API.md#limits).

**Config files are not ours to break.** `HookInstaller` writes to the *resolved*
path of `settings.json`, `hooks.json` and `config.toml`: an atomic write replaces
a symlink with a regular file, and dotfile managers keep these as links. The
backup copies the real file, not the link. A link whose target does not exist yet
(dotfiles not checked out) is followed and the target created; one into a read-only
store (home-manager, nix) fails with a message that says so and is left as it was.
`hook/install-hooks.sh` keeps the file's mode: `settings.json` can hold secrets in
`env`.

**The clipboard asks.** libghostty's protections — confirm before a program reads
the clipboard (OSC 52), confirm before an unsafe paste, and, with
`clipboard-write = ask`, before a program writes it — end in
`confirm_read_clipboard_cb` / `write_clipboard_cb(confirm: true)`. They used to be
answered "yes" (the write's flag was ignored). `ClipboardConfirmation` asks instead.
The dialog is **only ever a sheet on the window of the terminal that asked**: a
terminal in a background tab or a hidden app has no window the user could connect to
the question, so a request a program started there is refused quietly (and that
terminal is quiet for 30 s). One sheet per window — `Gate` — and a program that was
refused is not asked again for 30 s. The safe button is the default and first; the
preview shows what a paste hides: control characters, bidirectional overrides,
zero-width and separator characters appear as `␛` / `⟨U+202E⟩`. Denying completes the
request with an empty string (never leave it open: `state` is owed a completion),
except a denied *write*, which must not complete at all — completing writes the
string, and `""` would clear the clipboard.

**A dialog never stops the app.** `NSAlert.runModal()` spins a nested run loop. Started
from inside a block the main *dispatch queue* is running — every `await`
continuation on the main actor, every `DispatchQueue.main.async` — that loop does not
run the queue's other blocks. libghostty's wake-up (`GhosttyRuntime.tick`), hook
events and control-API replies are such blocks: with the update dialog left open, no
terminal's output was processed, the library's mailbox filled, the IO threads blocked
and the agents behind them stopped on their next write (measured: a loop in a terminal
ran about 140 iterations and stood still; the control API never answered). A timer or
a run-loop source does not have the problem, so `ModalAlert` runs the alert from a
`CFRunLoopPerformBlock` callout and the caller awaits it. Every alert that can appear
from async code goes through it; clipboard dialogs are sheets and need nothing.

**Links that would run something are revealed, not opened.** `GhosttyRuntime.action`
sends a ⌘-clicked `file:` link to Finder when opening it would launch an app, a
`.command` script or anything executable. The decision is made on the *resolved*
target (`realpath`, Finder aliases), checking the extension of the link and of what
it points to, and the content type; document packages (`.xcodeproj`, `.rtfd`) are
folders for this purpose and open. What is opened is the resolved target, so the
file that was judged is the file that is opened.

**Sleeping Claude.** An idle Claude session holds 150–500 MB with its MCP servers. With
`ClaudeSleep` on, the housekeeping tick ends the Claude of a terminal that is idle, unseen work
done, nothing in the background and not on screen (`ClaudeSleep.shouldSleep`), by SIGTERM to the
`claude` process found through its `PLANCHETTE_SESSION` (`ClaudeProcess`). The terminal keeps the
conversation id (`sleepingClaudeID`, persisted) and wakes on focus or selection with the restore
line, `claude --resume <id>`.

**tmux not answering is not "nothing is running".** A durable terminal's agent outlives
the app; a restore replays scrollback or `claude --resume` only into a session tmux
reports as gone. `Durable.listSessions()` returns `nil` when tmux did not answer in
time, and `liveIDsForRestore` then assumes every durable session is alive — replaying
into a live TUI would `cat` a stale snapshot over it and start a second agent.

## Packaging & updates

`scripts/package.sh` builds a release binary, assembles `Planchette.app`
(Info.plist, icon, bundled Ghostty resources, ad-hoc codesign) and a `.dmg`.
The ad-hoc signature's designated requirement is pinned to the bundle identifier,
not left at the default cdhash: macOS keys its privacy answers (folder access of the
shells Planchette starts) on that requirement, and a cdhash changes with every build,
so each update asked for every folder again.
`scripts/release.sh X.Y.Z` tags `vX.Y.Z` on the default branch and publishes a
GitHub Release with the DMG. `UpdateService` polls `/releases/latest`, compares
the tag to the running `CFBundleShortVersionString` with `Semver`, and offers
the download — so "new stable version on the default branch → offered as update"
is the whole loop. No Sparkle, no appcast server.

What stands between a release and the running app: redirects must stay on
GitHub's hosts over HTTPS, the download must answer 200 and stay under 250 MB, and
the in-app install needs the release's `SHA256SUMS` (a release without one takes
the manual DMG path). The zip is hashed in chunks and unpacked off the main thread
— a main-thread `ditto` froze the window, spinner included. Before anything is
swapped, `UpdateService.verifyBundle` requires the same bundle identifier, a version
equal to the release tag and newer than the running app (no rollback, no update
that offers itself again), and a passing `codesign --verify --deep --strict`.
The app is ad-hoc signed, so that last check proves the bundle is complete and
unmodified, not who signed it; a Developer ID signature (and notarization) would turn it into
proof of origin, and is the one hardening here that needs an account rather than
code. Every file the
updater puts in the temp folder is removed again, in every outcome; leftovers from
older versions are swept at launch. The swap helper only ever receives a directory
that Swift has checked is an extraction of ours (`cleanupDirectory(forStagedBundle:)`:
the path is resolved first — so a symlink cannot aim the cleanup elsewhere — and must
be `<temp>/planchette-update-<id>/<name>.app`), and repeats the name check itself;
whatever fails, the installed app stays in place.

## Platform note

macOS is implemented. A Linux frontend (Zig + GTK4 against libghostty) is
planned but gated on libghostty's embedding API stabilizing; the pure-logic core
(state machine, persistence model, hook protocol) is portable.
