// A stand-in for Claude Code at the terminal level, for driving Side's Terminal stage in tests
// without anyone's Claude account. Built as a binary named `claude`, so the process is called
// what the real one is.
//
// What it does, as Claude Code does:
// - asks the terminal what it is (DA1, XTVERSION) at startup, so the replies arrive on its input
//   the way they do for the real one;
// - titles the terminal "✳ Claude Code" while waiting, and a braille spinner frame in front of
//   it while working;
// - reads a message in raw mode; Enter starts a turn of FAKE_CLAUDE_TURN seconds (default 4);
// - rings the bell when a turn ends;
// - ^C or ^D quits.
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

static struct termios original;

static void restore(void) {
    tcsetattr(STDIN_FILENO, TCSANOW, &original);
    // Back to the shell's own title.
    fputs("\033]0;\007", stdout);
    fflush(stdout);
}

static void title(const char *text) {
    printf("\033]0;%s\007", text);
    fflush(stdout);
}

static void prompt(void) {
    fputs("\r\n> ", stdout);
    fflush(stdout);
}

// Reads whatever is waiting, up to `wait_ms`. Returns the bytes read.
static ssize_t read_some(char *buffer, size_t size, int wait_ms) {
    fd_set set;
    FD_ZERO(&set);
    FD_SET(STDIN_FILENO, &set);
    struct timeval timeout = { wait_ms / 1000, (wait_ms % 1000) * 1000 };
    if (select(STDIN_FILENO + 1, &set, NULL, NULL, &timeout) <= 0) return 0;
    return read(STDIN_FILENO, buffer, size);
}

static void turn(double seconds) {
    static const char *frames[] = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
    struct timespec start, now;
    clock_gettime(CLOCK_MONOTONIC, &start);
    int frame = 0;
    fputs("\r\n", stdout);
    for (;;) {
        clock_gettime(CLOCK_MONOTONIC, &now);
        double elapsed = (now.tv_sec - start.tv_sec) + (now.tv_nsec - start.tv_nsec) / 1e9;
        if (elapsed >= seconds) break;
        char text[64];
        snprintf(text, sizeof text, "%s Claude Code", frames[frame++ % 10]);
        title(text);
        printf("\rworking %.1fs", elapsed);
        fflush(stdout);
        char discard[256];
        read_some(discard, sizeof discard, 100);
    }
    printf("\rdone.         ");
    title("✳ Claude Code");
    fputs("\a", stdout);
    prompt();
}

int main(void) {
    const char *turn_env = getenv("FAKE_CLAUDE_TURN");
    double seconds = turn_env ? atof(turn_env) : 4;
    tcgetattr(STDIN_FILENO, &original);
    atexit(restore);
    struct termios raw = original;
    cfmakeraw(&raw);
    tcsetattr(STDIN_FILENO, TCSANOW, &raw);

    // What Claude Code asks the terminal at startup.
    fputs("\033[c\033[>0q", stdout);
    title("✳ Claude Code");
    fputs("fake claude: type a message and press Enter", stdout);
    prompt();

    char buffer[256];
    // Inside an escape sequence (the terminal's replies, arrow keys): not part of the message.
    int escape = 0;
    for (;;) {
        ssize_t count = read_some(buffer, sizeof buffer, 1000);
        for (ssize_t i = 0; i < count; i++) {
            char c = buffer[i];
            if (escape) {
                // A string (DCS, OSC) runs to BEL or ST; anything else to its final letter.
                if (escape == 1) { escape = (c == 'P' || c == ']') ? 3 : 2; if (c == 'O') escape = 4; continue; }
                if (escape == 3) { if (c == 7 || c == '\\') escape = 0; continue; }
                if (escape == 4 || (c >= '@' && c <= '~')) escape = 0;
                continue;
            }
            if (c == 27) { escape = 1; continue; }
            if (c == 3 || c == 4) return 0;
            if (c == '\r' || c == '\n') turn(seconds);
            else if (c >= 32 && c < 127) { putchar(c); fflush(stdout); }
        }
    }
}
