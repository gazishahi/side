// A PTY read-path experiment: cat a file through a PTY into libghostty-vt, timed, with either
// Ghostty's own reader (Exec.zig at c7f68a7: gather + parse threads, a ring of 4×64 KiB,
// non-blocking reads, 16 spin retries and a 1 ms poll once a stream is saturated, 3 ms per
// batch) or the harness's (one thread: blocking 64 KiB read, then parse).
//   ptyread <file> <ghostty|serial> [parse|noparse] [initiated|interactive] [iutf8|noiutf8]
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#include <util.h>
#include <ghostty/vt.h>

static int master_fd;
static int do_parse = 1;
static qos_class_t qos = QOS_CLASS_USER_INITIATED;
static GhosttyTerminal term;
static size_t parsed = 0;

static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC_RAW, &t); return t.tv_sec + t.tv_nsec / 1e9; }
static void consume(const uint8_t *p, size_t n) { if (do_parse) ghostty_terminal_vt_write(term, p, n); parsed += n; }

// ---- Ghostty's pipeline ----
enum { COUNT = 4, CAP = 64 * 1024, THRESHOLD = 1024, SPIN = 16 };
static struct {
    pthread_mutex_t m; pthread_cond_t ready, freed;
    size_t lens[COUNT]; int head, tail, count, bridging, done;
    int idle_r, idle_w;
    uint8_t bufs[COUNT][CAP];
} P = { PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER, PTHREAD_COND_INITIALIZER };

static void *gather(void *arg) {
    (void)arg;
    pthread_set_qos_class_self_np(qos, 0);
    struct pollfd fds[2] = { { master_fd, POLLIN, 0 }, { P.idle_r, POLLIN, 0 } };
    for (;;) {
        pthread_mutex_lock(&P.m);
        while (P.count == COUNT) pthread_cond_wait(&P.freed, &P.m);
        uint8_t *buf = P.bufs[P.head];
        pthread_mutex_unlock(&P.m);
        size_t total = 0; int spins = 0, fatal = 0, eof = 0; double bridge_start = 0;
        while (total < CAP) {
            ssize_t n = read(master_fd, buf + total, CAP - total);
            if (n < 0 && errno == EAGAIN) {
                if (total < THRESHOLD) break;
                if (spins < SPIN) { spins++; continue; }
                double t = now();
                if (bridge_start) { if (t - bridge_start >= 0.003) break; } else bridge_start = t;
                pthread_mutex_lock(&P.m);
                if (P.count == 0) { pthread_mutex_unlock(&P.m); break; }
                P.bridging = 1;
                pthread_mutex_unlock(&P.m);
                int r = poll(fds, 2, 1);
                pthread_mutex_lock(&P.m); P.bridging = 0; pthread_mutex_unlock(&P.m);
                if (r <= 0) break;
                if (fds[1].revents & POLLIN) { char trash[16]; while (read(P.idle_r, trash, sizeof trash) == sizeof trash) {} break; }
                if (!(fds[0].revents & POLLIN)) break;
                continue;
            }
            if (n < 0 && errno == EINTR) continue;
            if (n < 0) { fatal = 1; break; }   // EIO: the child is gone
            if (n == 0) { eof = 1; break; }  // macOS: the child is gone
            total += n; spins = 0;
        }
        if (total > 0) {
            pthread_mutex_lock(&P.m);
            P.lens[P.head] = total; P.head = (P.head + 1) % COUNT; P.count++;
            pthread_mutex_unlock(&P.m);
            pthread_cond_signal(&P.ready);
        }
        if (fatal || eof) break;
        if (total == CAP) continue;
        struct pollfd one = { master_fd, POLLIN, 0 };
        poll(&one, 1, -1);
        if ((one.revents & (POLLHUP | POLLERR)) && !(one.revents & POLLIN)) break;
    }
    pthread_mutex_lock(&P.m); P.done = 1; pthread_mutex_unlock(&P.m);
    pthread_cond_signal(&P.ready);
    return NULL;
}

static void run_ghostty(void) {
    fcntl(master_fd, F_SETFL, fcntl(master_fd, F_GETFL) | O_NONBLOCK);
    int fds[2]; pipe(fds); P.idle_r = fds[0]; P.idle_w = fds[1];
    fcntl(P.idle_r, F_SETFL, O_NONBLOCK); fcntl(P.idle_w, F_SETFL, O_NONBLOCK);
    pthread_t g; pthread_create(&g, NULL, gather, NULL);
    for (;;) {
        pthread_mutex_lock(&P.m);
        while (P.count == 0) { if (P.done) { pthread_mutex_unlock(&P.m); pthread_join(g, NULL); return; } pthread_cond_wait(&P.ready, &P.m); }
        int slot = P.tail;
        pthread_mutex_unlock(&P.m);
        consume(P.bufs[slot], P.lens[slot]);
        pthread_mutex_lock(&P.m);
        P.tail = (P.tail + 1) % COUNT; P.count--;
        int wake = P.count == 0 && P.bridging;
        pthread_mutex_unlock(&P.m);
        pthread_cond_signal(&P.freed);
        if (wake) write(P.idle_w, "i", 1);
    }
}

// ---- The harness's reader ----
static void run_serial(void) {
    static uint8_t buf[64 * 1024];
    for (;;) {
        ssize_t n = read(master_fd, buf, sizeof buf);
        if (n > 0) { consume(buf, n); continue; }
        if (n < 0 && errno == EINTR) continue;
        break;
    }
}

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: ptyread <file> <ghostty|serial> [parse|noparse] [initiated|interactive] [iutf8|noiutf8]\n"); return 2; }
    const char *file = argv[1]; int ghostty = strcmp(argv[2], "ghostty") == 0;
    if (argc > 3 && strcmp(argv[3], "noparse") == 0) do_parse = 0;
    if (argc > 4 && strcmp(argv[4], "interactive") == 0) qos = QOS_CLASS_USER_INTERACTIVE;
    int iutf8 = !(argc > 5 && strcmp(argv[5], "noiutf8") == 0);
    struct stat st; stat(file, &st);

    if (ghostty_terminal_new(NULL, &term, 200, 60) != GHOSTTY_SUCCESS) return 1;
    size_t lines = 10000; ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &lines);
    ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, NULL);

    // As Ghostty's pty.zig: openpty, IUTF8 on the master's termios.
    struct winsize ws = { 60, 200, 0, 0 };
    int slave;
    if (openpty(&master_fd, &slave, NULL, NULL, &ws) < 0) { perror("openpty"); return 1; }
    if (iutf8) { struct termios a; tcgetattr(master_fd, &a); a.c_iflag |= IUTF8; tcsetattr(master_fd, TCSANOW, &a); }
    int go[2]; pipe(go);
    pid_t pid = fork();
    if (pid == 0) {
        setsid(); ioctl(slave, TIOCSCTTY, 0);
        dup2(slave, 0); dup2(slave, 1); dup2(slave, 2);
        close(master_fd); close(slave); close(go[1]);
        char c; read(go[0], &c, 1);  // start together with the clock
        execl("/bin/cat", "cat", file, (char *)NULL);
        _exit(127);
    }
    close(slave); close(go[0]);
    pthread_set_qos_class_self_np(qos, 0);
    struct rusage r0, r1; getrusage(RUSAGE_SELF, &r0);
    double t0 = now();
    write(go[1], "g", 1); close(go[1]);
    if (ghostty) run_ghostty(); else run_serial();
    double t = now() - t0;
    getrusage(RUSAGE_SELF, &r1);
    int status; waitpid(pid, &status, 0);
    double cpu = (r1.ru_utime.tv_sec - r0.ru_utime.tv_sec) + (r1.ru_utime.tv_usec - r0.ru_utime.tv_usec) / 1e6
               + (r1.ru_stime.tv_sec - r0.ru_stime.tv_sec) + (r1.ru_stime.tv_usec - r0.ru_stime.tv_usec) / 1e6;
    printf("%-7s %-7s %-11s %-7s %6.1f MB/s  cpu %.2f s  (%zu of %lld bytes)\n", argv[2], do_parse ? "parse" : "noparse",
           qos == QOS_CLASS_USER_INITIATED ? "initiated" : "interactive", iutf8 ? "iutf8" : "noiutf8",
           parsed / t / 1048576.0, cpu, parsed, (long long)st.st_size);
    return 0;
}
