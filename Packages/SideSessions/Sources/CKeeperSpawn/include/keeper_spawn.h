#ifndef KEEPER_SPAWN_H
#define KEEPER_SPAWN_H

#include <sys/types.h>

/// Starts `path` with `argv` and `envp` on a new PTY of `cols` x `rows`, in `directory`, as the
/// leader of its own session with the PTY as its controlling terminal (forkpty). Returns the
/// child's pid and stores the PTY master in `*master`, or returns -1 with errno set. Every
/// other descriptor is closed in the child. The child does only async-signal-safe work.
pid_t keeper_spawn(const char *path, char *const argv[], char *const envp[], const char *directory,
                   unsigned short cols, unsigned short rows, int *master);

#endif
