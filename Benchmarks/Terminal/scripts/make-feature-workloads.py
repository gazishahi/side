"""The RFC's rule 4 workloads (docs/SIDE_RFC_TERMINAL_ENGINE.md): output that exercises the new
renderer's features, deterministic (a fixed seed), 64 MB each by default.

  ligatures.bin   syntax-highlighted code, as bat or an editor's preview prints it, dense with
                  ligature sequences (-> => != === <= >= :: |> <$> && || ...): shaping and
                  ligatures, in a ligature font (Fira Code).
  boxes.bin       a dashboard redrawn in place, as btop or lazygit draw: box drawing (light, heavy,
                  double, rounded), block elements and shades, braille graphs, eighth-block meters.
  underlines.bin  scrolling text marked as editors and LSPs mark it: underline styles (single,
                  double, curly, dotted, dashed) with their own colors (SGR 58), strikethrough,
                  overline.

Usage: python3 -I make-feature-workloads.py <out dir> [MB]
"""
import random
import sys

out = sys.argv[1]
size = int(sys.argv[2]) * 1024 * 1024 if len(sys.argv) > 2 else 64 * 1024 * 1024
ESC = '\x1b['


def write(name, make):
    rng = random.Random(4)
    parts, total = [], 0
    while total < size:
        chunk = make(rng).encode()
        parts.append(chunk)
        total += len(chunk)
    data = b''.join(parts)[:size]
    open(f'{out}/{name}', 'wb').write(data)
    print(f'{name}: {len(data)} bytes')


# Ligatures: code lines, colored per token as a highlighter prints them.
WORDS = ['value', 'next', 'state', 'item', 'count', 'buffer', 'index', 'result', 'node', 'left', 'right', 'map', 'acc', 'xs']
TYPES = ['Option', 'Result', 'Vec', 'Map', 'String', 'Int', 'Maybe', 'Either']
KEYWORDS = ['if', 'let', 'fn', 'return', 'match', 'else', 'guard', 'where', 'for', 'while']
OPERATORS = ['->', '=>', '!=', '==', '===', '!==', '<=', '>=', '::', '|>', '<|', '<$>', '>>=', '=<<', '&&', '||',
             '++', '--', '..', '...', '..=', '<-', '<<', '>>', '**', '//', '/*', '*/', '??', '?.', '<>', '</', '/>',
             '<!--', '-->', ':=', '=~', '!~', '#{', '#[', '__', 'www', '0xFF', '|||', ';;', '~>', '<~', '<=>']
COLORS = {'kw': '35', 'type': '33', 'op': '36', 'num': '31', 'str': '32', 'comment': '90'}


def code_line(rng):
    indent = ' ' * (4 * rng.randrange(0, 5))
    tokens = []
    length = len(indent)
    while length < rng.randrange(40, 150):
        kind = rng.random()
        if kind < 0.15:
            t, c = rng.choice(KEYWORDS), 'kw'
        elif kind < 0.25:
            t, c = rng.choice(TYPES), 'type'
        elif kind < 0.6:
            t, c = rng.choice(OPERATORS), 'op'
        elif kind < 0.65:
            t, c = str(rng.randrange(1000)), 'num'
        elif kind < 0.7:
            t, c = '"' + rng.choice(WORDS) + '"', 'str'
        else:
            t, c = rng.choice(WORDS), None
        tokens.append(f'{ESC}{COLORS[c]}m{t}{ESC}0m' if c else t)
        length += len(t) + 1
    line = indent + ' '.join(tokens)
    if rng.random() < 0.1:
        line += f' {ESC}90m// ' + ' '.join(rng.choice(OPERATORS + WORDS) for _ in range(6)) + f'{ESC}0m'
    return line + '\r\n'


def code(rng):
    return ''.join(code_line(rng) for _ in range(200))


# Boxes: a 200×60 dashboard of panels, redrawn in place every frame.
BORDERS = [('┌', '┐', '└', '┘', '─', '│'), ('┏', '┓', '┗', '┛', '━', '┃'),
           ('╔', '╗', '╚', '╝', '═', '║'), ('╭', '╮', '╰', '╯', '─', '│')]
EIGHTHS = ' ▏▎▍▌▋▊▉█'
SHADES = '░▒▓█▀▄▌▐▖▗▘▙▚▛▜▝▞▟'
BRAILLE = [chr(0x2800 + i) for i in range(256)]


def panel(rng, top, left, height, width, color):
    b = BORDERS[rng.randrange(4)]
    s = [f'{ESC}{top};{left}H{ESC}38;5;{color}m{b[0]}{b[4] * (width - 2)}{b[1]}']
    for row in range(1, height - 1):
        s.append(f'{ESC}{top + row};{left}H{b[5]}')
        inner = width - 2
        kind = row % 3
        if kind == 0:  # a meter
            fill = rng.random() * inner
            whole = int(fill)
            part = EIGHTHS[int((fill - whole) * 8)] if whole < inner else ''
            bar = '█' * whole + part
            s.append(f'{ESC}38;5;{rng.randrange(17, 231)}m{bar}{" " * (inner - len(bar))}{ESC}38;5;{color}m')
        elif kind == 1:  # a braille graph
            s.append(f'{ESC}38;5;{rng.randrange(17, 231)}m' + ''.join(rng.choice(BRAILLE) for _ in range(inner)) + f'{ESC}38;5;{color}m')
        else:  # shades and blocks
            s.append(''.join(rng.choice(SHADES) for _ in range(inner)))
        s.append(b[5])
    s.append(f'{ESC}{top + height - 1};{left}H{b[2]}{b[4] * (width - 2)}{b[3]}{ESC}0m')
    return ''.join(s)


def dashboard(rng):
    s = [f'{ESC}?25l']
    for top in (1, 21, 41):
        for left in (1, 51, 101, 151):
            s.append(panel(rng, top, left, 20, 50, rng.randrange(17, 231)))
    return ''.join(s)


# Underlines: scrolling text marked as diagnostics and markup mark it.
MARKS = [('4', ''), ('4:2', ''), ('4:3', '58;2;230;80;80'), ('4:3', '58;2;230;190;60'), ('4:4', '58;5;39'),
         ('4:5', '58;5;114'), ('9', ''), ('53', ''), ('4:3;1', '58;2;230;80;80'), ('4:1;3', '58;5;208')]


def marked_line(rng):
    words = []
    length = 0
    while length < rng.randrange(60, 190):
        w = rng.choice(WORDS + TYPES + KEYWORDS)
        if rng.random() < 0.3:
            style, color = rng.choice(MARKS)
            w = f'{ESC}{style}{";" + color if color else ""}m{w}{ESC}0m'
        words.append(w)
        length += 8
    return ' '.join(words) + '\r\n'


def marked(rng):
    return ''.join(marked_line(rng) for _ in range(200))


write('ligatures.bin', code)
write('boxes.bin', dashboard)
write('underlines.bin', marked)
