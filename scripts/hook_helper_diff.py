#!/usr/bin/env python3
"""Differential test of the hook forwarder: the shell script against the native helper.

    python3 scripts/hook_helper_diff.py <hook/planchette-hook> <built helper> [--only NAME]
    python3 scripts/hook_helper_diff.py <script> <helper> --bench 200

Run through scripts/test-hook-helper.sh, which builds the helper first.

Every case runs both forwarders against fresh fake app sockets (unix sockets in
/tmp, served by threads here) and asserts, for each of them:

  - the bytes each fake app received, connection by connection, are exactly what
    the script's contract says (`expected`, computed here independently), and
    byte-identical between the script and the helper;
  - the same exit status (0, always) and nothing on stdout;
  - for the helper: nothing on stderr either, and the time bound of the case.

Where the two differ on purpose, the case says so and why:

  script_slow   the script gets there, but late: `nc` does not bound a write the
                app never drains, the helper does (5 s, the same deadline). The
                bytes are still compared; the time bound holds for the helper only.
  script_hangs  the script never ends on its own (it is killed after a while and
                only the helper is checked): with fd 0 closed, `$(cat)` reads the
                pipe of its own command substitution and waits for itself.

--bench N runs each forwarder N times against an app that reads and closes, with a
typical PreToolUse event, and reports the CPU time (user + system) of the hook and
every process it starts, per event. A third row is a `/bin/sh` wrapper that execs
the helper: what a "wrapper script" install would cost.

Nothing here touches ~/.planchette, ~/.claude or a running Planchette: HOME is a
fresh directory for every run, and every socket is a new path in /tmp.
"""
import argparse
import os
import resource
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import uuid

DEADLINE = 5.0      # the forwarder's deadline per candidate (nc -w 5)
SLACK = 3.0         # a loaded CI runner may start a process slowly
HOLD = 8.0          # how long a stalled fake app holds a connection before it lets go

EVENTS = [
    "SessionStart", "UserPromptSubmit", "Notification", "PermissionRequest",
    "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionDenied",
    "Stop", "StopFailure", "SubagentStop", "SessionEnd",
]


# ---------------------------------------------------------------------------
# The fake app
# ---------------------------------------------------------------------------

class FakeApp:
    """A unix socket in /tmp that accepts any number of connections and treats each
    one by `behavior`:

      read       read to EOF, then close (the real app, for a hook event)
      reply      read to EOF, answer, then close (the hook must ignore the answer)
      read_hold  read to EOF, then hold the connection open until HOLD passes
      stall      read nothing and hold the connection until HOLD passes
      close_now  close at once, reading nothing
      read_some  read `limit` bytes, then close
      refuse     a socket file nobody listens on (an app that was killed)
    """

    def __init__(self, behavior="read", limit=100, path=None):
        self.behavior = behavior
        self.limit = limit
        # A short path: sun_path holds 104 bytes, and the scratch directories do not fit.
        self.dir = tempfile.mkdtemp(prefix="plt-hh-", dir="/tmp")
        self.path = path or os.path.join(self.dir, f"{uuid.uuid4().hex[:8]}.sock")
        self.connections = []           # bytes received, one entry per connection
        self.lock = threading.Lock()
        self.threads = []
        self.released = threading.Event()
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(self.path)
        os.chmod(self.path, 0o600)
        if behavior == "refuse":
            self.listener.close()       # the file stays, nobody listens: ECONNREFUSED
            self.listener = None
            return
        self.listener.listen(16)
        self.listener.settimeout(0.1)
        self.stopped = False
        self.acceptor = threading.Thread(target=self._accept, daemon=True)
        self.acceptor.start()

    @property
    def accepts(self):
        with self.lock:
            return len(self.connections)

    def received(self):
        with self.lock:
            return [bytes(c) for c in self.connections]

    def _accept(self):
        while not self.stopped:
            try:
                client, _ = self.listener.accept()
            except (socket.timeout, OSError):
                continue
            with self.lock:
                buf = bytearray()
                self.connections.append(buf)
            t = threading.Thread(target=self._serve, args=(client, buf), daemon=True)
            t.start()
            with self.lock:
                self.threads.append(t)

    def _read_to_eof(self, client, buf, limit=None):
        client.settimeout(30)
        try:
            while limit is None or len(buf) < limit:
                chunk = client.recv(65536 if limit is None else min(65536, limit - len(buf)))
                if not chunk:
                    break
                with self.lock:
                    buf.extend(chunk)
        except OSError:
            pass

    def _serve(self, client, buf):
        try:
            b = self.behavior
            if b == "read":
                self._read_to_eof(client, buf)
            elif b == "reply":
                self._read_to_eof(client, buf)
                client.sendall(b'{"ok": true, "note": "a hook must not print this"}\n')
            elif b == "read_hold":
                self._read_to_eof(client, buf)
                self.released.wait(HOLD)
            elif b == "stall":
                self.released.wait(HOLD)
            elif b == "close_now":
                pass
            elif b == "read_some":
                self._read_to_eof(client, buf, self.limit)
        finally:
            client.close()

    def settle(self):
        """Wait for every connection to be served (a held one until HOLD passes)."""
        with self.lock:
            threads = list(self.threads)
        for t in threads:
            t.join(HOLD + 30)

    def stop(self):
        self.released.set()
        if self.listener is not None:
            self.stopped = True
            self.acceptor.join(5)
            self.listener.close()
        self.settle()
        try:
            os.unlink(self.path)
        except FileNotFoundError:
            pass


# ---------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------

def model_event(session, args, stdin):
    """The script's wire format, computed without the script: what must arrive."""
    agent = args[0] if args and args[0] != b"" else b"claude"
    payload = stdin.replace(b"\0", b"").rstrip(b"\n") or b"{}"
    return b'{"planchette_session":"' + session + b'","agent":"' + agent + b'","event":' + payload + b"}"


def event_json(name, **fields):
    parts = [f'"hook_event_name":"{name}"', f'"session_id":"{uuid.uuid4()}"',
             '"transcript_path":"/Users/someone/.claude/projects/x/abc.jsonl"', '"cwd":"/Users/someone/dev"']
    for key, value in fields.items():
        parts.append(f'"{key}":{value}')
    return ("{" + ",".join(parts) + "}").encode()


class Case:
    """One scenario. `apps` names the fake apps it starts; `setup(ctx)` returns the
    environment additions and may write the pointer file; `expected(ctx)` maps app
    name → the list of payloads it must have received."""

    def __init__(self, name, *, apps=None, stdin=b"{}", args=(b"claude",), session=None,
                 setup=None, expected=None, min_seconds=None, max_seconds=None,
                 script_slow=False, script_hangs=None, helper_only=False, close_stdin=False, preload=None):
        self.name = name
        self.apps = apps or {}
        self.stdin = stdin
        self.args = list(args)
        # One session for both forwarders, so their bytes can be compared.
        self.session = session if session is not None else str(uuid.uuid4()).encode()
        self.setup = setup
        self.expected = expected
        self.min_seconds = min_seconds
        self.max_seconds = max_seconds
        self.script_slow = script_slow
        self.script_hangs = script_hangs
        self.helper_only = helper_only
        self.close_stdin = close_stdin
        self.preload = preload


class Context:
    def __init__(self, case, home):
        self.case = case
        self.home = home
        self.apps = {}
        self.session = case.session

    def pointer(self, content, mode=None):
        directory = os.path.join(self.home, ".planchette")
        os.makedirs(directory, exist_ok=True)
        path = os.path.join(directory, "socket")
        with open(path, "wb") as f:
            f.write(content)
        if mode is not None:
            os.chmod(path, mode)

    def event(self):
        return model_event(self.session, self.case.args, self.case.stdin)


def env_with(ctx, socket_path=None, **extra):
    env = {"PLANCHETTE_SESSION": ctx.session.decode("utf-8", "surrogateescape")}
    if socket_path is not None:
        env["PLANCHETTE_SOCKET"] = socket_path
    env.update(extra)
    return env


def build_cases():
    cases = []
    big = b'{"hook_event_name":"UserPromptSubmit","prompt":"' + b"x" * (5 * 1024 * 1024) + b'"}'
    mb = b'{"hook_event_name":"UserPromptSubmit","prompt":"' + b"y" * (1024 * 1024) + b'"}'
    only = lambda name: (lambda ctx: {name: [ctx.event()]})          # noqa: E731
    nothing = lambda ctx: {name: [] for name in ctx.apps}              # noqa: E731

    # Every hook event Claude Code is configured for, and Codex's claim.
    for name in EVENTS:
        fields = {}
        if name in ("PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionDenied"):
            fields = {"tool_name": '"Bash"', "tool_use_id": '"toolu_01"',
                      "tool_input": '{"command":"git status","description":"Show status"}'}
        if name == "Notification":
            fields = {"message": '"Claude needs your permission to use Bash"',
                      "notification_type": '"permission_prompt"'}
        cases.append(Case(f"event {name}", apps={"app": "read"}, stdin=event_json(name, **fields),
                          setup=lambda ctx: env_with(ctx, ctx.apps["app"].path), expected=only("app")))
    cases.append(Case("codex SessionStart", apps={"app": "read"}, args=(b"codex",),
                      stdin=event_json("SessionStart", source='"startup"'),
                      setup=lambda ctx: env_with(ctx, ctx.apps["app"].path), expected=only("app")))

    plain = lambda ctx: env_with(ctx, ctx.apps["app"].path)            # noqa: E731
    # The agent label.
    cases += [
        Case("no argument means claude", apps={"app": "read"}, args=(), setup=plain, expected=only("app")),
        Case("an empty argument means claude", apps={"app": "read"}, args=(b"",), setup=plain, expected=only("app")),
        Case("extra arguments are ignored", apps={"app": "read"}, args=(b"codex", b"x", b"--y"),
             setup=plain, expected=only("app")),
        Case("a label with spaces and umlauts", apps={"app": "read"}, args=("mein Agent ü".encode(),),
             setup=plain, expected=only("app")),
        Case("a session with a quote is passed raw", apps={"app": "read"}, session=b'ab"c\\d',
             setup=plain, expected=only("app")),
    ]

    # What stdin carries.
    allbytes = bytes(b for b in range(1, 256)) * 4
    cases += [
        Case("unicode and emoji", apps={"app": "read"},
             stdin='{"hook_event_name":"UserPromptSubmit","prompt":"Grüße 👋🏽 日本語 \\u00e9 — ✓"}'.encode(),
             setup=plain, expected=only("app")),
        Case("every byte but NUL", apps={"app": "read"}, stdin=allbytes, setup=plain, expected=only("app")),
        Case("NUL bytes are dropped", apps={"app": "read"}, stdin=b'{"a":"x\0y"}\0\0', setup=plain,
             expected=only("app")),
        Case("trailing newlines are removed", apps={"app": "read"}, stdin=b'{"a":1}\n\n\n', setup=plain,
             expected=only("app")),
        Case("CRLF keeps the CR", apps={"app": "read"}, stdin=b'{"a":1}\r\n', setup=plain, expected=only("app")),
        Case("leading and inner newlines stay", apps={"app": "read"}, stdin=b'\n\n{"a":\n1}\n', setup=plain,
             expected=only("app")),
        Case("0-byte stdin becomes {}", apps={"app": "read"}, stdin=b"", setup=plain, expected=only("app")),
        Case("only newlines becomes {}", apps={"app": "read"}, stdin=b"\n\n\n", setup=plain, expected=only("app")),
        Case("only NULs becomes {}", apps={"app": "read"}, stdin=b"\0\0", setup=plain, expected=only("app")),
        Case("closed stdin becomes {}", apps={"app": "read"}, stdin=b"", close_stdin=True, setup=plain,
             expected=only("app"), script_hangs="`$(cat)` reads its own pipe when fd 0 is closed"),
        Case("5 MB stdin arrives whole", apps={"app": "read"}, stdin=big, setup=plain, expected=only("app")),
        Case("an answer from the app is ignored", apps={"app": "reply"}, setup=plain, expected=only("app")),
    ]

    # Not inside a Planchette terminal.
    cases += [
        Case("no PLANCHETTE_SESSION: no-op", apps={"app": "read"}, stdin=mb,
             setup=lambda ctx: {"PLANCHETTE_SOCKET": ctx.apps["app"].path}, expected=nothing),
        Case("empty PLANCHETTE_SESSION: no-op", apps={"app": "read"},
             setup=lambda ctx: {"PLANCHETTE_SESSION": "", "PLANCHETTE_SOCKET": ctx.apps["app"].path},
             expected=nothing),
    ]

    # Which socket.
    def pointer_to(app, suffix=b"\n"):
        def setup(ctx):
            ctx.pointer(ctx.apps[app].path.encode() + suffix)
            return env_with(ctx, "/tmp/plt-hh-gone-" + uuid.uuid4().hex[:8] + ".sock")
        return setup

    def missing_everything(ctx):
        return env_with(ctx, "/tmp/plt-hh-gone-" + uuid.uuid4().hex[:8] + ".sock")

    cases += [
        Case("socket missing, no pointer", stdin=b"{}", setup=missing_everything, expected=lambda ctx: {}),
        Case("socket missing, pointer with newline", apps={"live": "read"}, setup=pointer_to("live"),
             expected=only("live")),
        Case("pointer without a newline", apps={"live": "read"}, setup=pointer_to("live", b""),
             expected=only("live")),
        Case("pointer: only the first line counts", apps={"live": "read"},
             setup=pointer_to("live", b"\n/tmp/other.sock\n"), expected=only("live")),
        Case("pointer cut at a NUL", apps={"live": "read"}, setup=pointer_to("live", b"\0garbage\n"),
             expected=only("live")),
        Case("pointer with CRLF names no socket", apps={"live": "read"}, setup=pointer_to("live", b"\r\n"),
             expected=lambda ctx: {"live": []}),
        Case("pointer with a trailing space names no socket", apps={"live": "read"},
             setup=pointer_to("live", b" \n"), expected=lambda ctx: {"live": []}),
    ]

    def leading_space(ctx):
        ctx.pointer(b" " + ctx.apps["live"].path.encode() + b"\n")
        return env_with(ctx, "/tmp/plt-hh-gone.sock")

    def empty_first_line(ctx):
        ctx.pointer(b"\n" + ctx.apps["live"].path.encode() + b"\n")
        return env_with(ctx, "/tmp/plt-hh-gone.sock")

    def empty_pointer(ctx):
        ctx.pointer(b"")
        return env_with(ctx, "/tmp/plt-hh-gone.sock")

    def unreadable_pointer(ctx):
        ctx.pointer(ctx.apps["live"].path.encode() + b"\n", mode=0)
        return env_with(ctx, "/tmp/plt-hh-gone.sock")

    def pointer_is_directory(ctx):
        os.makedirs(os.path.join(ctx.home, ".planchette", "socket"))
        return env_with(ctx, "/tmp/plt-hh-gone.sock")

    def long_pointer(ctx):
        ctx.pointer(b"/tmp/" + b"a" * 5000 + b"\n")
        return env_with(ctx, "/tmp/plt-hh-gone.sock")

    def no_home(ctx):
        env = env_with(ctx, "/tmp/plt-hh-gone.sock")
        env["HOME"] = None
        return env

    def env_wins(ctx):
        ctx.pointer(ctx.apps["other"].path.encode() + b"\n")
        return env_with(ctx, ctx.apps["mine"].path)

    def stale_then_pointer(ctx):
        ctx.pointer(ctx.apps["live"].path.encode() + b"\n")
        return env_with(ctx, ctx.apps["dead"].path)

    def pointer_same_as_failed(ctx):
        ctx.pointer(ctx.apps["app"].path.encode() + b"\n")
        return env_with(ctx, ctx.apps["app"].path)

    cases += [
        Case("pointer with a leading space names no socket", apps={"live": "read"}, setup=leading_space,
             expected=lambda ctx: {"live": []}),
        Case("pointer with an empty first line", apps={"live": "read"}, setup=empty_first_line,
             expected=lambda ctx: {"live": []}),
        Case("empty pointer file", setup=empty_pointer, expected=lambda ctx: {}),
        Case("unreadable pointer file", apps={"live": "read"}, setup=unreadable_pointer,
             expected=lambda ctx: {"live": []}),
        Case("pointer is a directory", setup=pointer_is_directory, expected=lambda ctx: {}),
        Case("pointer longer than any path", setup=long_pointer, expected=lambda ctx: {}),
        Case("HOME unset", setup=no_home, expected=lambda ctx: {}),
        Case("PLANCHETTE_SOCKET wins over the pointer", apps={"mine": "read", "other": "read"}, setup=env_wins,
             expected=lambda ctx: {"mine": [ctx.event()], "other": []}),
        Case("stale socket (refuses), then the pointer", apps={"dead": "refuse", "live": "read"},
             setup=stale_then_pointer, expected=lambda ctx: {"live": [ctx.event()]}),
        # The app closes before taking the event (EPIPE): a failed send. The pointer
        # names the same socket and is not tried a second time.
        Case("pointer equal to a socket that failed is not retried", apps={"app": "close_now"}, stdin=mb,
             setup=pointer_same_as_failed, expected=lambda ctx: {"app": [b""]}),
        Case("app closes after part of a big event: pointer", apps={"app": "read_some", "live": "read"},
             stdin=mb,
             setup=lambda ctx: (ctx.pointer(ctx.apps["live"].path.encode() + b"\n"),
                                env_with(ctx, ctx.apps["app"].path))[1],
             expected=lambda ctx: {"app": [ctx.event()[:100]], "live": [ctx.event()]}),
        Case("app closes after part of a small event: delivered", apps={"app": "read_some", "live": "read"},
             stdin=event_json("Stop", padding='"' + "p" * 300 + '"'),
             setup=lambda ctx: (ctx.pointer(ctx.apps["live"].path.encode() + b"\n"),
                                env_with(ctx, ctx.apps["app"].path))[1],
             expected=lambda ctx: {"app": [ctx.event()[:100]], "live": []}),
    ]

    # What is not a socket of ours.
    def symlink_to_own(ctx):
        link = os.path.join(ctx.apps["app"].dir, "link.sock")
        os.symlink(ctx.apps["app"].path, link)
        ctx.pointer(link.encode() + b"\n")
        return env_with(ctx, link)

    def regular_file(ctx):
        path = os.path.join(ctx.home, "plain")
        open(path, "w").close()
        return env_with(ctx, path)

    def directory(ctx):
        return env_with(ctx, ctx.home)

    def foreign_socket(ctx):
        return env_with(ctx, "/var/run/mDNSResponder")

    cases += [
        Case("a symlink to our own socket is refused", apps={"app": "read"}, setup=symlink_to_own,
             expected=lambda ctx: {"app": []}),
        Case("a regular file is not a socket", setup=regular_file, expected=lambda ctx: {}),
        Case("a directory is not a socket", setup=directory, expected=lambda ctx: {}),
        Case("a root-owned socket is refused", setup=foreign_socket, expected=lambda ctx: {}),
        Case("a path too long for a socket", setup=lambda ctx: env_with(ctx, "/tmp/" + "s" * 200),
             expected=lambda ctx: {}),
        # Only the helper can be made to see our own socket as someone else's: /bin/sh
        # is protected from DYLD_INSERT_LIBRARIES. Its control case is "event Stop".
        Case("our socket seen with another euid is refused (helper only)", apps={"app": "read"},
             setup=plain, expected=lambda ctx: {"app": []}, helper_only=True, preload="fake_euid"),
    ]

    # The default socket path, when nothing names one. Skipped when that path is taken.
    def default_path(ctx):
        return env_with(ctx)

    def default_path_empty(ctx):
        return env_with(ctx, "")

    cases += [
        Case("PLANCHETTE_SOCKET unset: /tmp/planchette.sock", apps={"default": "read"}, setup=default_path,
             expected=lambda ctx: {"default": [ctx.event()]}),
        Case("PLANCHETTE_SOCKET empty: /tmp/planchette.sock", apps={"default": "read"}, setup=default_path_empty,
             expected=lambda ctx: {"default": [ctx.event()]}),
    ]

    # A stalled app: the deadline.
    def stall_with_pointer(ctx):
        ctx.pointer(ctx.apps["live"].path.encode() + b"\n")
        return env_with(ctx, ctx.apps["stalled"].path)

    cases += [
        # The event fits the socket buffer: written at once, then the forwarder waits
        # for a close that never comes, and gives up at the deadline. That is a send:
        # the pointer is not tried.
        Case("accepts, never reads (small event): ends at the deadline", apps={"stalled": "stall", "live": "read"},
             setup=stall_with_pointer, expected=lambda ctx: {"stalled": [b""], "live": []},
             min_seconds=DEADLINE - 0.5, max_seconds=DEADLINE + SLACK),
        Case("reads, never closes: ends at the deadline", apps={"app": "read_hold"}, setup=plain,
             expected=only("app"), min_seconds=DEADLINE - 0.5, max_seconds=DEADLINE + SLACK),
        # The event does not fit: the write cannot finish. The helper gives up at the
        # deadline and tries the pointer; `nc` blocks until the app lets go (HOLD), dies
        # of SIGPIPE, and then the script tries the pointer too.
        Case("accepts, never reads (5 MB): gives up, then the pointer", apps={"stalled": "stall", "live": "read"},
             stdin=big, setup=stall_with_pointer, expected=lambda ctx: {"stalled": [b""], "live": [ctx.event()]},
             min_seconds=DEADLINE - 0.5, max_seconds=DEADLINE + SLACK, script_slow=True),
        Case("accepts, never reads (5 MB), no pointer", apps={"stalled": "stall"}, stdin=big,
             setup=lambda ctx: env_with(ctx, ctx.apps["stalled"].path),
             expected=lambda ctx: {"stalled": [b""]},
             min_seconds=DEADLINE - 0.5, max_seconds=DEADLINE + SLACK, script_slow=True),
    ]
    return cases


# ---------------------------------------------------------------------------
# Running
# ---------------------------------------------------------------------------

class Run:
    def __init__(self, status, stdout, stderr, seconds, received, hung):
        self.status, self.stdout, self.stderr = status, stdout, stderr
        self.seconds, self.received, self.hung = seconds, received, hung


def run_one(command, case, tools, is_script=False):
    home = tempfile.mkdtemp(prefix="plt-hh-home-")
    ctx = Context(case, home)
    try:
        for name, behavior in case.apps.items():
            if name == "default":
                # The fixed fallback path; left alone when anything else has it.
                if os.path.lexists("/tmp/planchette.sock"):
                    return None
                ctx.apps[name] = FakeApp(behavior, path="/tmp/planchette.sock")
            else:
                ctx.apps[name] = FakeApp(behavior)
        extra = case.setup(ctx) if case.setup else env_with(ctx)
        env = {"PATH": "/usr/bin:/bin", "HOME": home, "LANG": "en_US.UTF-8"}
        for key, value in extra.items():
            if value is None:
                env.pop(key, None)
            else:
                env[key] = value
        if case.preload:
            env["DYLD_INSERT_LIBRARIES"] = tools[case.preload]
        argv = [command] + [a.decode("utf-8", "surrogateescape") for a in case.args]
        if case.close_stdin:
            # No preexec_fn: it is not safe in a process that runs threads.
            argv = ["/bin/sh", "-c", 'exec "$0" "$@" <&-'] + argv
        timeout = 10 if (is_script and case.script_hangs) else 120
        started = time.monotonic()
        # A session of its own, so a hang can be ended with everything the hook started.
        process = subprocess.Popen(argv, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, start_new_session=True)
        hung = False
        try:
            out, err = process.communicate(case.stdin, timeout=timeout)
        except subprocess.TimeoutExpired:
            hung = True
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            out, err = process.communicate()
        seconds = time.monotonic() - started
        for app in ctx.apps.values():
            app.stop()
        received = {name: app.received() for name, app in ctx.apps.items()}
        return Run(process.returncode, out, err, seconds, received, hung)
    finally:
        for app in ctx.apps.values():
            app.stop()
        shutil.rmtree(home, ignore_errors=True)
        for app in ctx.apps.values():
            if app.dir.startswith("/tmp/plt-hh-"):
                shutil.rmtree(app.dir, ignore_errors=True)


def show(data, limit=120):
    if len(data) > limit:
        return f"{data[:limit]!r}… ({len(data)} bytes)"
    return repr(data)


def check_case(case, script, helper, tools):
    """Returns a list of failure messages (empty: the case passed) and the runs."""
    failures = []
    runs = {}
    if not case.helper_only:
        runs["script"] = run_one(script, case, tools, is_script=True)
    runs["helper"] = run_one(helper, case, tools)
    if any(r is None for r in runs.values()):
        return None, runs
    if runs["helper"].hung:
        failures.append("helper: never ended (killed after 120 s)")
    # A script that hangs where it is known to is reported, not compared.
    checked = dict(runs)
    if "script" in runs and runs["script"].hung:
        if case.script_hangs:
            del checked["script"]
        else:
            failures.append("script: never ended (killed) — the harness did not expect that")
    # `expected` needs only the event, which depends on the session, args and stdin.
    model = Context(case, None)
    model.apps = {name: None for name in case.apps}
    expected = case.expected(model) if case.expected else {}
    for label, run in checked.items():
        for name in case.apps:
            want = expected.get(name, [])
            got = run.received.get(name, [])
            if got != want:
                failures.append(f"{label}: app '{name}' received {[show(g) for g in got]}, "
                                f"expected {[show(w) for w in want]}")
        if run.status != 0:
            failures.append(f"{label}: exit status {run.status}, expected 0 (stderr: {run.stderr[:300]!r})")
        if run.stdout:
            failures.append(f"{label}: printed {show(run.stdout)} on stdout")
    helper_run = runs["helper"]
    if helper_run.stderr:
        failures.append(f"helper: printed {show(helper_run.stderr)} on stderr")
    if case.max_seconds is not None and helper_run.seconds > case.max_seconds:
        failures.append(f"helper: took {helper_run.seconds:.2f}s, bound {case.max_seconds:.1f}s")
    if case.min_seconds is not None and helper_run.seconds < case.min_seconds:
        failures.append(f"helper: left after {helper_run.seconds:.2f}s, before the deadline "
                        f"({case.min_seconds:.1f}s) — nc waits for the app to close")
    if "script" in checked:
        s, h = runs["script"], runs["helper"]
        if s.received != h.received:
            failures.append("script and helper delivered different bytes:\n"
                            f"        script: { {k: [show(x) for x in v] for k, v in s.received.items()} }\n"
                            f"        helper: { {k: [show(x) for x in v] for k, v in h.received.items()} }")
        if s.status != h.status:
            failures.append(f"exit status differs: script {s.status}, helper {h.status}")
        if case.max_seconds is not None and not case.script_slow and s.seconds > case.max_seconds:
            failures.append(f"script: took {s.seconds:.2f}s, bound {case.max_seconds:.1f}s (harness assumption)")
    return failures, runs


def build_tools(workdir):
    """The geteuid interposer: our own socket then belongs to "someone else"."""
    source = os.path.join(workdir, "fake_euid.c")
    with open(source, "w") as f:
        f.write(
            "#include <unistd.h>\n"
            "static uid_t fake_geteuid(void) { return getuid() + 1; }\n"
            "__attribute__((used)) static const struct { const void *replacement; const void *replacee; }\n"
            "interposers[] __attribute__((section(\"__DATA,__interpose\"))) = {\n"
            "    { (const void *)fake_geteuid, (const void *)geteuid },\n"
            "};\n")
    dylib = os.path.join(workdir, "fake_euid.dylib")
    # Both slices, so the case also runs against the helper's x86_64 slice (Rosetta).
    subprocess.run(["xcrun", "clang", "-dynamiclib", "-arch", "arm64", "-arch", "x86_64", "-Wall", "-Werror",
                    "-o", dylib, source], check=True)
    return {"fake_euid": dylib}


def differential(script, helper, only):
    workdir = tempfile.mkdtemp(prefix="plt-hh-tools-")
    tools = build_tools(workdir)
    cases = [c for c in build_cases() if not only or only.lower() in c.name.lower()]
    failed = 0
    skipped = 0
    print(f"{'case':<62} {'script':>8} {'helper':>8}  result")
    print("-" * 92)
    # Stalled cases take seconds each: run cases in parallel, report in order.
    results = [None] * len(cases)

    def work(i):
        results[i] = check_case(cases[i], script, helper, tools)

    default_cases = [i for i, c in enumerate(cases) if "default" in c.apps]
    others = [i for i in range(len(cases)) if i not in default_cases]
    threads = [threading.Thread(target=work, args=(i,)) for i in others]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    for i in default_cases:     # one fixed path: never two at once
        work(i)

    for case, (failures, runs) in zip(cases, results):
        s = runs.get("script")
        h = runs.get("helper")
        st = f"{s.seconds:7.2f}s" if s else "      — "
        ht = f"{h.seconds:7.2f}s" if h else "      — "
        if failures is None:
            skipped += 1
            print(f"{case.name:<62} {'':>8} {'':>8}  SKIP (/tmp/planchette.sock exists)")
            continue
        verdict = "ok" if not failures else "FAIL"
        note = ""
        if case.script_slow:
            note = " (script late: nc blocks on the undrained write)"
        if case.script_hangs and s is not None and s.hung:
            note = f" (script hangs: {case.script_hangs})"
        st = "   hangs" if s is not None and s.hung else st
        print(f"{case.name:<62} {st:>8} {ht:>8}  {verdict}{note}")
        for f in failures:
            print(f"      {f}")
        failed += bool(failures)
    shutil.rmtree(workdir, ignore_errors=True)
    print("-" * 92)
    print(f"{len(cases) - failed - skipped} passed, {failed} failed, {skipped} skipped")
    return failed == 0


# ---------------------------------------------------------------------------
# CPU per event
# ---------------------------------------------------------------------------

def bench(script, helper, count):
    app = FakeApp("read")
    home = tempfile.mkdtemp(prefix="plt-hh-home-")
    wrapper_dir = tempfile.mkdtemp(prefix="plt-hh-wrap-")
    wrapper = os.path.join(wrapper_dir, "planchette-hook")
    with open(wrapper, "w") as f:
        f.write(f'#!/bin/sh\nexec "{helper}" "$@"\n')
    os.chmod(wrapper, 0o755)
    stdin = event_json("PreToolUse", tool_name='"Bash"', tool_use_id='"toolu_01ABCDEF"',
                       tool_input='{"command":"git status && git diff --stat","description":"Show changes"}',
                       permission_mode='"default"')
    env = {"PATH": "/usr/bin:/bin", "HOME": home, "LANG": "en_US.UTF-8",
           "PLANCHETTE_SESSION": str(uuid.uuid4()), "PLANCHETTE_SOCKET": app.path}
    print(f"CPU per event, {count} runs each, {len(stdin)}-byte PreToolUse event, app reads and closes")
    print(f"{'forwarder':<34} {'user ms':>9} {'sys ms':>9} {'total ms':>9} {'wall ms':>9}")
    rows = {}
    for label, command in (("shell script (sh + cat + nc)", script), ("native helper", helper),
                           ("sh wrapper exec'ing the helper", wrapper)):
        for _ in range(5):   # warm the caches
            subprocess.run([command, "claude"], env=env, input=stdin, check=True)
        before = resource.getrusage(resource.RUSAGE_CHILDREN)
        started = time.monotonic()
        for _ in range(count):
            subprocess.run([command, "claude"], env=env, input=stdin, check=True)
        wall = (time.monotonic() - started) / count * 1000
        after = resource.getrusage(resource.RUSAGE_CHILDREN)
        user = (after.ru_utime - before.ru_utime) / count * 1000
        system = (after.ru_stime - before.ru_stime) / count * 1000
        rows[label] = user + system
        print(f"{label:<34} {user:9.2f} {system:9.2f} {user + system:9.2f} {wall:9.2f}")
    app.stop()
    delivered = app.received()
    expected = model_event(env["PLANCHETTE_SESSION"].encode(), [b"claude"], stdin)
    ok = len(delivered) == 3 * (count + 5) and all(d == expected for d in delivered)
    print(f"every one of the {len(delivered)} events arrived intact: {ok}")
    shutil.rmtree(home, ignore_errors=True)
    shutil.rmtree(wrapper_dir, ignore_errors=True)
    shutil.rmtree(app.dir, ignore_errors=True)
    return ok


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("script")
    parser.add_argument("helper")
    parser.add_argument("--only", help="run the cases whose name contains this text")
    parser.add_argument("--bench", type=int, metavar="N", help="measure CPU per event over N runs instead")
    options = parser.parse_args()
    for path in (options.script, options.helper):
        mode = os.stat(path).st_mode
        if not stat.S_ISREG(mode) or not os.access(path, os.X_OK):
            sys.exit(f"not an executable file: {path}")
    if options.bench:
        sys.exit(0 if bench(options.script, options.helper, options.bench) else 1)
    sys.exit(0 if differential(options.script, options.helper, options.only) else 1)


if __name__ == "__main__":
    main()
