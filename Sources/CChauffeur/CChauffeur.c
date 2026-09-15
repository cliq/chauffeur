#include "CChauffeur.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/file.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <spawn.h>
#include <util.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <signal.h>
#include <stdlib.h>

static int unix_socket(const char *path, int listening) {
    struct sockaddr_un address = { .sun_family = AF_UNIX };
    if (strlen(path) >= sizeof(address.sun_path)) { errno = ENAMETOOLONG; return -1; }
    strlcpy(address.sun_path, path, sizeof(address.sun_path));
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
    int result = listening ? bind(fd, (struct sockaddr *)&address, sizeof(address)) : connect(fd, (struct sockaddr *)&address, sizeof(address));
    if (!result && listening) { chmod(path, 0600); result = listen(fd, 32); }
    if (result < 0) { int saved = errno; close(fd); errno = saved; return -1; }
    return fd;
}
int chauffeur_unix_listen(const char *path) { return unix_socket(path, 1); }
int chauffeur_unix_connect(const char *path) { return unix_socket(path, 0); }
int chauffeur_peer_is_current_user(int fd) {
    uid_t uid; gid_t gid;
    return getpeereid(fd, &uid, &gid) == 0 && uid == getuid();
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
        if (chdir(cwd) < 0) _exit(126);
        execve(executable, argv, envp);
        _exit(127);
    }
    if (pid > 0) fcntl(*master, F_SETFD, FD_CLOEXEC);
    return pid;
}
int chauffeur_resize(int fd, unsigned short cols, unsigned short rows) {
    struct winsize size = { .ws_row = rows, .ws_col = cols };
    return ioctl(fd, TIOCSWINSZ, &size);
}
