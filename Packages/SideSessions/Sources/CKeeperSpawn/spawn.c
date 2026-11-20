#include "keeper_spawn.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

pid_t keeper_spawn(const char *path, char *const argv[], char *const envp[], const char *directory,
                   unsigned short cols, unsigned short rows, int *master) {
    struct winsize size = {.ws_row = rows, .ws_col = cols};
    int highest = (int)sysconf(_SC_OPEN_MAX);
    pid_t pid = forkpty(master, NULL, NULL, &size);
    if (pid != 0) {
        if (pid > 0) fcntl(*master, F_SETFD, FD_CLOEXEC);
        return pid;
    }
    // The child: a session leader whose controlling terminal is the PTY (forkpty's login_tty).
    for (int fd = 3; fd < highest && fd < 4096; fd++) close(fd);
    // Signals back to their defaults: the keeper ignores SIGPIPE and handles SIGHUP itself.
    struct sigaction dfl = {.sa_handler = SIG_DFL};
    for (int sig = 1; sig < NSIG; sig++) sigaction(sig, &dfl, NULL);
    sigset_t none;
    sigemptyset(&none);
    sigprocmask(SIG_SETMASK, &none, NULL);
    // Input is UTF-8 (IUTF8), as Terminal and Ghostty set it: in canonical mode (a `read`
    // prompt, `cat` waiting) a backspace then erases a whole é or 日, not one byte of it,
    // which left broken bytes behind (side-c0, 2026-11-20).
    struct termios mode;
    if (tcgetattr(STDIN_FILENO, &mode) == 0) {
        mode.c_iflag |= IUTF8;
        tcsetattr(STDIN_FILENO, TCSANOW, &mode);
    }
    if (directory && directory[0] && chdir(directory) != 0) chdir("/");
    execve(path, argv, envp);
    _exit(127);
}
