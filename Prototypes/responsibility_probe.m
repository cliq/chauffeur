// Diagnostic only: no private responsibility mutation or production dependency.
#import <AppKit/AppKit.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;
static const char *executable, *directory, *tmux;
static void accessProbe(const char *phase) {
    NSString *config = [NSString stringWithFormat:@"%s/access-path.txt", directory];
    NSString *path = [NSString stringWithContentsOfFile:config encoding:NSUTF8StringEncoding error:NULL];
    if (!path) return;
    int fd = open(path.fileSystemRepresentation, O_RDONLY);
    int error = fd < 0 ? errno : 0;
    if (fd >= 0) close(fd);
    NSDictionary *row = @{@"pid": @(getpid()), @"opened": @(fd >= 0), @"errno": @(error)};
    NSString *out = [NSString stringWithFormat:@"%s/access-%s.json", directory, phase];
    [[NSJSONSerialization dataWithJSONObject:row options:0 error:NULL] writeToFile:out atomically:YES];
}
static void record(const char *name) {
    pid_t (*responsible)(pid_t) = dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid");
    NSString *path = [NSString stringWithFormat:@"%s/%s.json", directory, name];
    NSDictionary *row = @{@"pid": @(getpid()), @"ppid": @(getppid()),
        @"responsible": @(responsible ? responsible(getpid()) : -1)};
    [[NSJSONSerialization dataWithJSONObject:row options:0 error:NULL] writeToFile:path atomically:YES];
}
static pid_t spawn(char *const args[], short flags, BOOL wait) {
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr, flags);
    if (flags & POSIX_SPAWN_SETPGROUP) posix_spawnattr_setpgroup(&attr, 0);
    pid_t pid = 0;
    int error = posix_spawn(&pid, args[0], NULL, &attr, args, environ);
    posix_spawnattr_destroy(&attr);
    if (error) { fprintf(stderr, "spawn: %s\n", strerror(error)); exit(1); }
    if (wait) { int status; waitpid(pid, &status, 0); if (status) exit(2); }
    return pid;
}
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 5) return 64;
        alarm(600); // Bound abandoned fixtures, including an unanswered TCC prompt.
        executable = argv[0]; directory = argv[2]; tmux = argv[3];
        const char *mode = argv[1], *name = argv[4];
        if (!strcmp(mode, "hold")) { record(name); sleep(600); return 0; }
        if (!strcmp(mode, "leaf")) {
            record(name);
            if (!strcmp(name, "pane") && ![[NSFileManager defaultManager] fileExistsAtPath:
                    [NSString stringWithFormat:@"%s/access-after-only", directory]]) accessProbe("before");
            if (!strcmp(name, "later") || !strcmp(name, "after-replacement")) accessProbe(name);
            // A file gate permits measuring the same process after its owner exits.
            NSString *gate = [NSString stringWithFormat:@"%s/sample-after-exit", directory];
            for (int i = 0; i < 1200; i++) {
                if ([[NSFileManager defaultManager] fileExistsAtPath:gate]) {
                    record([[NSString stringWithFormat:@"%s-after", name] UTF8String]);
                    if (!strcmp(name, "pane")) accessProbe("after");
                    break;
                }
                usleep(100000);
            }
            sleep(120); return 0;
        }
        if (!strcmp(mode, "daemon")) {
            pid_t pid = fork(); if (pid < 0) return 1; if (pid) return 0;
            if (setsid() < 0) return 1;
            pid = fork(); if (pid < 0) return 1; if (pid) _exit(0);
            execl(executable, executable, "leaf", directory, tmux, name, NULL); return 1;
        }
        if (!strcmp(mode, "open")) {
            char *args[] = {"/usr/bin/open", "-n", "-a", argv[5], "--args", "gui",
                (char *)directory, (char *)tmux, "owner", argc > 6 ? argv[6] : argv[0], NULL};
            spawn(args, 0, YES); record("launcher"); sleep(600); return 0;
        }
        if (!strcmp(mode, "gui")) {
            [NSApplication sharedApplication];
            [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
            [NSApp finishLaunching];
        }
        if (argc > 5) executable = argv[5]; // Separate signed tool, outside the app.
        record("owner");
        char *plain[] = {(char *)executable, "leaf", (char *)directory, (char *)tmux, "plain", NULL};
        spawn(plain, 0, NO);
        char *group[] = {(char *)executable, "leaf", (char *)directory, (char *)tmux, "pgroup", NULL};
        spawn(group, POSIX_SPAWN_SETPGROUP, NO);
        char *daemon[] = {(char *)executable, "daemon", (char *)directory, (char *)tmux, "daemon", NULL};
        spawn(daemon, 0, YES);
        NSTask *task = [[NSTask alloc] init];
        task.executableURL = [NSURL fileURLWithPath:@(executable)];
        task.arguments = @[@"leaf", @(directory), @(tmux), @"foundation"];
        if (![task launchAndReturnError:NULL]) return 1;
        NSString *socket = [NSString stringWithFormat:@"%s/tmux.sock", directory];
        char *terminal[] = {(char *)tmux, "-S", (char *)socket.UTF8String, "-f", "/dev/null",
            "start-server", ";", "set-option", "-g", "exit-empty", "off", ";",
            "new-session", "-d", "-s", "probe", (char *)executable, "leaf",
            (char *)directory, (char *)tmux, "pane", NULL};
        spawn(terminal, 0, YES);
        if (!strcmp(mode, "gui")) [NSApp run]; else sleep(600);
    }
}
