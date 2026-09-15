#pragma once
#include <sys/types.h>
int chauffeur_unix_listen(const char *path);
int chauffeur_unix_connect(const char *path);
int chauffeur_peer_is_current_user(int fd);
int chauffeur_lock(const char *path);
pid_t chauffeur_spawn_pty(const char *executable, char *const argv[], char *const envp[], const char *cwd, int *master, unsigned short cols, unsigned short rows);
int chauffeur_resize(int fd, unsigned short cols, unsigned short rows);
