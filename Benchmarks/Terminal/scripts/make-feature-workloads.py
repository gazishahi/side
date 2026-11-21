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
  images.bin      a listing with image previews between its lines, as a file browser or a loop
                  of `kitten icat` prints them: kitty graphics, PNG (decoded by the terminal) and
                  raw RGB, 160x100 pixels each, shown at 20x5 cells, each a new image id, so
                  every one is decoded, stored, uploaded and drawn, then scrolled away.

Usage: python3 -I make-feature-workloads.py <out dir> [MB]
"""
import base64
import random
import struct
import sys
import zlib

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


# Images: a few distinct pictures, sent again and again under new ids.
def png(width, height, pixel):
    raw = b''.join(b'\x00' + b''.join(bytes(pixel(x, y)) for x in range(width)) for y in range(height))
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xFFFFFFFF)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(raw, 6)) + chunk(b'IEND', b''))


def picture(seed):
    rng = random.Random(seed)
    a, b, c = rng.randrange(256), rng.randrange(256), rng.randrange(256)
    return lambda x, y: ((a + x * 3) % 256, (b + y * 5) % 256, (c + x * y) % 256, 255 if (x // 8 + y // 8) % 5 else 160)


PICTURES = [picture(seed) for seed in range(8)]
PNGS = [base64.b64encode(png(160, 100, p)).decode() for p in PICTURES]
RGBS = [base64.b64encode(b''.join(bytes(p(x, y)[:3]) for y in range(100) for x in range(160))).decode() for p in PICTURES]
image_id = [0]


def kitty(control, payload):
    # Chunks of 4096 bytes of base64, as the protocol asks of large payloads.
    pieces = [payload[i:i + 4096] for i in range(0, len(payload), 4096)]
    out = ''
    for n, piece in enumerate(pieces):
        head = (control + ',' if n == 0 else '') + f'm={1 if n < len(pieces) - 1 else 0}'
        out += f'\x1b_G{head};{piece}\x1b\\'
    return out


def previews(rng):
    image_id[0] += 1
    n = rng.randrange(len(PICTURES))
    name = f'{rng.choice(WORDS)}-{image_id[0]}.{"png" if image_id[0] % 2 else "rgb"}'
    if image_id[0] % 2:
        image = kitty(f'a=T,f=100,i={image_id[0]},c=20,r=5,q=2', PNGS[n])
    else:
        image = kitty(f'a=T,f=24,s=160,v=100,i={image_id[0]},c=20,r=5,q=2', RGBS[n])
    lines = ''.join(f'{ESC}2m{rng.randrange(10**6):>8}{ESC}0m  {rng.choice(WORDS)}/{rng.choice(WORDS)}\r\n' for _ in range(rng.randrange(2, 8)))
    return f'{ESC}1m{name}{ESC}0m\r\n{image}\r\n{lines}'


write('ligatures.bin', code)
write('boxes.bin', dashboard)
write('underlines.bin', marked)
write('images.bin', previews)
