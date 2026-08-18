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

Both are local only. There is no network listener, no token, no remote access:
the socket's permissions are the whole security model.

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
| `session.prompt` | type text into a terminal |
| `session.read` | read a terminal's screen or scrollback |
| `session.wait` | block until a terminal reaches a state |
| `project.list` | every project |
| `notification.list` | the notifications panel, as data |

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
It does not steal focus unless you ask: leave the user where they are.

Returns `{"session": session}`.

### session.prompt

| Argument | Type | Default |
|---|---|---|
| `id` | UUID string | the calling terminal |
| `text` | string (**required**) | — |
| `submit` | bool | `true` — `false` types without pressing Enter |
| `force` | bool | `false` |

Refuses with `session is running; wait for it or pass force` while a turn is in
flight: typing into a running turn interrupts it, and that turn is the user's
work, not yours to discard. `force` overrides it — be sure.

Text and the newline are written together, so a TUI cannot submit an empty line
and then receive the prompt.

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

Returns `{"session": session, "timed_out": false}` on arrival, or `ok: false`
with a timeout error. **It only works for an agent whose state Planchette can
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
| `only_active` | bool | only running / waiting / error |
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

## Objects

### session

Returned by every `session.*` command.

| Field | Type | Meaning |
|---|---|---|
| `id` | string | terminal id |
| `title` | string | the name shown in the tab bar |
| `path` | string | live working directory |
| `state` | string | `running` · `waiting` · `ready` · `error` · `free` |
| `agent` | string | `claude` · `codex` · `none` |
| `seen` | bool | has its last report been looked at |
| `task` | string | the last prompt submitted here (absent if none) |
| `message` | string | the last question or error (absent if none) |
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
| `running` | purple | a turn is in flight |
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
