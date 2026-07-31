---
name: planchette
description: "Control Planchette, the terminal IDE this session may be running in: list its terminals, open one, send a prompt to another agent, wait for it to finish, and read its output. Use only when the user explicitly asks to inspect or drive Planchette terminals, or to hand work to another agent beside this one. Do not use merely because a task could be parallelized. Requires $PLANCHETTE_CLI."
---

# Planchette

Planchette runs many coding agents as terminals grouped into projects, and knows
which one is running, waiting for an answer, done, or free. This skill is the
outbound half: it lets the agent *inside* a terminal drive the app.

Before anything else, confirm this session actually runs inside Planchette:

```bash
test -n "${PLANCHETTE_CLI:-}" && test -n "${PLANCHETTE_SESSION:-}"
```

If that fails, say you are not running inside Planchette and stop. Never try to
reach another user's session.

## The surface

`"$PLANCHETTE_CLI"` with no arguments prints the command groups. Every command
returns JSON on stdout: exit 0 on success, 1 when the app reports a failure
(read `.error`), 2 on a usage or socket problem. Parse ids out of the JSON —
never guess them, and never infer them from the sidebar.

```bash
"$PLANCHETTE_CLI" session list                 # every terminal: id, project, state, task
"$PLANCHETTE_CLI" project list                 # projects, favorites, worktree paths
"$PLANCHETTE_CLI" session get                  # the calling terminal
"$PLANCHETTE_CLI" session get --id <uuid>
```

Commands default to **the calling terminal** when `--id` is omitted, because
`$PLANCHETTE_SESSION` is sent with every request. Pass `--id` explicitly whenever
you mean a different one.

## States

`running` (a turn is in flight) · `waiting` (it needs a human answer) ·
`ready` (a turn finished, result unreviewed) · `error` (last command or agent
failed) · `free` (empty prompt, nothing pending).

`waiting` means a human is needed — do not try to answer another agent's
permission prompt on the user's behalf. Report it and let them decide.

## Putting a second agent to work

Open a terminal in the caller's own project and working directory, start an
agent in it, hand it a task, then wait:

```bash
new=$("$PLANCHETTE_CLI" session new --cwd "$PWD")
id=$(printf '%s' "$new" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["session"]["id"])')

"$PLANCHETTE_CLI" session prompt --id "$id" --text 'claude'
"$PLANCHETTE_CLI" session wait   --id "$id" --until free --timeout-ms 60000

"$PLANCHETTE_CLI" session prompt --id "$id" --text 'Review the staged diff. Report only actionable findings.'
"$PLANCHETTE_CLI" session wait   --id "$id" --until ready --until waiting --timeout-ms 600000
"$PLANCHETTE_CLI" session read   --id "$id" --lines 120
```

Notes that matter:

- `session new` puts the terminal in the **caller's project** unless
  `--project-id` says otherwise, and does not steal focus unless you pass
  `--focus`. Leave the user where they are.
- `session prompt` types the text and presses Enter. `--no-submit` types without
  submitting, for when the user should review it first.
- **`wait` only works for an agent whose state Planchette can see.** Claude Code
  reports every transition through hooks. Codex currently only claims its
  session — until its screen patterns are verified, its terminal will not change
  state, so a `wait` on it times out. For those, `session read` and judge the
  output yourself.
- `session wait` returns as soon as the state is one of the `--until` values, and
  fails with `timed_out` otherwise. Always pass a timeout you can defend; the
  default is 120 s. Waiting for `ready` alone will hang through a permission
  prompt — pass `--until waiting` too and handle it.
- `session read` returns the viewport by default (what a human would see).
  `--scrollback` reads the history instead; `--lines` bounds it. If a long answer
  is cut off, ask that agent to write its output to a file and read the file.

## Rules

- Do not close terminals or projects you did not create.
- Do not prompt a terminal that is `running`: you would interrupt a turn in
  flight. The API refuses this — `--force` overrides it, and you should only pass
  it when the user explicitly asked to interrupt.
- One task per terminal. Re-using a terminal for unrelated work makes the
  attention state meaningless for the human watching it.
- Report what you did in terms the user sees in the UI: project name and
  terminal title, not raw uuids.
