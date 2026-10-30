# Planchette API

The manual for **driving Planchette from inside one of its terminals** — and for
reading what it knows. Written for an agent: every command, every field, and the
rules that keep one agent from breaking another one's work.

Planchette watches agents (hooks report their state). This is the other
direction: an agent asks Planchette for things. Two surfaces, one protocol:

| Surface | Use it when |
|---|---|
| `"$PLANCHETTE_CLI"` | you are an agent in a terminal, or writing a shell script |
| the unix socket | you are a program that speaks JSON (status bar, Stream Deck, editor plugin) |

Both are local only. There is no network listener, no token, no remote access.
Access control is the socket, enforced from both ends:

- the socket file is private to the user (mode 0600);
- the app asks the kernel who is on the other end of every connection and drops
  anyone who is not the same user — the socket lives in `/tmp`, where a file name
  is not proof of anything;
- the CLI and the hook script refuse to talk to a socket that another user owns,
  because a request carries whatever an agent types into a terminal.

## Reaching it

Every Planchette terminal is handed three environment variables:

| Variable | What |
|---|---|
| `PLANCHETTE_SESSION` | this terminal's id (a UUID) — the "me" every command defaults to |
| `PLANCHETTE_SOCKET` | the socket of the app instance that opened this terminal |
| `PLANCHETTE_CLI` | absolute path to the `planchette` CLI (`~/.planchette/planchette`) |

Confirm you are inside Planchette before anything else, and stop if you are not:

```bash
test -n "${PLANCHETTE_CLI:-}" && test -n "${PLANCHETTE_SESSION:-}"
```

**`$PLANCHETTE_SOCKET` can name a dead socket.** A durable (tmux-backed) terminal
outlives the app that created it, so after a restart its environment still points
at the old instance. The running app publishes where it actually listens in
`~/.planchette/socket`. Try the env var first, fall back to the pointer, and only
report failure when neither answers — the env var must win whenever it answers,
because two instances can run at once and this terminal belongs to the one that
opened it. A killed app leaves its socket *file* behind, so the file existing
proves nothing; only a successful send does. The CLI already does all of this.

## The protocol

One JSON object per connection, one JSON object back, then the connection closes.
The client writes its request, **half-closes the write side** (the app answers on
EOF), and reads until EOF.

```
→ {"planchette_request": "session.list"}
← {"ok": true, "result": {"sessions": [ … ]}}
```

```
→ {"planchette_request": "session.get", "id": "not-a-session"}
← {"ok": false, "error": "no such session"}
```

- `planchette_request` names the command. Requests are told apart from hook
  events by this key, so hook traffic and API traffic share one socket.
- Every other key is an argument.
- `session` is added automatically by the CLI (`$PLANCHETTE_SESSION`), which is
  how "the calling terminal" defaults work.
- An unknown command answers with the list of known ones — the binary is the
  authority on its own surface, so ask it rather than trusting this page.

macOS `nc` cannot half-close a unix socket, so it can never read the reply. Use
python, socat, or the CLI.

### Limits

The socket is not a place to stream data, and it is bounded accordingly.

| | Limit |
|---|---|
| size of a request | 4 MiB; a bigger one is dropped, not truncated |
| time to deliver a request | 5 s in total. A client that never closes its side is still served — with what it sent when the 5 s end |
| connections being read at once | 64; the 65th is refused. A connection counts only while its request is being read, not while it waits for the answer |
| requests waiting for their answer | 64 (a `session.wait` is one until it ends); the 65th gets `ok: false` with `too many requests in flight; try again shortly` |
| terminals opened through `session.new` | 200 |

A response is written with a 15 s timeout per write, so a client that stops
reading cannot hold the app's thread. `session.read` always answers with the last
`lines` lines (at least one) of the buffer.

A request that waits for its answer (`session.wait`) ends as soon as its caller
goes away — Ctrl-C, a timeout in the calling tool, a killed process. The app sees
the close; it does not wait out the timeout. A client that only finished sending
(`shutdown(SHUT_WR)`, which is what the CLI does) is still waiting for its answer,
and gets it.

### CLI exit codes

| Code | Meaning |
|---|---|
| 0 | `ok: true` |
| 1 | the app answered `ok: false` — read `.error` |
| 2 | usage error, or Planchette is not reachable |

The CLI prints the whole JSON response on stdout, pretty-printed and key-sorted.

## Commands

| Command | Does |
|---|---|
| `session.list` | every terminal |
| `session.get` | one terminal (default: the caller) |
| `session.new` | open a terminal |
| `session.focus` | switch to a terminal |
| `session.prompt` | type text into a terminal |
| `session.read` | read a terminal's screen or scrollback |
| `session.wait` | block until a terminal reaches a state |
| `project.list` | every project |
| `notification.list` | the notifications panel, as data |
| `review.list` | the Reviews panel, as data: the pull requests that wait for your review |

### session.list

No arguments. Returns `{"sessions": [session, …]}`, sorted by title.

```bash
"$PLANCHETTE_CLI" session list
```

### session.get

| Argument | Type | Default |
|---|---|---|
| `id` | UUID string | the calling terminal |

Returns `{"session": session}`.

### session.new

| Argument | Type | Default |
|---|---|---|
| `cwd` | absolute path (**required**) | — |
| `project_id` | UUID string | the caller's project |
| `focus` | bool | `false` |

Creates the terminal *and starts its PTY*, so the next `session.prompt` has
something to type into. Without `project_id` it lands in the caller's own
project, so "another terminal here" does not scatter projects across the sidebar.
It does not steal focus unless you ask: leave the user where they are. At 200 open
terminals it answers `ok: false` ("too many terminals are open") instead of
opening another. While no display is awake (a Mac whose screens are asleep) a
terminal cannot be started at all — libghostty's renderer needs a display — so the
answer is `ok: false` ("terminal could not be started (is a display active?)") and
no tab is left behind; try again once a display is back. `session.prompt` and
`session.read` answer `ok: false` ("session has no live terminal") for a terminal
that has not started yet, rather than dropping what was typed.

Returns `{"session": session}`.

### session.focus

| Argument | Type | Default |
|---|---|---|
| `id` | UUID string | the calling terminal |

Shows a terminal that already exists: raises its window, switches to its
project, makes it the active tab, and marks it seen. `session.new` can only
focus the terminal it just created, so without this a caller could name the
terminal that wants attention but not take you to it.

That is the gap it fills. Anything displaying Planchette's state outside the app
— a status bar, a dashboard pane, an agent triaging its siblings — can list what
is waiting and then act on the answer:

```bash
id=$("$PLANCHETTE_CLI" notification list --unread-only \
  | python3 -c 'import json,sys; n=json.load(sys.stdin)["result"]["notifications"]; print(n[0]["id"] if n else "")')
[ -n "$id" ] && "$PLANCHETTE_CLI" session focus --id "$id"
```

Returns `{"session": session}`, or `{"ok": false, "error": "no such session"}`.

### session.prompt

| Argument | Type | Default |
|---|---|---|
| `id` | UUID string | the calling terminal |
| `text` | string (**required**) | — |
| `submit` | bool | `true` — `false` types without pressing Enter |
| `force` | bool | `false` |

Refuses with `session is running; wait for it or pass force` while a turn is in
flight: typing into a running turn interrupts it, and that turn is the user's
work, not yours to discard. `force` overrides it — be sure. It is the *turn* that
counts: a terminal shown as `running` only because Claude still runs a shell or an
agent in the background (`turn_state` says so) sits at its prompt, and is not refused.

The text is delivered as a paste — framed in bracketed-paste markers when the
program asked for that, as zsh, fish and Claude Code do — and then Enter is pressed
as a key, about 100 ms later, so the program has taken the text into its input
first. (A carriage return inside the paste frame is only a newline in the text. An
earlier version appended one to the text and, with such a program, typed the prompt
and left it waiting unsent.) Text with line breaks arrives as one multi-line input
and is submitted once. Prompts to the same terminal are delivered one after the
other, so two callers cannot mix their text; the call returns when Enter has been
pressed.

### session.read

| Argument | Type | Default |
|---|---|---|
| `id` | UUID string | the calling terminal |
| `lines` | int | `60` |
| `scrollback` | bool | `false` — `true` reads history, not just the viewport |

Returns `{"text": "…", "session": session}` — the last `lines` lines.

### session.wait

| Argument | Type | Default |
|---|---|---|
| `id` | UUID string | the calling terminal |
| `until` | array of state names | `["ready", "waiting", "error", "free"]` |
| `timeout_ms` | int | `120000` (capped at 3600 s) |

Waits on the *turn*: a terminal shown as `running` only because of its background
work counts as the state its turn is in (`turn_state`, `ready` or `free`), so a worker
that has answered is not waited for until its dev server stops.

Returns `{"session": session, "timed_out": false}` on arrival, or `ok: false`
with a timeout error. The wait stops early, without an answer, when the caller's
connection closes. **It only works for an agent whose state Planchette can
see** — Claude Code reports every transition through hooks; an agent that only
claims its session will never change state and the wait will time out. For those,
`session.read` and judge the output yourself.

Always pass `--until waiting` alongside `--until ready`: waiting for `ready`
alone hangs through a permission prompt.

### project.list

No arguments. Returns `{"projects": [ … ]}`:

| Field | Type | Meaning |
|---|---|---|
| `id` | string | project id |
| `name` | string | as shown in the sidebar |
| `favorite` | bool | main project — only these may post desktop notifications |
| `active` | bool | `false` = parked: dimmed, silent, out of every count |
| `sessions` | array | its terminal ids, in tab order |
| `worktree` | string | present only for a git worktree Planchette created |

### notification.list

The notifications panel as data: the same sections, the same order, every fact
the rows print. Answered from the same list the panel renders
(`AppState.notificationSections`), so it cannot drift from the UI.

| Argument | Type | Meaning |
|---|---|---|
| `unread_only` | bool | only terminals whose last report is unread |
| `only_active` | bool | only what wants you: waiting / error, and done terminals whose done check has not cleared yet. Running terminals are left out unless `include_running`; a terminal that is free again is left out |
| `include_running` | bool | with `only_active`, the running terminals too. Without `only_active` it changes nothing: that list holds every terminal |
| `project_id` | UUID string | one project |
| `limit` | int | stop after this many rows |

```bash
"$PLANCHETTE_CLI" notification list --unread-only --limit 10
```

Returns:

```json
{
  "counts": {"unread": 3, "waiting": 1, "errors": 0, "unseen_ready": 2, "listed": 3},
  "notifications": [ notification, … ]
}
```

Order is the panel's: the projects of the front window first (favorites before
the rest), then every other window's, and terminals in tab order.

- **Parked projects are absent.** A project marked inactive is silent on purpose.
- **Snoozed terminals are listed**, exactly as the panel lists them: `muted` is
  `true` and `snoozed_until` says when they come back. Skip them if your surface
  is meant to nag, keep them if it is meant to mirror.
- `counts` are the totals the panel header and the menu bar show. They ignore
  both the filters and `limit`, and they never include a muted terminal.

### review.list

The Reviews panel as data: the pull requests that asked you for a review, in the
panel's sections and order (`AppState.reviewSections`). GitHub is polled every
five minutes through `gh`; an isolated instance (`PLANCHETTE_STATE_DIR`) does not
poll and lists what its state holds.

| Argument | Type | Meaning |
|---|---|---|
| `include_team` | bool | also the requests that went only to one of your teams (the panel's "Only mine" unticked) |
| `hide_sent` | bool | leave out the reviews you sent that wait for the author |

```bash
"$PLANCHETTE_CLI" review list --include-team
```

Returns `{"reviews": [...], "counts": {"unseen": n, "listed": n}, "checked_at": "…" | null}`.
Each review:

| Field | Type | Meaning |
|---|---|---|
| `url`, `repo`, `number`, `title`, `author` | | the pull request (`repo` is `owner/name`) |
| `draft`, `additions`, `deletions`, `changed_files` | | its size and draft state |
| `checks` | string | `passed` · `failed` · `pending` · `none` |
| `requested_from_me` | bool | asked by name, not only through a team |
| `team` | string | the team that was asked (absent when you were asked by name) |
| `section` | string | `needs_you` · `reviewing` · `sent` |
| `stage` | string | `requested` · `reviewing` · `findings` · `sent` |
| `unread` | bool | not looked at since it changed |
| `updated` | bool | the author asked again or pushed after your sent review |
| `sending` | bool | "Send review" was clicked; the review terminal is posting |
| `since` | string | ISO 8601 — when the stage last changed |
| `checkout` | string | where the review runs or ran (absent before a start) |
| `temporary` | bool | that checkout is a worktree Planchette removes after the review is sent |
| `session` | UUID string | the review terminal |
| `findings` | int | how many findings the review wrote (absent before) |
| `verdict` | string | `COMMENT` · `APPROVE` · `REQUEST_CHANGES` — the one it will be sent with, or was |
| `snoozed_until` | string | ISO 8601, only while snoozed ("Later") |
| `error` | string | the last thing that went wrong (absent if nothing) |

The review itself runs in a terminal as the `review-pr` Claude Code skill — the user's own, or
the default in `skills/review-pr`, which the app installs when there is none. It and
the app share three files in `<state dir>/reviews/<owner>-<repo>-<number>/`:
`findings.json` (the skill's findings), `decisions.json` (yours, written by the
app on "Send review") and `sent.json` (the skill's receipt).

## Objects

### session

Returned by every `session.*` command.

| Field | Type | Meaning |
|---|---|---|
| `id` | string | terminal id |
| `title` | string | the name the app derives: a name you typed, else the ticket of the branch and the last prompt (`NIE-1902 · Add the switch`). The tab bar shows what Settings → Tabs says (the conversation's summary, by default), so the two can differ |
| `path` | string | live working directory |
| `state` | string | `running` · `waiting` · `ready` · `error` · `free`. A terminal whose turn ended while Claude still runs a shell or an agent in the background is `running` (Settings → Project panel → Behavior turns that off) |
| `turn_state` | string | `ready` or `free`, present only when `state` is `running` for that reason: the state the turn itself is in. `session.prompt` and `session.wait` go by it |
| `agent` | string | `claude` · `codex` · `none` |
| `seen` | bool | has its last report been looked at |
| `main` | bool | marked as a main terminal: a star, and it stays under its project while the project is folded |
| `task` | string | the last prompt submitted here (absent if none) |
| `message` | string | the last question or error (absent if none) |
| `background_tasks` | object | `{"shells": n, "agents": n}` — what Claude Code still runs in the background of this terminal (absent if nothing). A `ready` terminal can still be busy: a dev server, a review agent. A watch (an artifact's live link, an MCP stream) or an idle teammate is not counted: it never ends on its own. Claude Code only; older versions do not report it |
| `project` | string | project name (absent if the project is gone) |
| `project_id` | string | project id |

### notification

Everything in `session`, plus:

| Field | Type | Meaning |
|---|---|---|
| `headline` | string | the row's first line as the panel prints it: the branch from its ticket on, a name you typed, else `title` |
| `state_label` | string | the badge text, in the app's language |
| `needs_attention` | bool | `waiting` or `error` |
| `unread` | bool | last report not looked at yet |
| `prompt` | string | the row's middle line: the last prompt, else the message |
| `state_since` | string | ISO 8601 with offset — when the state last changed |
| `age_seconds` | int | seconds since `state_since` |
| `age` | string | the printed age (`42s`, `12m`, `1h 20m`, `2d 2h`, `1w 2d`) |
| `short_path` | string | last two path segments |
| `branch` | string | checked-out branch (absent outside a repo, and for ~10 s after launch — it is polled) |
| `ticket` | string | ticket key in that branch, e.g. `NIE-1902` (absent if none) |
| `tags` | array | the terminal's tags |
| `durable` | bool | tmux-backed, survives an app restart |
| `muted` | bool | silent: snoozed (or in a parked project, which this list omits) |
| `snoozed_until` | string | ISO 8601, present only while snoozed |
| `ai_summary` | string | one-line summary, only with AI assist enabled |
| `ai_topic` | string | one-word topic, same condition |
| `project_favorite` | bool | its project is a main project |
| `project_active` | bool | its project is not parked |
| `project_branch` | string | the branch all the project's terminals share |

**Branch on `state` and `age_seconds`, print `headline`, `state_label` and
`age`.** The raw
values are stable; the labels follow the user's language and are meant for
display. Absent keys mean "nothing to say" — check for the key, never for an
empty string.

## States

| State | Colour | Means |
|---|---|---|
| `running` | purple | a turn is in flight, or its turn ended and Claude still runs a shell or an agent in the background |
| `waiting` | blue | it needs a human answer |
| `ready` | green | a turn finished, the result is unreviewed |
| `error` | red | the last command or agent failed |
| `free` | gray | empty prompt, nothing pending |

`waiting` means **a human** is needed. Do not answer another agent's permission
prompt on the user's behalf: report it and let them decide.

## Recipes

Put a second agent to work in your own project and collect its result:

```bash
new=$("$PLANCHETTE_CLI" session new --cwd "$PWD")
id=$(printf '%s' "$new" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["session"]["id"])')

"$PLANCHETTE_CLI" session prompt --id "$id" --text 'claude'
"$PLANCHETTE_CLI" session wait   --id "$id" --until free --timeout-ms 60000

"$PLANCHETTE_CLI" session prompt --id "$id" --text 'Review the staged diff. Report only actionable findings.'
"$PLANCHETTE_CLI" session wait   --id "$id" --until ready --until waiting --timeout-ms 600000
"$PLANCHETTE_CLI" session read   --id "$id" --lines 120
```

A one-line status of what wants attention:

```bash
"$PLANCHETTE_CLI" notification list --only-active \
  | python3 -c '
import json, sys
data = json.load(sys.stdin)["result"]
print(" · ".join(f"{n[\"project\"]}/{n[\"title\"]} {n[\"state\"]} {n[\"age\"]}"
                 for n in data["notifications"]) or "all quiet")'
```

Talk to the socket without the CLI (any language that can write a unix socket):

```python
import json, os, socket

def call(request):
    path = os.environ.get("PLANCHETTE_SOCKET") or \
        open(os.path.expanduser("~/.planchette/socket")).read().strip()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(10)
        client.connect(path)
        client.sendall(json.dumps(request).encode())
        client.shutdown(socket.SHUT_WR)          # the app answers on EOF
        chunks = iter(lambda: client.recv(65536), b"")
        return json.loads(b"".join(chunks))

print(call({"planchette_request": "notification.list", "unread_only": True}))
```

## Rules for agents

- **Parse ids out of JSON.** Never guess one, never read one off the sidebar.
- **Do not answer a `waiting` terminal.** It is waiting for the human.
- **Do not steal focus.** `--focus` and `session.new` without it exist for that
  reason.
- **Never prompt a running terminal** unless the user asked you to interrupt it.
- **Read is cheap, write is not.** `notification.list` and `session.list` are
  safe to poll (a second apart is plenty); `session.new` creates a real process.
- **One request per connection.** Open, send, half-close, read, close.
- **Every terminal belongs to one app instance.** Do not try to reach another
  user's session, and do not "fix" a socket that does not answer by scanning
  `/tmp`.

## Where this lives in the code

| File | What |
|---|---|
| `macos/Planchette/Sources/Planchette/ControlAPI.swift` | commands, argument parsing, response encoding |
| `macos/Planchette/Sources/Planchette/HookServer.swift` | the socket, and the split between hook events and requests |
| `macos/Planchette/Sources/Planchette/AppState.swift` | `notificationSections` — the list panel and API share |
| `hook/planchette` | the CLI (python3, no dependencies) |
| `skills/planchette/SKILL.md` | the short version, as an agent skill |
