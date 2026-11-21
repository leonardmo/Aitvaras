#include "CGatewayPTY.h"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#include <util.h>

static const int signals[] = {SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGWINCH, SIGTSTP, SIGCONT};
#define SIGNAL_COUNT (sizeof(signals) / sizeof(signals[0]))
_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "Signal handoff requires lock-free atomics");
static _Atomic int pending[NSIG];

static void mark_signal(int signal) { atomic_store_explicit(&pending[signal], 1, memory_order_relaxed); }

static void pause_briefly(void) {
    const struct timespec delay = {0, 20 * 1000 * 1000};
    nanosleep(&delay, NULL);
}

static long long monotonic_milliseconds(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (long long)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static int resize_terminal(int master, int input) {
    struct winsize window;
    return master >= 0 && ioctl(input, TIOCGWINSZ, &window) == 0 &&
        ioctl(master, TIOCSWINSZ, &window) == 0;
}

static void signal_child(pid_t child, int master, int signal) {
    pid_t foreground = master >= 0 ? tcgetpgrp(master) : -1;
    if (foreground > 0 && foreground != child && foreground != getpgrp())
        kill(-foreground, signal);
    if (kill(-child, signal) < 0 && errno == ESRCH) kill(child, signal);
}

static void child_setup_failed(int report) {
    int code = errno;
    (void)write(report, &code, sizeof(code));
    _exit(code == ENOENT ? 127 : 126);
}

static pid_t start_pty(const char *path, char *const argv[], char *const envp[],
                       int *master, struct termios *terminal, int input,
                       const sigset_t *child_mask) {
    struct winsize window = {0};
    ioctl(input, TIOCGWINSZ, &window);
    int slave;
    if (openpty(master, &slave, NULL, terminal, &window) < 0) return -1;
    int report[2];
    if (pipe(report) < 0) {
        int code = errno; close(slave); errno = code; return -1;
    }
    if (fcntl(report[1], F_SETFD, FD_CLOEXEC) < 0) {
        int code = errno; close(report[0]); close(report[1]); close(slave); errno = code; return -1;
    }
    struct sigaction defaults = {0};
    defaults.sa_handler = SIG_DFL;
    sigemptyset(&defaults.sa_mask);
    pid_t child = fork();
    if (child == 0) {
        // Only async-signal-safe operations between fork and exec.
        close(*master);
        close(report[0]);
        sigset_t job_control;
        sigemptyset(&job_control);
        sigaddset(&job_control, SIGTTOU);
        sigprocmask(SIG_BLOCK, &job_control, NULL);
        if (setsid() < 0 || ioctl(slave, TIOCSCTTY, 0) < 0 || tcsetpgrp(slave, getpid()) < 0)
            child_setup_failed(report[1]);
        for (int fd = STDIN_FILENO; fd <= STDERR_FILENO; ++fd) {
            if (dup2(slave, fd) < 0) child_setup_failed(report[1]);
        }
        if (slave > STDERR_FILENO) close(slave);
        if (input > STDERR_FILENO) close(input);
        for (int signum = 1; signum < NSIG; ++signum) {
            if (signum != SIGKILL && signum != SIGSTOP &&
                sigaction(signum, &defaults, NULL) < 0 && errno != EINVAL)
                child_setup_failed(report[1]);
        }
        if (sigprocmask(SIG_SETMASK, child_mask, NULL) < 0) child_setup_failed(report[1]);
        execve(path, argv, envp);
        child_setup_failed(report[1]);
    }

    int code = errno;
    close(slave);
    close(report[1]);
    if (child >= 0) {
        struct pollfd reporter = {report[0], POLLIN, 0};
        int ready = poll(&reporter, 1, 2000);
        ssize_t n = ready > 0 ? read(report[0], &code, sizeof(code)) : -1;
        if (n != 0) {
            if (n != sizeof(code)) code = ready == 0 ? ETIMEDOUT : EIO;
            kill(child, SIGKILL);
            while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
            child = -1;
        }
    }
    close(report[0]);
    if (child < 0) errno = code;
    return child;
}

static pid_t start_child(const char *path, char *const argv[], char *const envp[],
                         int interactive, int *master, struct termios *terminal, int input,
                         const sigset_t *child_mask) {
    if (interactive) return start_pty(path, argv, envp, master, terminal, input, child_mask);

    posix_spawnattr_t attributes;
    int rc = posix_spawnattr_init(&attributes);
    if (rc) { errno = rc; return -1; }
    sigset_t defaults;
    sigfillset(&defaults);
    sigdelset(&defaults, SIGKILL);
    sigdelset(&defaults, SIGSTOP);
    // A redirection can leave one real terminal behind. Let that child
    // stay in the foreground group so terminal reads do not get SIGTTIN.
    int shared_terminal = isatty(STDIN_FILENO) || isatty(STDOUT_FILENO) || isatty(STDERR_FILENO);
    short flags = POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT;
    if (!shared_terminal) flags |= POSIX_SPAWN_SETPGROUP;
    rc = posix_spawnattr_setflags(&attributes, flags);
    if (!rc && !shared_terminal) rc = posix_spawnattr_setpgroup(&attributes, 0);
    if (!rc) rc = posix_spawnattr_setsigmask(&attributes, child_mask);
    if (!rc) rc = posix_spawnattr_setsigdefault(&attributes, &defaults);
    pid_t child = -1;
    posix_spawn_file_actions_t actions;
    int action_error = posix_spawn_file_actions_init(&actions);
    if (!rc) rc = action_error;
    if (!action_error) {
        for (int fd = STDIN_FILENO; !rc && fd <= STDERR_FILENO; ++fd) {
            if (fcntl(fd, F_GETFD) >= 0) rc = posix_spawn_file_actions_addinherit_np(&actions, fd);
        }
        if (!rc) rc = posix_spawn(&child, path, &actions, &attributes, argv, envp);
        posix_spawn_file_actions_destroy(&actions);
    }
    posix_spawnattr_destroy(&attributes);
    if (rc) { errno = rc; return -1; }
    return child;
}

struct buffer {
    char data[16384];
    size_t start, end;
};

static int read_buffer(int fd, struct buffer *buffer) {
    ssize_t count = read(fd, buffer->data, sizeof(buffer->data));
    if (count > 0) { buffer->start = 0; buffer->end = (size_t)count; return 1; }
    if (count < 0 && (errno == EAGAIN || errno == EINTR)) return 1;
    return 0; // PTY EOF may arrive as EIO on macOS.
}

static int write_buffer(int fd, struct buffer *buffer) {
    size_t remaining = buffer->end - buffer->start;
    ssize_t count = write(fd, buffer->data + buffer->start, remaining > 4096 ? 4096 : remaining);
    if (count > 0) { buffer->start += (size_t)count; return 1; }
    return count < 0 && (errno == EAGAIN || errno == EINTR);
}

static int buffered(const struct buffer *buffer) { return buffer->start < buffer->end; }

int aitvaras_supervise(const char *path, char *const argv[], char *const envp[], int interactive, int input, int output, int test_timeout_ms) {
    struct termios saved, raw;
    int master = -1, status = 0, error = 0;
    pid_t child = -1;
    int was_raw = 0, child_done = 0, installed = 0;
    for (size_t i = 0; i < SIGNAL_COUNT; ++i) atomic_store(&pending[signals[i]], 0);
    if (interactive) {
        if (tcgetattr(input, &saved) < 0) return -1;
        raw = saved;
        cfmakeraw(&raw);
    }

    struct sigaction old[SIGNAL_COUNT], old_pipe;
    struct sigaction handler = {0};
    handler.sa_handler = mark_signal;
    sigemptyset(&handler.sa_mask);
    sigset_t mask, original_mask, active_mask;
    sigemptyset(&mask);
    for (size_t i = 0; i < SIGNAL_COUNT; ++i) sigaddset(&mask, signals[i]);
    if (sigprocmask(SIG_BLOCK, &mask, &original_mask) < 0) return -1;
    active_mask = original_mask;
    for (size_t i = 0; i < SIGNAL_COUNT; ++i) sigdelset(&active_mask, signals[i]);
    for (size_t i = 0; i < SIGNAL_COUNT; ++i) {
        if (sigaction(signals[i], &handler, &old[i]) < 0) { error = errno; goto cleanup; }
        installed++;
    }
    struct sigaction ignore = {0};
    ignore.sa_handler = SIG_IGN;
    sigemptyset(&ignore.sa_mask);
    int pipe_installed = sigaction(SIGPIPE, &ignore, &old_pipe) == 0;
    sigset_t child_mask;
    sigemptyset(&child_mask);
    child = start_child(path, argv, envp, interactive, &master, &saved, input, &child_mask);
    if (child < 0) { error = errno; goto restore_pipe; }
    if (interactive) {
        if (fcntl(master, F_SETFD, FD_CLOEXEC) < 0 || fcntl(master, F_SETFL, O_NONBLOCK) < 0 ||
            tcsetattr(input, TCSANOW, &raw) < 0) { error = errno; goto restore_pipe; }
        was_raw = 1;
    }
    sigprocmask(SIG_SETMASK, &active_mask, NULL);

    struct buffer to_child = {0}, to_terminal = {0};
    int input_open = 1, master_open = 1, drain = 0;
    long long test_deadline = test_timeout_ms > 0 ? monotonic_milliseconds() + test_timeout_ms : 0;
    while (1) {
        if (test_deadline && monotonic_milliseconds() >= test_deadline) { error = ETIMEDOUT; break; }
        if (!child_done) {
            for (size_t i = 0; i < SIGNAL_COUNT; ++i) {
                int sig = signals[i];
                if (!atomic_exchange_explicit(&pending[sig], 0, memory_order_relaxed)) continue;
                if (sig != SIGWINCH || resize_terminal(master, input))
                    signal_child(child, master, sig);
            }
            pid_t result = waitpid(child, &status, WNOHANG | WUNTRACED | WCONTINUED);
            if (result < 0 && errno != EINTR) { error = errno; break; }
            if (result == child && WIFSTOPPED(status)) {
                if (test_deadline) { error = EIO; break; }
                if (was_raw) tcsetattr(input, TCSANOW, &saved);
                kill(getpid(), SIGSTOP);
                if (was_raw && tcsetattr(input, TCSANOW, &raw) < 0) { error = errno; break; }
                resize_terminal(master, input);
                signal_child(child, master, SIGCONT);
            } else if (result == child && (WIFEXITED(status) || WIFSIGNALED(status))) {
                child_done = 1;
            }
        }
        if (!interactive) {
            if (child_done) break;
            pause_briefly();
            continue;
        }
        // Drain final output without waiting indefinitely on a descendant
        // that retained the slave descriptor after the CLI exited.
        if (child_done && ((!master_open && !buffered(&to_terminal)) || ++drain > 20)) break;
        struct pollfd descriptors[] = {
            {input_open && !child_done && !buffered(&to_child) ? input : -1, POLLIN, 0},
            {master_open ? master : -1,
                (!buffered(&to_terminal) ? POLLIN : 0) | (!child_done && buffered(&to_child) ? POLLOUT : 0), 0},
            {buffered(&to_terminal) ? output : -1, POLLOUT, 0}
        };
        int ready = poll(descriptors, 3, 25);
        if (ready < 0 && errno != EINTR) { error = errno; break; }
        if (ready <= 0) continue;
        if (descriptors[0].revents && !read_buffer(input, &to_child)) {
            input_open = 0;
            signal_child(child, master, SIGHUP);
        }
        if ((descriptors[1].revents & POLLOUT) && !write_buffer(master, &to_child)) master_open = 0;
        if ((descriptors[1].revents & (POLLIN | POLLHUP | POLLERR)) && !buffered(&to_terminal))
            master_open = read_buffer(master, &to_terminal);
        if (descriptors[2].revents && !write_buffer(output, &to_terminal)) {
            error = EPIPE; break;
        }
    }

restore_pipe:
    sigprocmask(SIG_BLOCK, &mask, NULL);
    if (was_raw) tcsetattr(input, TCSANOW, &saved);
    if (child > 0 && !child_done) {
        signal_child(child, master, SIGKILL);
        while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
    }
    if (master >= 0) close(master);
    if (pipe_installed) sigaction(SIGPIPE, &old_pipe, NULL);
cleanup:
    while (installed > 0) { --installed; sigaction(signals[installed], &old[installed], NULL); }
    sigprocmask(SIG_SETMASK, &original_mask, NULL);
    if (error) { errno = error; return -1; }
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}
