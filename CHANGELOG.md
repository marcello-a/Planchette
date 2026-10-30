# Changelog

All notable changes to **Planchette** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Existing users receive each release via the in-app updater (Install & Relaunch).

## [Unreleased]

### Added
- **Main terminals.** Right-click a terminal (in the project panel or on its tab) → "Mark as main
  terminal": it carries a star and stays under its project, also while the project is folded —
  with "Collapse all" too.
- **Reviews, beside the bell.** A new icon left of the notifications bell switches the right panel
  to the pull requests that ask for your review — the same panel, rows and colours, by stage:
  *Needs you*, *Reviewing*, *Sent*. A blue dot says a new request is in; a banner says it once.
  GitHub is asked every five minutes through `gh`.
- **Start a review where nobody works.** A request opens in place and offers the checkouts of its
  repo that are free — no agent running or open on a work branch, no unread result, no
  uncommitted changes, no dev server — the one untouched longest first, or a temporary worktree
  that goes once the review is sent. The review runs as the `review-pr` Claude Code skill in a
  new terminal there; a click on the row goes to it.
- **Decide on every finding before anything is sent.** The findings open in the panel, most
  severe first, each with Comment (with a suggestion where the finding has one), Fix (a commit on
  the author's branch) or Skip — preselected from the severity, and "Set all" changes them at once.
  The verdict follows the decisions. Nothing reaches GitHub before "Send review".
- **A default `review-pr` skill.** A review runs as the Claude Code skill `review-pr`. Without one
  of your own, Planchette adds its default to `~/.claude/skills/review-pr` the first time a review
  starts, and keeps it up to date; a `review-pr` skill of your own there is never touched.
- A first-use hint for the Reviews, with a looping picture, when the first review request arrives.
- `planchette review list` / `review.list`: the Reviews panel as data.

### Changed
- **A project with one terminal is one row.** No disclosure arrow, and no second row that repeats
  the name, the path and the state: the state icon, the project's name, then what it is doing and
  since when. A second terminal turns it back into a list. Settings → Project panel → Projects →
  Layout turns it off.
- **Detail level:** *Minimal*, *Standard* or *Everything* sets the project panel's detail switches
  in one click (Settings → Project panel → Terminals), with a live example of a row. Any switch can
  change afterwards; the level then shows *Custom*.
- **The notepad opens and closes per terminal.** ⌘J and the tab bar's button act on the terminal
  you are in; the others keep their own pad, open or closed. A pad that was open for all comes up
  open for every terminal once after the update.
- **Drag and drop in the project panel.** A terminal onto a project moves it there, onto another
  terminal places it above or below; a folder onto a folder reorders them, its projects with it;
  a project goes into any folder, or next to a project in another folder. The drags travel as
  JSON, so a project dropped on a terminal no longer types its id into the shell.
- **Tree lines.** Thin lines in the folder's or the project's colour tie a folder to its projects
  and a project to its terminals; each ends at the child's state icon. A project with one terminal
  stands in the same column as the arrow of the others.
- **A selected folder marks what is in it:** its projects and terminals get a faint tint of the
  folder's colour, barely there.
- The colour dot of a project sits at the right end of its row and turns into the close button on
  hover; the count badges stay visible.
- The branch shows only when it is a work branch: `main`, `master`, `develop` and `trunk` say
  nothing about a checkout. "Also main and master" shows them again.

- The notepad button in the tab bar is yellow while the pad is closed, so it is easy to find.
- The pull request next to a branch follows a branch switch at once. When you or an agent run `git checkout`, `git switch`, `gh pr create` or `git push`, Planchette looks again after the command or the turn ends. Before, it took up to a minute. The PR of the old branch goes away right away and does not stay until the new one loads.
- A `cd` into another repository shows its branch and PR at once, and so does coming back to Planchette from another app.
- A failed GitHub request (no network, a timeout) keeps the PR pills as they were. Before, one failed request took every pill away for a minute.
- After a branch switch, the ticket in a tab name follows the new branch. Before, it could keep the old ticket until something else redrew the tab.
- **Only the latest release is installed, never one after the other.** A update that waits for the next quit is replaced when a newer release comes out, and the repeating check keeps looking while one waits. Before, the old one installed first and the newer one was offered at the next launch.
- **The last session comes back without a question.** After an update, a crash or a plain quit, Planchette restores your workspace at launch by itself. Settings → General → "Ask before restoring the last session" brings the Restore / Start fresh question back (off by default).
- The update dialog puts **Install & Relaunch** on top as the highlighted default button; "Install on quit" is second.

### Fixed
- Closing the notepad widens the terminal at once. It used to keep its old width until its next
  redraw, a moment later.

## [0.2.46] — 2026-10-23

### Fixed
- **A terminal whose Claude published an artifact goes back to done after its turn.** Claude Code
  keeps an artifact's live link open in the background, and Planchette counted it as a running
  shell: the terminal kept its globe and stayed "running" until Claude quit. Only shells and
  agents count now; a watch, an idle teammate and Claude's own housekeeping do not.

## [0.2.45] — 2026-10-17

### Added
- The notepad shows Markdown as you type: headlines, lists, quotes, code blocks, inline code, bold and italic. The text stays exactly as typed, so a prompt reaches the terminal unchanged. The type size follows the width of the pad, and headlines are tamed in a narrow pad, so sentences stay easy to read.
- A second button at every prompt adds it to the terminal and presses Return. The first button (new icon) still adds it as a draft.
- Feature hints: somebody who never used the notepad sees a short card with a looping picture of it when they open a new terminal, with a "Don't show tips again" checkbox. Later big features use the same card.

### Changed
- A fenced code block (```` ``` ````) is one prompt: a blank line inside it no longer ends the prompt.
- The run button starts the prompt on a new line when Claude Code's input box already holds text, so it does not run into what was typed there.
- ⌥-click on the load button no longer presses Return: the second button does that. ⌘↩ in a prompt still does.

## [0.2.44] — 2026-10-17

### Fixed
- **A terminal moved into a tab no longer renames it.** The tab keeps the name of the terminal it was
  made for — also when the moved terminal is dropped on the left or top edge, or has the keyboard
  afterwards, and when you click another pane. The name changes only when that terminal is closed
  or taken out of the tab; the next one in the tab then gives it its name. Where two tabs become one
  (Combine All Tabs), the first tab's name stays.

### Changed
- **A prompt that was loaded from the notepad leaves it.** Whatever is in the pad is what is still
  to do. It goes with the gap it leaves, so the rest stays as it was, and ⌘Z gives it back.
  Settings → Tabs → Notepad → *After a prompt is loaded* can strike it through instead (it stays,
  between `~~` marks, drawn with a line through it and a check in the margin; loading it again
  sends the words without the marks) or leave it as it is.
- **The notifications panel's row menu is shorter.** "Mark as done" is on top, "Mark as
  unread" (or "Mark as read") below it, then a line and the reminder and note items. The
  Rename item is gone from this menu; it stays in the project panel and on the tab.

## [0.2.43] — 2026-10-17

### Added
- **A notepad for every terminal, at the right of the tab.** Open it with the note button in the
  tab bar or ⌘J; close it with its ✕. Drag its edge to change the width. What you write is saved
  with the workspace — on every change, and again when the app quits — and the pad stays open at
  the width you left it. A prompt runs to the blank line that ends it (two Returns; Settings →
  Tabs → Notepad makes it one or three), so it can be several lines long. The ▶ in the margin
  loads the prompt into the terminal's prompt without running it; ⌥-click, or ⌘↩ inside the
  prompt, also presses Return.

### Fixed
- **A field next to a terminal keeps the keyboard.** The terminal took it back whenever SwiftUI
  re-attached it — in the middle of a word typed in the notepad — and answered ⌘V, ⌘A and ⌘Z that
  belonged to the field. It now does neither.

## [0.2.42] — 2026-10-16

### Added
- **Split a tab, as in iTerm2.** A tab can hold several terminals side by side. Drag a tab onto
  the edge of the terminal in front and the view splits there; drag a pane's title bar onto the
  tab bar to make it a tab again, or onto a tab to put it before that one. A tab with several
  panes shows a count, and the state of the most urgent pane — a question in a pane you cannot
  see is not hidden behind a calm one. Click into a pane, or its title bar, to give it the
  keyboard; coming back to a tab returns to the pane you were in.
- **Split Right (⌘D) and Split Down (⌘⇧D).** A new terminal in the project's folder, split off
  the one you are in. They are buttons in the tab bar and items of the Session menu.
- **Combine All Tabs and Separate All Panes**, next to them: every tab of a project in one view,
  as a grid, or every pane in a tab of its own.
- **A close button at the end of every tab.** It asks first, because closing a tab ends the
  terminal's session.

### Changed
- **The notification bell shows the red dot, not a number.** The count stays in the panel's
  title and in a screen reader's voice.
- **The cluster view is gone; the split tab replaces it.** A project that was in cluster mode
  opens as one tab holding the same panes in the same arrangement, and a saved arrangement keeps
  its splits. *Combine All Tabs* is the button for "everything at once". The pane drag of the
  cluster view now also works over the terminal itself, not only over its title.
- **Closing a terminal hands the keyboard to its neighbour:** the next pane of its tab, else the
  next tab, else the one before — it used to be the last terminal of the project.
- **A tab's menu has three separate close items:** *Close Tabs to the Left*, *Close This Tab* and
  *Close Tabs to the Right*. Each asks first and is greyed out when it has nothing to close.
- **"Look at code" moved from the header into a tab's right-click menu.** The header keeps room
  for the dev-server links. The menu has the same three things: *Look at code*, *Open in* and
  *Default IDE*.

### Fixed
- **The terminal only answers ⌘ shortcuts while it has the keyboard.** With a field next to it
  (the notepad, the find bar) ⌘V, ⌘A and ⌘Z belong to the field.
- **⌘D reaches the Session menu.** The terminal took it and typed it at the prompt.
- **A tab opens from a click anywhere on it.** Only the icon and the letters of the name took
  the click; the padding and the gaps between the chips did not.

## [0.2.41] — 2026-10-16

### Fixed
- **A terminal that is working no longer shows as free.** Claude Code 2.1.301 prints no
  "esc to interrupt" under a working turn in auto mode, so its footer looked like an idle
  prompt and the screen reader freed the terminal, even for a long Bash call or a long
  thought. The reader now takes the live status line ("Whisking… (3m 59s · …)") as proof that
  the turn runs.

## [0.2.40] — 2026-10-16

### Changed
- **"Only active" no longer lists the terminals that are running.** A terminal that works does
  not need you, and "Only active" is the list of what does: waiting, failed, and finished ones
  whose done check is still there. A new "Show running" checkbox next to it brings the working
  terminals back; it matters only while "Only active" is ticked. `notification list` follows:
  `--only-active` leaves running terminals out, `--include-running` adds them.

## [0.2.39] — 2026-10-16

### Added
- **A fourth intensity: Off.** Settings → General → Project color → Intensity can turn the
  gradient off completely, as Show the color on → Off already could. Off in either of the two
  wins, and the other one dims.

### Changed
- **"Mark as ready" is now "Mark as done"** in a terminal's menu, and the same in the other
  languages. It does what it did: you are done with this terminal, so it goes back to free
  and counts as read.

### Removed
- **"Mark as finished" is gone**, and with it the seal on a finished terminal, the dimmed
  row, and the "Finished mark" switch in Settings → Project panel. "Mark as done" already
  says you are finished with a terminal. A state file that still holds the mark loads as
  before and loses it at the next save.

## [0.2.38] — 2026-10-16

### Changed
- **A terminal that runs a shell or an agent in the background shows as running, with a globe.**
  A turn that ends while Claude still runs something in the background (`run_in_background`, an
  agent launched without waiting) used to turn the terminal green or gray; it now stays purple until
  that work is over, and then Claude's report of it makes it done as usual. The icon is a globe, not
  the robot, so "working for you" and "something runs in the background" are told apart; the
  Information tab explains it. A question or an error still wins. Settings → Project panel →
  Behavior turns it off. The control API keeps talking about the
  turn: `turn_state` says what it is, and `session.prompt` and `session.wait` go by it.

### Fixed
- **A permission you granted no longer leaves the terminal on "waiting".** Claude Code fires no
  event when you answer a dialog, so a terminal that had asked — for a Bash command, for a call to
  an MCP server — stayed blue through the whole call, and an MCP call can take minutes. The screen
  now notices that the dialog is gone and the footer of a live turn is there, and the terminal goes
  back to running.

## [0.2.37] — 2026-10-15

### Added
- **Settings → General → Project color.** Where the color of a project shows — nowhere,
  on its label only, or over the whole project — and how strong it is: colorful, subtle or
  faint. An example below the choices shows both a project with a color and one without.

### Changed
- **The project color is subtler by default, and None means no tint.** The gradient of 0.2.36
  read as heavy, so what you get now is "subtle", about half as strong; "colorful" is the old
  look. A project whose color is None is no longer tinted in the violet of the app icon: it
  stays plain, in the panel, above its terminal and on its overview page.
- **The line under a terminal says the session title by default.** The name Claude Code
  gives the conversation still says what a terminal is for hours into it, when the last
  prompt has become "ja, mach". A terminal without a title yet shows its last prompt.
  Settings → Project panel → Terminals → Source picks another one. If you ran 0.2.36 and
  never changed the source, it moves to the session title once.
- **Settings → Project panel → Behavior shows the done check** in front of "Clear the done
  check after": the icon that setting is about.

## [0.2.36] — 2026-10-15

### Added
- **Search from anywhere with Shift twice.** Tap Shift two times in a Planchette
  window, whatever has the focus, and the search opens over it; the same keys close
  it again. Settings → General → Search changes the keys: tap another modifier twice
  (⌃, ⌥ or ⌘), or press a key with ⌘, ⌃ or ⌥ held — the terminal never sees that
  chord. Keys the app or macOS already uses are refused, with the reason. ⌘K stays in
  the Session menu. The magnifier in the bottom bar of the Project panel names the
  keys in its tooltip.
- **A welcome for somebody who has never run Planchette.** Until the first project
  exists, the main area says what the app is for: first the feature that sets it
  apart — your projects, terminals, scrollback and Claude conversations come back after a
  quit, an update or a restart — then the state icons, the search keys and the
  notifications, the durable terminals with the install command right there (copy it, or
  open a terminal with it typed), and where the settings are. After the first project an
  empty window is the small start screen again.
- **Find in a terminal: ⌘F.** A bar opens over the terminal in front; as you type it
  highlights every match, says how many there are, and Enter and ⇧Enter (or ⌘G and
  ⌘⇧G) step through them. Esc closes it. A plain terminal is searched by libghostty,
  scrollback included. A durable terminal keeps its history in tmux, where libghostty
  cannot see it, so there the search runs in tmux's copy mode — the bar is the same,
  and tmux does the highlighting. Edit → Find… has the same commands.
- **Settings → Tabs.** What a tab is named after — the summary, the last prompt, the
  first prompt, or the old ticket and last prompt — and what else it carries: the
  folder, the branch, the tags. The branch is off by default. An example at the top
  shows the result of each choice as you make it.
- **After an update, a one-time offer of durable terminals.** If tmux is missing or the
  switch is off, the first launch of each new version says in a few lines what durable
  terminals do and why they help, with the install command and one click to a terminal
  with it typed — or the switch, when tmux is already there. The card notices by itself
  when tmux appears. "Don't show this again" ends it for good; it never shows twice for
  one version, and never to somebody who has durable terminals.

### Changed
- **The search finds what you mean.** It takes words in any order and matches each one
  against the title, path, project, branch, tags, note, task, summary, last message,
  the pull request's title and number, and what runs in the background: whole words
  first, then the start of a word, then the middle of one, then initials (`gwm`) and
  letters in order. `#2093` goes straight to the ticket or the PR with that number.
  The matched letters are bold, and when the best match is not on the row (a note, a
  summary, a PR title) one line under it says where it was found. An empty result says
  so, and the footer lists the keys.
- **A tab is named after the session's summary, not after the branch.** The name Claude
  Code gives the conversation, else the AI summary, else your last prompt. The ticket
  of the branch is no longer part of the name, so three terminals in one checkout no
  longer wear the same one; "ticket and last prompt" is a choice in Settings → Tabs.
  The cluster tiles and the project overview use the same name. The `title` a program
  reads with `planchette session list` is unchanged.
- **The tab bar scrolls, and the + stays.** With more tabs than fit, the bar scrolls with
  a swipe and with the mouse wheel (up and down turns it sideways), keeps the tab you
  are in on screen, and the + that adds a terminal no longer scrolls away with the tabs.
- **A project wears its color as a gradient.** The color picked in the project's Color menu,
  and the violet of the app icon until you pick one: strongest at the left, fading out to the
  right. It tints the project's header (the tab bar and the project overview) and its label in
  the project panel; under an open label, one soft wash of the same color lies behind all of
  its terminals. A collapsed panel shows the project as a tile of the same color. The icon's
  violet is dark, so it is shown at full strength on a dark window and as a lighter tint of
  the same hue on a light one.
- **The gear opens the Project panel settings**, not Information. Settings opens on
  the tab you used last.
- **The update dialog lists every change, and each point opens to its full text.** It
  showed five headlines and "…and 7 more", and nothing more of any entry. Now all of
  them are there, in a list that scrolls inside the dialog so the buttons stay in
  reach, each closed to its headline with the kind of change above it (Added, Fixed,
  Security). Click a point to read its whole entry, or "Expand all".
- **"Only active" in the Notifications panel keeps fresh results.** It hid every finished
  (green) terminal, so a turn that ended a minute ago dropped out of the list the moment you
  ticked it. Now it keeps what is running, waiting or failed, and the finished terminals whose
  done check has not cleared yet; only the terminals that are free again are left out. How long
  a done check lasts is still Settings → Project panel → "Clear the done check after". The
  checkbox has a tooltip now, and `only_active` of `notification list` follows the same rule.
- **A project with one terminal opens that terminal.** Clicking the row of a project that
  holds a single terminal opened its overview page, which was one card between you and the
  terminal. The click now opens the terminal. A project with several terminals, or with none
  yet, still opens its overview.

### Fixed
- **A finished command ends its question.** `brew install` asks "(y/n)", the icon
  turns into a blue "?", the command ends — and the "?" stayed, as did a purple robot
  after a command you stopped with Ctrl+C. The prompt coming back means the foreground
  job is over, so a finished or aborted command now sets the state its exit code names
  (a check for success, red for a failure, gray for Ctrl+C) whatever the icon showed.
  A Claude that was killed (`kill -9`, a crash) shows an error instead of running for
  ever, and a restart no longer brings back a purple or blue terminal whose process is
  gone. (A durable terminal still hears nothing of its commands: tmux does not pass
  that signal on.)
- **Claude's screen patterns no longer read other programs.** In a terminal where
  Claude once ran, the "Do you want to continue?" of `apt` or `brew` raised the
  question again after every command. The patterns now apply only while a Claude is
  live, and in durable terminals, whose Claude can outlive a restart.
- **Stopping Claude frees the icon in every case.** Ctrl+C or Esc before Claude has
  printed anything puts your prompt back into the input and prints no "Interrupted"
  line, and Claude Code sends no hook either: the icon ran on. An idle prompt that
  holds on two readings now ends such a turn (every permission mode's footer is read,
  not only "? for shortcuts"). Esc at a permission dialog no longer leaves the "?",
  and the "Interrupted" marker is found when a narrow pane clips or wraps it.

## [0.2.35] — 2026-10-14

### Added
- **Background agents and shells show under the state icon.** When Claude Code
  runs something in the background — a dev server it started with
  `run_in_background`, an agent it launched without waiting for it — the
  terminal's row gets a small terminal symbol under the state icon, with the
  number inside it from two on. Hover for what runs. A terminal that looks idle
  is often not: this says so. Planchette uses the list Claude Code itself sends
  when a turn ends (`background_tasks` in the `Stop` hook), adds a task the
  moment a tool call starts one, and drops it when its end notice arrives. The
  tasks belong to the Claude process, so they survive `/clear`. On by default;
  Settings → Project panel has a switch. It needs a Claude Code that sends that
  list (2.1.299 does); with an older one the symbol never shows. `session get`
  reports the same counts as `background_tasks`, so an agent can see that a
  `ready` terminal is not done yet.
- **A tag list you can edit.** Settings → Project panel → Tags lists the tags a
  terminal's Tags menu offers — the four suggestions at first. Add, rename or delete
  tags there. A rename or a delete reaches every terminal that carries the tag and
  the saved arrangements, so none of them brings it back; deleting a tag that is in
  use asks first. A tag made with "New tag…" shows below the list until you add it,
  and "Restore default list" brings the four suggestions back.

### Security
- **The clipboard asks first.** A program in a terminal that asks to read your
  clipboard (OSC 52), and a paste that could run commands the moment it arrives,
  now ask for your OK — as they do in Ghostty itself. Both were approved without
  asking, so running `cat` on an untrusted file or opening an `ssh` session to a
  hostile host was enough to read out whatever you had last copied. The question
  is a sheet on the window of the terminal that asked; a program in a background
  tab, which you could not connect to the question, is refused without asking. The
  safe button is the default, a program you refused is not allowed to ask again for
  30 seconds, the preview shows invisible characters (escape codes, right-to-left
  overrides, zero-width characters) instead of hiding them, and an ordinary
  bracketed paste (what your shell and Claude Code use) is not interrupted. With
  `clipboard-write = ask` in your Ghostty config, a program that wants to *replace*
  your clipboard asks too — that setting was ignored.
- **Only you can talk to Planchette's socket.** The app now checks who is on the
  other end of every connection instead of trusting the file mode of a socket in
  `/tmp`, and the hook, the `planchette` CLI and the notification click refuse a
  socket that another user owns — or a symlink to one, which could be swapped for
  another listener between the check and the connect; the CLI also asks the kernel
  who is listening. An event carries the prompt you just typed. Connections are
  bounded too: one 5-second deadline for a request, 4 MiB at most, 64 being read
  at a time and 64 requests waiting for an answer.
- **An update has to prove it is an update.** Redirects stay on GitHub over HTTPS, the
  download must answer 200 and stay under 250 MB, and the in-app install needs the
  release's `SHA256SUMS` (without it you get the manual download instead). The
  unpacked app must have the same identity, the version of the release and a newer
  one than the running app, and an intact signature — before the running app is
  touched.
- **A link that would run something is shown, not run.** ⌘-clicking a `file:` path in
  terminal output opens documents and folders as before, but an application, a
  `.command` script or an executable is revealed in Finder instead of started —
  also when the link goes through a symlink or a Finder alias, which are looked
  through before the decision.
- **The AI summaries cannot be steered into your files.** The summarizer reads
  transcript text that came from web pages and files; it now runs in an empty
  directory of its own with all tools switched off (where your `claude` supports
  that), and is told to treat that text as data.
- **Planchette's support folder is private** (mode 0700), including on installs that
  predate this release: it holds working directories, session ids and terminal
  scrollback.

### Fixed
- **A finished background task is no longer shown as the terminal's task.** Claude
  Code announces the end of a shell or an agent as a prompt (`<task-notification>…`),
  and the sidebar printed that as what the terminal was working on.
- **`planchette session prompt` submits again.** It typed the text with a carriage
  return inside the paste, and a program that asked for bracketed paste — zsh (the
  macOS default), fish, and Claude Code — took that for a line break in the text:
  the prompt sat in the input box, with an extra empty line, unsent. Enter is now a
  key press after the paste. Measured with Claude Code 2.1.299 against a stand-in
  API: 30 of 30 prompts submitted (none before), multi-line and special characters
  arrive intact, and three prompts sent at once stay three messages. Shells without
  bracketed paste (bash 3.2) work as before. The call now takes about 100 ms.
- **A terminal no longer stays dead when the screens were asleep.** With no display
  awake, libghostty cannot build a terminal (its renderer needs a display link). The
  app logged that and left a blank terminal for good — after a launch at login, or
  when an agent opened one overnight with `planchette session new`, which still
  answered "ok" and swallowed whatever was typed into it. The terminal now waits and
  starts by itself within a few seconds of a display coming back. `session.new` with
  no display awake says so and leaves no empty tab behind, and `session.prompt` and
  `session.read` refuse a terminal that has not started instead of dropping the text.
- **A development run no longer overwrites the installed `planchette` CLI.** Started
  from the build folder (`./.build/debug/Planchette`), the app took its own
  executable for the bundled CLI — the file system ignores case, so `planchette`
  found `Planchette` — and copied 27 MB of binary over `~/.planchette/planchette`.
  Agents in the installed app's terminals then started a second Planchette instead
  of reaching the first. Only the packaged app deploys the hook and the CLI now, and
  an instance with its own `PLANCHETTE_STATE_DIR` leaves your agent configuration
  alone.
- **Your agents no longer freeze while a dialog is open.** The update dialog stopped
  everything dispatched to the main thread (the worktree and import alerts were
  opened the same way): no terminal's output was processed, hook events and the
  `planchette` CLI got no answer, and an agent that kept writing blocked on its next
  write. Measured with the update dialog left open: a loop in a terminal ran about
  140 iterations and stood still until the dialog was closed. Alerts now run in a
  way that keeps the app running.
- **A `session.wait` ends when its caller is gone.** Ctrl-C, a timeout in the
  calling tool or a killed process left the wait — and its connection — in place
  for the rest of its timeout, up to an hour.
- **A symlinked `~/.claude/settings.json` stays a symlink.** Wiring up the hooks
  replaced a dotfile-managed settings file with a regular file, so the dotfiles repo
  stopped tracking it. The same goes for Codex's `hooks.json` and `config.toml`, and
  the one-time backup is now a copy of the file rather than a second link to it. A
  link whose file does not exist yet (dotfiles not checked out) is followed and the
  file created; a link into a read-only store (nix, home-manager) is left alone and
  the error says why.
- **A busy agent no longer starves the autosave.** Saving waited for a quiet second,
  and a running turn never has one, so every change since it began was lost in a
  crash. The oldest unsaved change now waits at most ten seconds.
- **Clicking a notification works from a home folder with a space** in its path.
- **The update window no longer freezes while it unpacks.** Hashing and unpacking
  the download ran on the main thread, spinner included.
- **Updates leave nothing behind.** The downloaded zip, the unpacked copy and the
  swap script stayed in the temp folder (about 35 MB per update); they are removed
  once the update is applied or fails, and leftovers from earlier versions are swept
  at launch.
- **A stuck `git`, `gh`, `lsof` or `tmux` can no longer pile up.** Each of them now
  has a deadline (15 seconds; an hour for the commands that change a worktree,
  which can be slow on a large repository), and no poll starts while its previous
  run is still going. A restore that gets no answer from `tmux` assumes the agents
  are alive instead of replaying a restore command into them.
- **`hook/install-hooks.sh` installs the same nine events as the app** (it was
  missing the tool and sub-agent ones) and writes the file atomically, keeping its
  mode.

### Changed
- **Settings → Project panel is sorted by what a switch is about.** Three pages —
  Terminals, Projects, Tags — instead of one long list. A terminal's details come in
  four groups: where it is, what it is doing, your marks, Claude Code (the three that
  start off, with the reason). What a project's row shows and how a folded project
  behaves have their own page; "Clear the done check after" moved to Terminals. The
  page you were on is remembered.
- **The "finished" mark ends with `/clear` and with a new Claude, not only with a
  prompt.** A terminal you cleared or restarted kept its seal and its dimmed row,
  though the work they stood for was gone. A resumed conversation — what the app does
  for every Claude terminal on launch — and a compaction keep the mark, and so does
  Claude's own "a background task ended" notice: it reaches Planchette as a prompt,
  but you gave no work.
- **Less work in the background.** A terminal's branch is read from `.git/HEAD`
  instead of starting `git` for every directory every ten seconds, and a dev
  server's folder comes from the kernel instead of a second `lsof`.
- **An animated terminal title no longer repaints the window.** A program that
  spins a glyph in its title made every frame a "change" — a window refresh and a
  state file write per frame, per busy terminal.
- **`session.read` answers faster on a long scrollback** (the last lines are found by
  scanning back from the end instead of splitting the whole buffer), and `session.new`
  stops at 200 open terminals instead of forking without end.
- Everything the update dialog says when it refuses an update is translated.

## [0.2.34] — 2026-09-24

### Changed
- **Font size lives in the terminal's right-click menu.** Larger, Smaller and
  Reset moved out of the tab bar, next to copy and paste, where the menu also
  shows their shortcuts (⌘+ / ⌘- / ⌘0). The shortcuts work as before.

### Fixed
- **A click anywhere on a tab row opens that tab.** Before, only the text
  caught the click; the empty part of the row opened the project overview.
- **Selecting a project opens its active tab again.** Only a click on the
  project's own row opens the overview.

## [0.2.33] — 2026-09-23

### Added
- **Pull request on every branch.** Next to a branch, the sidebar shows its
  PR: number, state (draft, open, merged, closed) and the review decision — a
  check for approved, `!` for changes requested. Click it to open the PR. It
  uses your own GitHub CLI login (`gh`); without it there is simply no pill.
- **Notes and a "finished" mark.** Right-click a terminal to write a note on
  it ("waits for QA") or to mark its work finished. A finished terminal gets a
  seal and steps back in the list until you send it a new prompt.
- **Project overview.** Clicking a project row (not a tab) opens a page with
  every tab of the project: state, branch, PR, prompt and note. A click on a
  tab still goes straight to that terminal.
- **Settings → Project panel.** A switch for every extra detail the sidebar
  shows, each with a description and a live example. All on by default,
  except two new optional ones: the **model** a Claude terminal runs on and a
  **context-usage ring** that turns orange at 70 % and red at 90 %.

### Changed
- **A folder's colour is always visible** on its sidebar row, not only in its
  overview.
- **Collapse all folds everything.** With every project collapsed, terminals
  that need you still peek out — a second click on Collapse all now folds
  those away too. The next question or error peeks again.

## [0.2.32] — 2026-09-08

### Fixed
- **A restore only starts Claude where Claude actually ran.** Restoring a tab
  that never held a Claude session — a plain shell, a `npm run dev` — could
  launch `claude --resume <id>` anyway: when it was the only restored tab of
  its folder, it inherited that folder's newest conversation (a recovery step
  for sessions captured before the hooks were installed). Worse, the hooks then
  recorded that id into the tab, so it kept starting Claude on every restore.
  The recovery now requires this terminal's own evidence of Claude (a recorded
  session id or transcript); everything else comes back as the shell it was,
  with its scrollback.

## [0.2.31] — 2026-08-31

### Fixed
- **No more raising the wrong project's window.** Activating the IDE asked for
  *all* of its windows, so whichever window happened to sit on the current
  Space came forward — you clicked "2nd Multibild" and got another project.
  The IDE has already put the requested project in front of its own stack, so
  it is activated plainly now and decides itself which window that is.
- **The one setting that decides whether the jump can work is offered.** No
  application may carry another application's window across Spaces — only
  macOS can, and only when *Desktop & Dock → Mission Control → "When switching
  to an application, switch to a Space with open windows"* is on, which it is
  not by default. The button asks once, while Planchette is still in front, and
  can turn it on for you (the Dock restarts for a second). Declining is
  remembered and never asked again.

### Known limitation
- An IDE window that is minimized, or on a Space none of your displays is
  showing, cannot be brought over by Planchette — macOS offers no way, for any
  app. All four mechanisms were tried: LaunchServices, app activation with and
  without all windows, the app's own `activate` Apple Event, and Accessibility
  (a JetBrains IDE exposes no windows there at all). When that happens the
  click still reaches the IDE — the project *is* opened and focused inside it —
  and Planchette now says so instead of looking broken. Keeping the IDE window
  on the same Space as Planchette makes the jump instant.

## [0.2.30] — 2026-08-31

### Fixed
- **"Look at code" jumps to the window that already has the project open.** The
  strongest evidence there is, and it was not being used: the IDEs record which
  projects they currently show (JetBrains in `recentProjects.xml`, the VS Code
  family in its `storage.json`), so Planchette reads that and sends the click
  there — no dialog, no second window, and the tooltip says "jump to" instead
  of "open in". Only when no IDE has the project open does the marker decide
  which one to start.
- **The IDE is pulled to the front.** Opening reached the IDE all along, but
  nothing raised it: the IDE put its window (or its "this window or a new one?"
  dialog) wherever it already lived — behind Planchette, or on another Space —
  and the click looked like it did nothing, while the invisible modal swallowed
  every further click. The target app is now activated with all of its windows,
  twice, because activating before the IDE has drawn its window raises nothing.
- **A click that cannot become visible says so.** macOS lets no app raise
  another app's window from a different Space, and following an app to its
  Space is off unless *System Settings → Desktop & Dock → Mission Control →
  "When switching to an application, switch to a Space with open windows"* is
  on. When the IDE ends up frontmost with nothing on screen, a notification now
  names that setting — or, when it is already on and every window is
  minimized, says that only you can bring one back. Silence was the actual bug
  here; the app's whole point is that you always know what happened.

### Changed
- **A dev-server chip asks the port which scheme it speaks.** Reading the URL
  off the terminal only works when the server runs in a Planchette terminal —
  started from an IDE's run panel, its banner is out of reach. Each new port is
  now probed once: a TLS port yields `https://localhost:<port>`, so a Vite
  server behind a certificate opens instead of failing. An announced network
  URL still wins over the probe.

## [0.2.29] — 2026-08-31

### Fixed
- **The code button opens the project's own IDE.** It picked the first *listed*
  IDE that happened to be running, so every checkout with an `.idea/` — every
  JetBrains project — was handed to VS Code. The choice now follows evidence:
  the default once you set one, then the marker the checkout itself carries
  (`.idea` → JetBrains, `.vscode` → the VS Code family, an Xcode workspace or
  `Package.swift` → Xcode), then the IDE you last worked in, then whatever
  runs. With nothing to go on it asks instead of guessing.
- **The IDE menu appears.** A SwiftUI `Menu` with a primary action, shown next
  to a terminal surface, flashed blank and closed — so picking an IDE or
  setting a default was impossible. It is an `NSMenu` now, like the terminal's
  own context menu: every installed IDE (running ones marked, the one a click
  would open in bold, one that cannot open this checkout listed but disabled),
  then the default choice with its checkmark. A left click opens, the chevron
  always asks. Unit tests now read the menu, so "it came up empty" cannot pass
  unnoticed again.
- **Xcode is no longer handed a bare folder.** Given a directory it has no
  project for, Xcode opens a window and closes it again — the "I just see a
  blank, then it closes". Xcode only counts as a target when the checkout has
  a `.xcworkspace`, an `.xcodeproj` or a `Package.swift`, and is handed that
  file. Failures to open are logged instead of swallowed.

### Changed
- **A dev-server chip is the port, and it opens the real address.** The port
  comes from the OS, but the scheme and host only exist in what the server
  printed, so Planchette reads them off the terminal — the network address
  first. Vite on `https://photo-frame-designer.myposter.de:8082` is now what a
  click gets, instead of a dead `http://localhost:8082`. The full URL and the
  serving process stay one hover away.

## [0.2.28] — 2026-08-27

### Added
- **Dev servers show their link on the project.** A server running in a
  project's checkout appears as a clickable `localhost:<port>` chip in the
  project header and the folder overview; a click opens it in the browser.
  Found by process (listening socket → working directory → project), not by
  reading terminal output — so a server started in an IDE's integrated
  terminal, or anywhere else, counts exactly like one started in a Planchette
  terminal. Debugger ports, ephemeral ports and IDE helper processes are
  filtered out, and an ancestor directory only matches when it looks like a
  checkout root, so a listener in a plain collection folder claims nothing.
- **"Look at code" hands the project to your IDE.** One click opens the
  project in the IDE that is already running — macOS focuses the window it is
  open in instead of opening a second one. The button's menu lists every
  installed IDE (running ones marked), and a *Default IDE* submenu with a
  checkmark makes one of them the standing choice: from then on the button
  always opens that one. With no IDE running and no default chosen, the
  button reads *Open new IDE* and is the picker. Recognized: VS Code, Cursor,
  Windsurf, Zed, WebStorm, IntelliJ IDEA (+CE), PhpStorm, PyCharm, Xcode,
  Sublime Text.

## [0.2.27] — 2026-08-26

### Fixed
- **Scrolling a durable terminal no longer types arrow keys.** tmux keeps the
  terminal in the alternate screen, where ghostty converts wheel ticks into
  cursor keys when no program owns the mouse — so scrolling at a prompt cycled
  shell history, and in Claude Code it navigated instead of scrolling (the
  pane's real history lives inside tmux, out of ghostty's reach). The private
  tmux server now runs with `mouse on`: the wheel scrolls the pane's history at
  a prompt, still forwards to programs that ask for the mouse, and still sends
  arrows to full-screen programs that don't (`less`, `vim`). Mouse selections
  land on the system clipboard on release. tmux's own right-click menus are
  unbound — the native context menu keeps working — and the config is
  re-sourced on every attach, so servers started by an older version pick the
  fix up without a reboot.
- **A restored live agent no longer gets the replay typed into it.** Restore
  resolved "is this agent still alive in tmux?" in parallel with the first
  render; when the render won, a surviving agent was treated as dead and got
  `clear`, the old scrollback and `claude --resume` typed straight into its
  TUI. The liveness answer is now resolved before any terminal is published,
  so a surface can never be built on a stale answer.
- **Two command injections are closed.** A crafted transcript filename could
  inject into the `claude --resume` line a restore types (resume ids are
  validated now, anything odd falls back to Claude's own picker), and a
  filename containing a newline acted as Return when dropped onto a terminal
  (`Shell.escape` strips CR/LF — a backslash cannot neutralize a newline).
- **Clipboard reads no longer loop.** Under Ghostty's default
  `clipboard-read = ask`, an OSC 52 read — and a newline paste into a program
  without bracketed paste — was re-dispatched forever: pinned CPU, a paste
  that never landed.
- **A state.json that fails to decode is archived, not deleted.** A downgrade
  (or closing every terminal before quitting) used to erase all projects and
  settings silently; the file now lands in `state-previous.json` first.
- **Updates verify fail-closed.** When a release carries `SHA256SUMS`, a
  failed checksum fetch aborts the install instead of silently skipping
  verification. The swap helper only starts once a quit is confirmed, so
  cancelling the quit dialog no longer leaves a helper behind that would swap
  the bundle and relaunch the app later, out of nowhere.
- Smaller fixes: a second question arriving in the same state counts as
  unread; merging windows keeps the source window's folders; shifted app
  shortcuts (⌘⇧K, ⌘⇧T) reach the menu from a focused terminal; a hand-edited
  `screen-rules.json` with omitted optional fields no longer discards the
  whole file; worktree terminals show their real branch; the quick switcher
  can no longer open the wrong row when the list re-ranks under the pointer;
  `session.new` without `focus` leaves you where you are, and `session.focus`
  actually brings the app forward; `notification.list` matches the panel's
  window order; `~/.claude/settings.json` and `~/.codex/hooks.json` are
  written atomically; an isolated instance re-attaches its own tmux server
  after a restart.

### Changed
- **Idle cost dropped again.** The 1.5s screen poll runs at a quarter rate
  while the app is in the background, scrollback saves are throttled and
  written off the main thread, git-branch lookups are cached instead of
  walking the filesystem on every view update, and AI summaries run one at a
  time instead of spawning one `claude -p` per busy agent.

### Added
- **Settings can install tmux for you.** When tmux is missing, the
  durable-terminals section shows the install command with a copy button —
  and one click opens a terminal with the command already typed, so Enter is
  all that's left.

## [0.2.26] — 2026-08-20

### Added
- **`session.focus` in the socket API** — switch to a terminal that already
  exists. `session.new` could focus one, but only the terminal it had just
  created, so a caller could tell you which terminal was waiting and then leave
  you to go and find it. Anything showing Planchette's state from outside the
  app — a status pane, a dashboard strip, an agent triaging its siblings — can
  now list what needs attention and take you straight there. It raises the
  window, switches to the project, makes the terminal the active tab and marks
  it seen: the same `select(session:)` the app uses when you click a row.
  Thanks to @Vitalii-Samsoniuk!

### Fixed
- **Idle CPU no longer scales with the animated state icons.** The running
  robot's timeline re-applied its tooltip and accessibility modifiers on every
  0.18s frame, and each tick escalated into a full window layout pass — about
  a third of the main thread in a working workspace, in the background as much
  as in front. A frame step is a canvas redraw now, and an app in the
  background shows a still sprite with no timeline at all. Alongside: no-op
  state writes no longer invalidate every window (hook events re-carry the
  same values constantly), terminals in minimized or covered windows stop
  being drawn, the per-hook git-branch lookup left the main thread, and the
  menu-bar state images are cached. Measured on the same 16-terminal
  workspace: ~7.5% → ~1.2% CPU active, ~7.0% → ~0.8% in the background.

## [0.2.25] — 2026-08-20

### Fixed
- **Terminal reads no longer leak memory.** Every read of a terminal's text —
  the 1.5s screen poll on each agent terminal, `session.read`, the scrollback
  capture on quit/hide — leaked its whole buffer, because the pinned
  libghostty's C header declares `ghostty_surface_free_text(surface, text)`
  while the compiled export takes only the text pointer: called as the header
  says, it freed nothing. A workday instance grew by hundreds of MB. The call
  now matches the real ABI (verified by disassembly), and a comment at the
  shim warns whoever bumps vendor/ghostty. Two small unbounded growths went
  with it: the escalation and AI-throttle records of closed terminals are
  dropped on close.

## [0.2.24] — 2026-08-18

### Added
- **Delete a saved arrangement** — and rename one — from the Arrangements menu.
  Both were only reachable from the welcome screen's cards, which you stop seeing
  the moment the workspace has anything in it, so an arrangement you no longer
  wanted could not be got rid of. Deleting asks first, by name: an arrangement is
  the one thing "Start fresh" deliberately spares, and nothing can bring one
  back. What it built stays — the template goes, its projects and terminals do
  not.

### Changed
- **Durable terminals are on by default**, so every setting now ships on. New
  terminals run inside tmux and their agents survive quitting, a crash and
  Install & Relaunch. The cost is unchanged and stated in Settings: tmux cannot
  pass the terminal's keyboard protocol through, so `Shift+Enter` reaches an
  agent as a plain `Enter` — turn it off if multi-line prompts matter more than a
  surviving agent. A machine without tmux is unaffected (no tmux, no durable
  session), and a state that already says `false` keeps it: only "never chose"
  becomes on.

## [0.2.23] — 2026-08-18

### Added
- **A manual for the API** ([docs/API.md](docs/API.md)). Every command, every
  argument, every field of every object, the socket protocol for programs that
  are not shells, working recipes, and the rules that keep one agent from
  breaking another one's work. The agent skill links to it and keeps the short
  version. It is the contract other programs read, so a command or a response
  field that changes has to change there in the same commit.
- **Mark a project active or inactive.** An inactive project is parked: it keeps
  its terminals and its place in the sidebar, reads dimmed with a pause glyph,
  and goes silent — out of the counts, the badges, the dock, the notifications
  panel and every banner, like a snooze that does not end on its own. Marking it
  inactive also marks its terminals free, so a parked project cannot sit on a
  question nobody will answer. `AppState.isMuted` is now THE filter for anything
  that counts or announces attention; `isSnoozed` is only for the snooze badge
  and the expiry reminder.
- **`notification list` in the socket API and the CLI.** The notifications panel
  as JSON — the same sections in the same order, with every fact the row prints:
  state and its label, unread, the last prompt, the message, age (`12m`),
  `age_seconds`, `state_since`, path, branch, ticket, tags, and the project it
  sits under, plus the panel's own totals. Narrow it with `--unread-only`,
  `--only-active`, `--project-id` and `--limit`. Panel and API answer from one
  shared list (`AppState.notificationSections`), so the API cannot drift from the
  UI it reports on.
- **A folded project cannot hide a question.** Collapse a project and the
  terminals asking for you — a question or an error you have not read — stay
  visible under its row, then disappear by themselves once read.
- **Saving an arrangement asks which one.** "Save arrangement" now offers a new
  name *or* one of the saved arrangements to overwrite, picked from a list.
  Overwriting used to depend on retyping an existing name exactly; a typo left
  the old arrangement behind next to a near-duplicate.

### Changed
- **The project context menu is grouped by what its items act on.** The three
  ways to make a project quiet now sit together at the top, ordered by how long
  the quiet lasts — *Mark project as free*, *Remind me…*, *Mark project
  inactive* — then what the project *is* (main project, name, colour), then where
  it lives (folder, window), then *Close Project* alone. Parking used to stand
  next to "Mark as main project", where it read as a designation rather than as
  silence, and the attention items sat below a divider in the middle. The
  notifications panel's project header gets the same three items, and the
  multi-selection menu the same four groups.
- **The sidebar rows are restructured around what you actually ask.** A project
  row is its name with the checked-out branch under it, and a terminal row is
  three lines: the ticket of its checkout plus the path, then the branch, then
  the prompt you last sent with how long ago something happened. The branch is
  stated once where it is true — on the project while all its terminals are on
  it, on each terminal as soon as they differ — so two worktrees of one repo can
  no longer read the same. The branch poll now runs per distinct directory
  instead of per project, which costs no extra subprocesses.
- **A notification row leads with the prompt and names its checkout by the
  branch.** The title is the branch from its ticket on
  (`marcello/feat/NIE-1902-format-switch` → `NIE-1902-format-switch`) — the same
  lead-in on every branch one person makes is dropped. The middle line was the
  agent's own message ("Claude is waiting for your input"), which said what the
  state badge already says; it is the prompt now, up to two lines, ending before
  the age instead of running under it. The state badge moved to the corner beside
  the name, and the wall-clock time it replaced is gone.
- **A project reads the same wherever it is counted.** The notifications panel's
  project header carries the sidebar's badge row — errors, questions, unseen
  results — instead of one badge for the most urgent state.
- **Ages use unit symbols: `s`, `m`, `h`, `d`, `w`.** `42s`, `12m`, `1h 20m`,
  `2d 2h`, `1w 2d` — two units at most, and the smaller one only while it says
  something. The label ticks every second while it counts seconds and once a
  minute afterwards, so a fresh row no longer shows a number that is already
  wrong. The age sits at the right edge of the row in every list.
- **Only the terminal you can see is marked as active.** The outline used to sit
  on the active terminal of *every* project at once, which is a list of
  bookmarks, not an answer to "which one am I in". It is now the one on screen:
  the active terminal of the project this window shows, and in a split the pane
  you focused.

### Fixed
- **The Claude state told three lies.** `SubagentStop` reported a finished turn,
  so a turn that spawns `Task` subagents turned green mid-flight — only `Stop`
  ends a turn now. Granting a permission fires no hook of its own, so a terminal
  you had already answered kept asking until the whole turn ended; `PreToolUse`
  and `PostToolUse` are now installed and mean "a turn is in flight", which is
  the proof that the question is gone. And Claude Code's idle nudge after a
  minute at the prompt ("waiting for your input") arrives as a `Notification`
  like a permission request does — it turned terminals blue and posted "X asks"
  for a question nobody had asked; it now changes nothing. The cost is two more
  hook invocations per tool call, which is a `sh` + `nc` each.

## [0.2.22] — 2026-08-14

### Added
- **The active terminal is marked wherever it is listed.** The tab bar already
  outlined it in its state colour; the sidebar rows and the folder overview now
  carry the same outline, so "which terminal am I in, and what is it doing" is
  answered without opening the project. All three marks got room to breathe.

### Removed
- **The "Needs you" block at the top of the notifications panel.** It repeated
  rows that stand three lines further down, in a panel that already sorts and
  filters by exactly that question. The panel opens straight into the project
  mirror now. Nothing else changed: `attentionQueue` still drives the menu bar
  and ⌘⇧K.

## [0.2.21] — 2026-08-14

### Added
- **Each project shows its checked-out branch** (#8, by @mtreuberg). Two
  worktrees of one repo used to look identical in the sidebar; the branch is
  read from the checkout every 10s off the main thread, so a `git checkout`
  shows up while you are still looking at the terminal. Derived, never
  persisted — the checkout on disk is the truth and it changes behind the app's
  back. A detached HEAD shows nothing, since a bare sha would only be noise.

## [0.2.20] — 2026-08-14

### Added
- **A Help tab that lists every feature, and can be searched.** Settings → Help
  holds the whole feature set in sections — what it does, where it lives, its
  shortcut — with a search box that narrows on every word you type. It is built
  from the *same* localized strings the controls carry, not a second copy of
  them: a feature's name is its menu item's name and its description is that
  control's tooltip, so the page cannot drift from the app without the app
  changing. A test walks every entry and fails on a key with no text.
- **"Request a feature" opens a pre-filled GitHub issue** from the Help tab,
  labelled `enhancement`, with the build and macOS version already in the body.
- Keeping the Help tab current is now **ground rule 5 in AGENTS.md** and a step
  in CONTRIBUTING's "Add a feature": a user-facing feature is not done until it
  is in the catalogue.

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
