/*
 * planchette-hook — the native hook forwarder.
 *
 * Claude Code runs the hook command on every hook event of every agent
 * (PreToolUse, PostToolUse, Stop, ...). The shell script `hook/planchette-hook`
 * spends 15-17 ms of CPU per event on its shell, `cat` and `nc`. This program
 * does exactly what the script does, byte for byte, in one process:
 *
 *   - $PLANCHETTE_SESSION empty or unset: exit 0 at once, stdin not read.
 *   - The event JSON is all of stdin, NUL bytes dropped and trailing newlines
 *     removed (what `payload=$(cat)` does); nothing left becomes `{}`. A closed
 *     stdin reads as empty (the script's `$(cat)` then waits on its own pipe for good).
 *   - The agent label is argv[1], or "claude" when it is missing or empty.
 *   - The wire format, written raw (the script does not escape either value):
 *       {"planchette_session":"<session>","agent":"<label>","event":<json>}
 *   - Candidates, in order: $PLANCHETTE_SOCKET (default /tmp/planchette.sock),
 *     then the first line of $HOME/.planchette/socket. An empty candidate, or one
 *     equal to the one tried before it, is skipped.
 *   - A candidate is used only when it is a socket this user owns and not a
 *     symlink (`[ -L ]`, `[ -S ]`, `[ -O ]` in the script; see there for why).
 *   - A candidate that refuses the connection, or that breaks it before the whole
 *     event is written, is a failed send: the next candidate is tried. One that
 *     took the whole event is the end, however it answers.
 *   - 5 seconds per candidate, the app's own read deadline (the script's
 *     `nc -w 5`): after the event is written the half-closed connection is held
 *     until the app closes it, as `nc` does, and given up at the deadline. Unlike
 *     `nc`, a write the app never drains is bounded by the same deadline.
 *   - Exit status 0, always, and nothing on stdout or stderr: a missing, busy or
 *     stalled app must never block or fail the agent.
 *
 * The app installs this binary as ~/.planchette/planchette-hook after it has
 * proved that it runs, and the script otherwise (HookInstaller.deployHook).
 * Built by hook/build-hook-helper.sh; scripts/test-hook-helper.sh runs it and the
 * script side by side and compares what reaches the socket.
 */

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#define DEADLINE_MS 5000
#define DEFAULT_SOCKET "/tmp/planchette.sock"
#define POINTER_SUFFIX "/.planchette/socket"
#define READ_CHUNK 65536

/* A growable byte buffer. Every failure to grow ends the program quietly. */
struct buffer {
    char *bytes;
    size_t length;
    size_t capacity;
};

static int64_t now_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* Milliseconds left until `deadline`, for poll(): 0 once it has passed. */
static int remaining_ms(int64_t deadline) {
    int64_t left = deadline - now_ms();
    if (left <= 0) return 0;
    if (left > INT_MAX) return INT_MAX;
    return (int)left;
}

static int reserve(struct buffer *buf, size_t extra) {
    if (extra <= buf->capacity - buf->length) return 0;
    if (extra > SIZE_MAX - buf->length) return -1;
    size_t needed = buf->length + extra;
    size_t capacity = buf->capacity ? buf->capacity : READ_CHUNK;
    while (capacity < needed) {
        if (capacity > SIZE_MAX / 2) {
            capacity = needed;
            break;
        }
        capacity *= 2;
    }
    char *grown = realloc(buf->bytes, capacity);
    if (grown == NULL) return -1;
    buf->bytes = grown;
    buf->capacity = capacity;
    return 0;
}

static int append(struct buffer *buf, const char *bytes, size_t count) {
    if (reserve(buf, count) != 0) return -1;
    memcpy(buf->bytes + buf->length, bytes, count);
    buf->length += count;
    return 0;
}

static int append_string(struct buffer *buf, const char *string) {
    return append(buf, string, strlen(string));
}

/* Remove the NUL bytes from bytes[0..count), in place; returns the new count.
 * bash drops them from a command substitution, so `$(cat)` never carries one. */
static size_t drop_nul_bytes(char *bytes, size_t count) {
    char *nul = memchr(bytes, '\0', count);
    if (nul == NULL) return count;
    size_t kept = (size_t)(nul - bytes);
    for (size_t i = kept + 1; i < count; i++) {
        if (bytes[i] != '\0') bytes[kept++] = bytes[i];
    }
    return kept;
}

/* Wait until `fd` is readable. Used only when stdin was handed over non-blocking. */
static void wait_readable(int fd) {
    struct pollfd watch = {.fd = fd, .events = POLLIN, .revents = 0};
    while (poll(&watch, 1, -1) < 0 && errno == EINTR) {
    }
}

/* Append all of stdin. A read error ends the input with what arrived before it,
 * as `cat` does. Returns -1 only when memory runs out. */
static int read_stdin(struct buffer *buf) {
    for (;;) {
        if (reserve(buf, READ_CHUNK) != 0) return -1;
        ssize_t count = read(STDIN_FILENO, buf->bytes + buf->length, READ_CHUNK);
        if (count > 0) {
            buf->length += drop_nul_bytes(buf->bytes + buf->length, (size_t)count);
            continue;
        }
        if (count == 0) return 0;
        if (errno == EINTR) continue;
        if (errno == EAGAIN) {
            wait_readable(STDIN_FILENO);
            continue;
        }
        return 0;
    }
}

/* The first line of $HOME/.planchette/socket, as `IFS= read -r POINTER` reads it:
 * up to the first newline, cut at the first NUL. Empty when there is no readable
 * file. A line longer than any path cannot name a socket and comes back empty
 * as well (the script's `[ -S ]` fails on it with ENAMETOOLONG). Opened
 * non-blocking, so a FIFO in its place cannot hang the agent. */
static void read_pointer(char *out, size_t size) {
    out[0] = '\0';
    const char *home = getenv("HOME");
    char path[PATH_MAX + 1];
    int written = snprintf(path, sizeof path, "%s%s", home ? home : "", POINTER_SUFFIX);
    if (written < 0 || (size_t)written >= sizeof path) return;

    int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return;
    size_t length = 0;
    int complete = 0;
    while (length < size - 1) {
        ssize_t count = read(fd, out + length, size - 1 - length);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            complete = 1;
            break;
        }
        size_t start = length;
        length += (size_t)count;
        if (memchr(out + start, '\n', (size_t)count) != NULL ||
            memchr(out + start, '\0', (size_t)count) != NULL) {
            complete = 1;
            break;
        }
    }
    close(fd);
    out[length] = '\0';   /* the C string now ends at the first NUL, if any */
    char *newline = strchr(out, '\n');
    if (newline != NULL) {
        *newline = '\0';
    } else if (!complete) {
        out[0] = '\0';    /* no line end within `size` bytes: no path is that long */
    }
}

/* `[ -L ] && continue; [ -S ] || continue; [ -O ] || continue` */
static int is_own_socket(const char *path) {
    struct stat info;
    if (lstat(path, &info) != 0) return 0;
    if (S_ISLNK(info.st_mode)) return 0;
    if (!S_ISSOCK(info.st_mode)) return 0;
    return info.st_uid == geteuid();
}

static int connect_socket(const char *path, int64_t deadline) {
    struct sockaddr_un address;
    memset(&address, 0, sizeof address);
    address.sun_family = AF_UNIX;
    size_t length = strlen(path);
    if (length >= sizeof address.sun_path) return -1;
    memcpy(address.sun_path, path, length);

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int on = 1;
    (void)fcntl(fd, F_SETFD, FD_CLOEXEC);
    (void)setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
    int flags = fcntl(fd, F_GETFL);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) != 0) {
        close(fd);
        return -1;
    }
    if (connect(fd, (struct sockaddr *)&address, (socklen_t)sizeof address) == 0) return fd;
    if (errno != EINPROGRESS && errno != EINTR && errno != EALREADY) {
        close(fd);
        return -1;
    }
    /* Still connecting: wait for the outcome within the deadline. */
    for (;;) {
        struct pollfd watch = {.fd = fd, .events = POLLOUT, .revents = 0};
        int ready = poll(&watch, 1, remaining_ms(deadline));
        if (ready < 0 && errno == EINTR) continue;
        if (ready <= 0) {
            close(fd);
            return -1;
        }
        int error = 0;
        socklen_t size = sizeof error;
        if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) != 0 || error != 0) {
            close(fd);
            return -1;
        }
        return fd;
    }
}

/* Write all of `bytes` before the deadline. 0 when the whole event went out. */
static int write_all(int fd, const char *bytes, size_t count, int64_t deadline) {
    size_t sent = 0;
    while (sent < count) {
        ssize_t written = write(fd, bytes + sent, count - sent);
        if (written > 0) {
            sent += (size_t)written;
            continue;
        }
        if (written < 0 && errno == EINTR) continue;
        if (written < 0 && errno == EAGAIN) {
            struct pollfd watch = {.fd = fd, .events = POLLOUT, .revents = 0};
            int ready = poll(&watch, 1, remaining_ms(deadline));
            if (ready < 0 && errno == EINTR) continue;
            if (ready <= 0) return -1;   /* the app stopped reading: give up */
            continue;
        }
        return -1;   /* EPIPE, ECONNRESET: the app closed before taking it all */
    }
    return 0;
}

/* After the event: half-close, then wait for the app to close its side, as `nc`
 * does, reading (and dropping) whatever it says. Ends at the deadline. */
static void wait_for_close(int fd, int64_t deadline) {
    (void)shutdown(fd, SHUT_WR);
    char sink[4096];
    for (;;) {
        struct pollfd watch = {.fd = fd, .events = POLLIN, .revents = 0};
        int ready = poll(&watch, 1, remaining_ms(deadline));
        if (ready < 0 && errno == EINTR) continue;
        if (ready <= 0) return;
        ssize_t count = read(fd, sink, sizeof sink);
        if (count > 0) continue;
        if (count < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        return;   /* EOF, or the connection broke */
    }
}

/* 0 when the candidate took the whole event (the script's `nc` succeeded). */
static int send_event(const char *path, const struct buffer *event) {
    int64_t deadline = now_ms() + DEADLINE_MS;
    int fd = connect_socket(path, deadline);
    if (fd < 0) return -1;
    if (write_all(fd, event->bytes, event->length, deadline) != 0) {
        close(fd);
        return -1;
    }
    wait_for_close(fd, deadline);
    close(fd);
    return 0;
}

int main(int argc, char **argv) {
    /* A write to an app that went away must fail with EPIPE, not kill us. */
    signal(SIGPIPE, SIG_IGN);

    const char *session = getenv("PLANCHETTE_SESSION");
    if (session == NULL || session[0] == '\0') return 0;

    const char *socket_path = getenv("PLANCHETTE_SOCKET");
    if (socket_path == NULL || socket_path[0] == '\0') socket_path = DEFAULT_SOCKET;

    char pointer[4096];
    read_pointer(pointer, sizeof pointer);

    const char *agent = (argc > 1 && argv[1][0] != '\0') ? argv[1] : "claude";

    /* The envelope is written first and stdin read straight in after it, so the
     * event — up to megabytes of prompt — is never copied. */
    struct buffer event = {NULL, 0, 0};
    if (append_string(&event, "{\"planchette_session\":\"") != 0 ||
        append_string(&event, session) != 0 ||
        append_string(&event, "\",\"agent\":\"") != 0 ||
        append_string(&event, agent) != 0 ||
        append_string(&event, "\",\"event\":") != 0) {
        return 0;
    }
    size_t envelope = event.length;
    if (read_stdin(&event) != 0) return 0;
    while (event.length > envelope && event.bytes[event.length - 1] == '\n') event.length--;
    if (event.length == envelope && append_string(&event, "{}") != 0) return 0;
    if (append_string(&event, "}") != 0) return 0;

    const char *candidates[2] = {socket_path, pointer};
    const char *tried = "";
    for (int i = 0; i < 2; i++) {
        const char *target = candidates[i];
        if (target[0] == '\0') continue;
        /* The pointer usually names the same socket: one failed send to it is enough. */
        if (strcmp(target, tried) == 0) continue;
        tried = target;
        if (!is_own_socket(target)) continue;
        if (send_event(target, &event) == 0) break;
    }

    free(event.bytes);
    return 0;
}
