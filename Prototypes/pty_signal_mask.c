/* Regression: a PTY child must not inherit a worker thread's blocked signals. */
#include "CChauffeur.h"
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <limits.h>

int main(int argc, char **argv, char **envp) {
    if (argc == 2 && strcmp(argv[1], "--child") == 0) {
        sigset_t current;
        struct sigaction action;
        sigprocmask(SIG_BLOCK, NULL, &current);
        sigaction(SIGINT, NULL, &action);
        int unblocked = !sigismember(&current, SIGWINCH) && !sigismember(&current, SIGTERM);
        int default_interrupt = action.sa_handler == SIG_DFL;
        printf("resize/stop signals unblocked=%d; interrupt default=%d\n", unblocked, default_interrupt);
        return unblocked && default_interrupt ? 0 : 1;
    }
    sigset_t blocked, original;
    sigemptyset(&blocked); sigaddset(&blocked, SIGWINCH); sigaddset(&blocked, SIGTERM);
    sigprocmask(SIG_BLOCK, &blocked, &original);
    signal(SIGINT, SIG_IGN);
    char executable[PATH_MAX];
    if (!realpath(argv[0], executable)) return 1;
    char *child_argv[] = {executable, "--child", NULL};
    int master = -1;
    pid_t pid = chauffeur_spawn_pty(executable, child_argv, envp, "/tmp", &master, 100, 30);
    sigprocmask(SIG_SETMASK, &original, NULL);
    if (pid < 0) { perror("spawn"); return 1; }
    char output[256];
    ssize_t count = read(master, output, sizeof(output));
    if (count > 0) write(STDOUT_FILENO, output, (size_t)count);
    int status;
    waitpid(pid, &status, 0); close(master);
    return WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : 1;
}
