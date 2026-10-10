#pragma once
#include <sys/types.h>
int chauffeur_unix_listen(const char *path);
int chauffeur_unix_connect(const char *path);
int chauffeur_peer_is_current_user(int fd);
int chauffeur_lock(const char *path);
pid_t chauffeur_spawn_pty(const char *executable, char *const argv[], char *const envp[], const char *cwd, int *master, unsigned short cols, unsigned short rows);
int chauffeur_resize(int fd, unsigned short cols, unsigned short rows);
/// Renames without replacing: fails with EEXIST when `to` exists (renameatx_np RENAME_EXCL on macOS, renameat2 RENAME_NOREPLACE on Linux).
int chauffeur_rename_exclusive(const char *from, const char *to);
int chauffeur_renameat_exclusive(int from_fd, const char *from, int to_fd, const char *to);
/// Starts `executable` (no PATH search) with the given standard descriptors and no others,
/// no signals blocked and default signal actions. `envp` must not be NULL. Returns the pid,
/// or -1 with errno set. The caller reaps the child.
pid_t chauffeur_spawn(const char *executable, char *const argv[], char *const envp[], const char *cwd, int stdin_fd, int stdout_fd, int stderr_fd);
/// The file's creation time. Returns -1 with errno set where the file system doesn't record one.
int chauffeur_birth_time(const char *path, long long *seconds, long *nanoseconds);
/// A pipe whose ends close on exec (atomically on Linux).
int chauffeur_pipe(int descriptors[2]);
