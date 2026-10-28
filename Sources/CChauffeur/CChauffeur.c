#ifdef __linux__
#define _GNU_SOURCE
#endif
#include "CChauffeur.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/file.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <spawn.h>
#ifdef __linux__
#include <pty.h>
#else
#include <util.h>
#include <libproc.h>
#endif
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <signal.h>
#include <stdlib.h>
#include <stdio.h>

static int unix_socket(const char *path, int listening) {
    struct sockaddr_un address = { .sun_family = AF_UNIX };
    if (strlen(path) >= sizeof(address.sun_path)) { errno = ENAMETOOLONG; return -1; }
    strlcpy(address.sun_path, path, sizeof(address.sun_path));
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    int yes = 1;
#ifdef SO_NOSIGPIPE
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
#else
    (void)yes; // Linux has no per-socket option; writers pass MSG_NOSIGNAL instead.
#endif
    int result = listening ? bind(fd, (struct sockaddr *)&address, sizeof(address)) : connect(fd, (struct sockaddr *)&address, sizeof(address));
    if (!result && listening) { chmod(path, 0600); result = listen(fd, 32); }
    if (result < 0) { int saved = errno; close(fd); errno = saved; return -1; }
    return fd;
}
int chauffeur_unix_listen(const char *path) { return unix_socket(path, 1); }
int chauffeur_unix_connect(const char *path) { return unix_socket(path, 0); }
int chauffeur_peer_is_current_user(int fd) {
#ifdef __linux__
    struct ucred credentials; socklen_t length = sizeof credentials;
    return getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &credentials, &length) == 0 && credentials.uid == getuid();
#else
    uid_t uid; gid_t gid;
    return getpeereid(fd, &uid, &gid) == 0 && uid == getuid();
#endif
}
int chauffeur_lock(const char *path) {
    int fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) return -1;
    if (flock(fd, LOCK_EX | LOCK_NB) < 0) { int saved = errno; close(fd); errno = saved; return -1; }
    return fd;
}
pid_t chauffeur_spawn_pty(const char *executable, char *const argv[], char *const envp[], const char *cwd, int *master, unsigned short cols, unsigned short rows) {
    // forkpty makes the child a session leader with a controlling terminal. Only
    // async-signal-safe C functions run between fork and exec (never Swift).
    struct winsize size = { .ws_row = rows, .ws_col = cols };
    // Read the descriptor limit before fork; the child may only make syscalls.
    int descriptor_limit = getdtablesize();
#ifdef __APPLE__
    // The limit can be raised to about two billion (launchctl limit maxfiles), and
    // closing every number up to it delays the attach by minutes. The child lists
    // its open descriptors instead, into a buffer allocated here with headroom for
    // descriptors other threads open before fork.
    int listing_size = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, NULL, 0);
    if (listing_size < 0) listing_size = 0;
    listing_size += 256 * (int)sizeof(struct proc_fdinfo);
    struct proc_fdinfo *listing = malloc(listing_size);
#endif
    pid_t pid = forkpty(master, NULL, NULL, &size);
    if (pid == 0) {
        // Dispatch/NIO worker threads can block signals. exec preserves that
        // mask and ignored dispositions, which otherwise makes a tmux client
        // silently ignore resize or stop. Reset only this child, using POSIX
        // async-signal-safe calls before exec.
        struct sigaction default_action = { .sa_handler = SIG_DFL, .sa_flags = 0 };
        sigemptyset(&default_action.sa_mask);
        for (int signum = 1; signum < NSIG; signum++) {
            if (signum != SIGKILL && signum != SIGSTOP) sigaction(signum, &default_action, NULL);
        }
        sigset_t unblocked;
        sigemptyset(&unblocked);
        if (sigprocmask(SIG_SETMASK, &unblocked, NULL) < 0) _exit(126);
        // Unlike Foundation's Process, forkpty passes on every descriptor that
        // lacks FD_CLOEXEC, including pipes other threads are handing to their
        // own commands. A long-lived tmux client holding such a pipe's write end
        // keeps that command's output from ever reaching EOF.
        int first_unlisted = STDERR_FILENO + 1;
#ifdef __APPLE__
        // After fork this thread is the only one, so the listing is complete unless
        // it filled the buffer; then close everything above the last listed number.
        // proc_pidinfo returns 0 on failure, and a successful listing always has the
        // terminal on 0-2, so 0 keeps the full loop.
        int listed = listing ? proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, listing, listing_size) : 0;
        if (listed > 0) {
            int count = listed / (int)sizeof(struct proc_fdinfo);
            for (int index = 0; index < count; index++) {
                if (listing[index].proc_fd > STDERR_FILENO) close(listing[index].proc_fd);
            }
            first_unlisted = listed + (int)sizeof(struct proc_fdinfo) > listing_size && count > 0
                ? listing[count - 1].proc_fd + 1 : descriptor_limit;
        }
#endif
        for (int fd = first_unlisted; fd < descriptor_limit; fd++) close(fd);
        if (chdir(cwd) < 0) _exit(126);
        execve(executable, argv, envp);
        _exit(127);
    }
#ifdef __APPLE__
    free(listing);
#endif
    if (pid > 0) fcntl(*master, F_SETFD, FD_CLOEXEC);
    return pid;
}
int chauffeur_resize(int fd, unsigned short cols, unsigned short rows) {
    struct winsize size = { .ws_row = rows, .ws_col = cols };
    return ioctl(fd, TIOCSWINSZ, &size);
}

int chauffeur_rename_exclusive(const char *from, const char *to) {
    return chauffeur_renameat_exclusive(AT_FDCWD, from, AT_FDCWD, to);
}
int chauffeur_renameat_exclusive(int from_fd, const char *from, int to_fd, const char *to) {
#ifdef __linux__
    return renameat2(from_fd, from, to_fd, to, RENAME_NOREPLACE);
#else
    return renameatx_np(from_fd, from, to_fd, to, RENAME_EXCL);
#endif
}

pid_t chauffeur_spawn(const char *executable, char *const argv[], char *const envp[], const char *cwd, int stdin_fd, int stdout_fd, int stderr_fd) {
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    int error = posix_spawn_file_actions_init(&actions);
    if (error) { errno = error; return -1; }
    if ((error = posix_spawnattr_init(&attributes))) { posix_spawn_file_actions_destroy(&actions); errno = error; return -1; }
    short flags = POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF;
    // Only the three standard descriptors reach the child, whatever other threads
    // have open without FD_CLOEXEC at this moment.
    if (!error) error = posix_spawn_file_actions_adddup2(&actions, stdin_fd, STDIN_FILENO);
    if (!error) error = posix_spawn_file_actions_adddup2(&actions, stdout_fd, STDOUT_FILENO);
    if (!error) error = posix_spawn_file_actions_adddup2(&actions, stderr_fd, STDERR_FILENO);
#ifdef __APPLE__
    flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
#else
    if (!error) error = posix_spawn_file_actions_addclosefrom_np(&actions, STDERR_FILENO + 1);
#endif
    if (!error && cwd) error = posix_spawn_file_actions_addchdir_np(&actions, cwd);
    // Threads of the calling process block most signals, and the mask survives exec:
    // a tmux server started with SIGCHLD blocked never reaps its panes. Start the
    // child with nothing blocked and every catchable signal at its default action.
    sigset_t unblocked, defaults;
    sigemptyset(&unblocked);
    sigfillset(&defaults);
    sigdelset(&defaults, SIGKILL);
    sigdelset(&defaults, SIGSTOP);
    if (!error) error = posix_spawnattr_setsigmask(&attributes, &unblocked);
    if (!error) error = posix_spawnattr_setsigdefault(&attributes, &defaults);
    if (!error) error = posix_spawnattr_setflags(&attributes, flags);
    pid_t pid = -1;
    if (!error) error = posix_spawn(&pid, executable, &actions, &attributes, argv, envp);
    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);
    if (error) { errno = error; return -1; }
    return pid;
}

int chauffeur_birth_time(const char *path, long long *seconds, long *nanoseconds) {
#ifdef __linux__
    struct statx info;
    if (statx(AT_FDCWD, path, 0, STATX_BTIME, &info) != 0) return -1;
    if (!(info.stx_mask & STATX_BTIME)) { errno = ENOTSUP; return -1; }
    *seconds = info.stx_btime.tv_sec;
    *nanoseconds = info.stx_btime.tv_nsec;
#else
    struct stat info;
    if (stat(path, &info) != 0) return -1;
    *seconds = info.st_birthtimespec.tv_sec;
    *nanoseconds = info.st_birthtimespec.tv_nsec;
#endif
    return 0;
}

int chauffeur_pipe(int descriptors[2]) {
#ifdef __linux__
    return pipe2(descriptors, O_CLOEXEC);
#else
    if (pipe(descriptors) != 0) return -1;
    fcntl(descriptors[0], F_SETFD, FD_CLOEXEC);
    fcntl(descriptors[1], F_SETFD, FD_CLOEXEC);
    return 0;
#endif
}
