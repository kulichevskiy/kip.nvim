#!/usr/bin/env python3
"""Render a session recorded by demo/record.py into a video.

    uv run --with pyte --with pillow --with fonttools demo/render.py session.json out.mp4

Replays the terminal output through a terminal emulator (pyte), draws each frame
with Pillow and pipes raw frames to ffmpeg. Long waits for the model are cut short.
"""
import base64
import codecs
import json
import re
import subprocess
import sys

import pyte
from fontTools.ttLib import TTFont
from PIL import Image, ImageDraw, ImageFont

FPS = 30
SIZE = 26  # font size, px
KEEP_HEAD, KEEP_TAIL = 1.1, 0.5  # seconds of each model wait that survive the cut

SF = "/System/Applications/Utilities/Terminal.app/Contents/Resources/Fonts/SF-Mono-%s.otf"
FALLBACKS = [
    "/System/Library/Fonts/Menlo.ttc",
    "/System/Library/Fonts/Apple Symbols.ttf",
    "/System/Library/Fonts/Apple Braille.ttf",
    "/Library/Fonts/Arial Unicode.ttf",
]
BG, FG = "#1a1b26", "#c0caf5"
CANVAS, CHROME, MUTED = "#0d0e14", "#16161e", "#737aa2"
NAMED = {
    "black": "#15161e", "red": "#f7768e", "green": "#9ece6a", "brown": "#e0af68",
    "blue": "#7aa2f7", "magenta": "#bb9af7", "cyan": "#7dcfff", "white": "#a9b1d6",
}

src, dst = sys.argv[1], sys.argv[2]
S = json.load(open(src))
COLS, ROWS = S["cols"], S["rows"]


def load(path, size=SIZE):
    try:
        return ImageFont.truetype(path, size)
    except OSError:
        return None


fonts = {
    (False, False): load(SF % "Regular"), (True, False): load(SF % "Semibold"),
    (False, True): load(SF % "RegularItalic"), (True, True): load(SF % "SemiboldItalic"),
}
if not fonts[(False, False)]:
    fonts = {k: load(FALLBACKS[0]) for k in fonts}
main_cmap = set(TTFont(SF % "Regular").getBestCmap()) if load(SF % "Regular") else set()
fallbacks = []
for p in FALLBACKS:
    f = load(p)
    if f:
        fallbacks.append((set(TTFont(p, fontNumber=0).getBestCmap()), f))
ui_font = load(SF % "Medium", 24) or fonts[(False, False)]
ui_small = load(SF % "Regular", 20) or fonts[(False, False)]

CW = round(fonts[(False, False)].getlength("M"))
CH = round(SIZE * 1.42)
PAD, BAR, MARGIN, STRIP = 22, 46, 44, 96
TW, TH = COLS * CW + 2 * PAD, ROWS * CH + 2 * PAD + BAR
W, H = TW + 2 * MARGIN, TH + MARGIN + STRIP
W += W % 2
H += H % 2
X0, Y0 = MARGIN + PAD, MARGIN + BAR + PAD


def font_for(ch, bold, italic):
    if ord(ch) in main_cmap or not main_cmap:
        return fonts[(bold, italic)]
    for cmap, f in fallbacks:
        if ord(ch) in cmap:
            return f
    return fonts[(bold, italic)]


def color(c, default):
    if c == "default":
        return default
    if c in NAMED:
        return NAMED[c]
    if c.startswith("bright") and c[6:] in NAMED:
        return NAMED[c[6:]]
    return "#" + c if re.fullmatch(r"[0-9a-fA-F]{6}", c) else default


# --- time warp: cut the middle out of long model waits ---------------------
cuts = []
for a, b in S["waits"]:
    if b - a > KEEP_HEAD + KEEP_TAIL:
        cuts.append((a + KEEP_HEAD, b - KEEP_TAIL))


def warp(t):
    shift = 0.0
    for a, b in cuts:
        if t >= b:
            shift += b - a
        elif t > a:
            shift += t - a
    return t - shift


# --- terminal replay --------------------------------------------------------
screen = pyte.Screen(COLS, ROWS)
stream = pyte.Stream(screen)
decoder = codecs.getincrementaldecoder("utf-8")("replace")
cursor_bar = False
carry = ""

DROP = re.compile(
    r"\x1bP.*?\x1b\\"  # DCS
    r"|\x1b_.*?\x1b\\"  # APC
    r"|\x1b\].*?(?:\x07|\x1b\\)"  # OSC
    r"|\x1b\[[<=>][0-9;:]*[@-~]"  # private CSI
    r"|\x1b\[\?(?!25[hl])[0-9;]*[@-~$]*[a-zA-Z]"  # DEC modes except cursor visibility
    r"|\x1b\[[0-9;]*:[0-9;:]*m"  # SGR with sub-parameters
    r"|\x1b\[[0-9;]*[tu]",  # window ops, kitty keyboard
    re.S,
)
DECSCUSR = re.compile(r"\x1b\[(\d*) q")
INCOMPLETE = re.compile(r"\x1b(?:\[[0-9;:?<=>! ]*|[P_\]][^\x07\x1b]*\x1b?)?$", re.S)


def feed(data):
    global carry, cursor_bar
    text = carry + decoder.decode(data)
    m = INCOMPLETE.search(text)
    if m and len(text) - m.start() < 4096:
        text, carry = text[: m.start()], text[m.start():]
    else:
        carry = ""
    text = DROP.sub("", text)
    for m in DECSCUSR.finditer(text):
        cursor_bar = m.group(1) in ("5", "6")
    stream.feed(DECSCUSR.sub("", text))


# --- drawing ----------------------------------------------------------------
BOX = {"─": "lr", "│": "ud", "╭": "rd", "╮": "ld", "╰": "ru", "╯": "lu"}


def draw_box(d, ch, x, y, fg):
    cx, cy = x + CW // 2, y + CH // 2
    ends = {"l": (x, cy), "r": (x + CW, cy), "u": (cx, y), "d": (cx, y + CH)}
    a, b = BOX[ch]
    if ch in "─│":
        d.line([ends[a], ends[b]], fill=fg, width=2)
    else:
        d.line([ends[a], (cx, cy), ends[b]], fill=fg, width=2, joint="curve")


def keycap(d, x, y, label):
    w = max(46, int(ui_font.getlength(label)) + 28)
    d.rounded_rectangle([x, y, x + w, y + 46], 10, fill="#24283b", outline="#414868", width=2)
    d.text((x + w / 2, y + 22), label, font=ui_font, fill="#c0caf5", anchor="mm")
    return w + 10


def render(cap):
    img = Image.new("RGB", (W, H), CANVAS)
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([MARGIN, MARGIN, MARGIN + TW, MARGIN + TH], 16, fill=BG, outline="#2a2e42", width=2)
    d.rounded_rectangle([MARGIN + 1, MARGIN + 1, MARGIN + TW - 1, MARGIN + BAR], 15, fill=CHROME)
    d.rectangle([MARGIN + 2, MARGIN + BAR - 14, MARGIN + TW - 2, MARGIN + BAR], fill=CHROME)
    for i, c in enumerate(("#f7768e", "#e0af68", "#9ece6a")):
        d.ellipse([MARGIN + 20 + i * 26, MARGIN + 16, MARGIN + 34 + i * 26, MARGIN + 30], fill=c)
    d.text((MARGIN + TW / 2, MARGIN + BAR / 2), S.get("title", "nvim"), font=ui_small, fill=MUTED, anchor="mm")

    cur = screen.cursor
    for row in range(ROWS):
        line = screen.buffer[row]
        y = Y0 + row * CH
        for col in range(COLS):
            cell = line[col]
            fg, bg = color(cell.fg, FG), color(cell.bg, BG)
            if cell.reverse:
                fg, bg = bg, fg
            x = X0 + col * CW
            at_cursor = not cur.hidden and row == cur.y and col == cur.x
            if at_cursor and not cursor_bar:
                fg, bg = BG, FG
            if bg != BG:
                d.rectangle([x, y, x + CW - 1, y + CH - 1], fill=bg)
            ch = cell.data
            if ch and ch != " ":
                if ch in BOX:
                    draw_box(d, ch, x, y, fg)
                else:
                    f = font_for(ch, cell.bold, cell.italics)
                    d.text((x + CW / 2, y + CH / 2), ch, font=f, fill=fg, anchor="mm")
            if cell.underscore:
                d.line([x, y + CH - 4, x + CW, y + CH - 4], fill=fg, width=2)
            if at_cursor and cursor_bar:
                d.rectangle([x, y + 3, x + 2, y + CH - 4], fill=FG)

    if cap:
        y = MARGIN + TH + 26
        x = MARGIN + 8
        for k in cap["keys"]:
            x += keycap(d, x, y, k)
        if cap["keys"]:
            x += 10
        d.text((x, y + 22), cap["note"], font=ui_font, fill=MUTED, anchor="lm")
    return img.tobytes()


def signature(cap):
    cur = screen.cursor
    cells = tuple(tuple(screen.buffer[r][c] for c in range(COLS)) for r in range(ROWS))
    return hash((cells, cur.x, cur.y, cur.hidden, cursor_bar, json.dumps(cap, sort_keys=True)))


events = [(warp(t), base64.b64decode(b)) for t, b in S["output"]]
caps = [(warp(c["t"]), c) for c in S["captions"]]
total = warp(S["end"])

ff = subprocess.Popen(
    ["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}",
     "-r", str(FPS), "-i", "-", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "18",
     "-movflags", "+faststart", dst],
    stdin=subprocess.PIPE,
)
ei = ci = 0
cap = None
last_sig, last_frame, unique = None, None, 0
first = warp(S.get("start", 0.0))
n = int((total - first) * FPS)
for i in range(n):
    t = first + i / FPS
    while ei < len(events) and events[ei][0] <= t:
        feed(events[ei][1])
        ei += 1
    while ci < len(caps) and caps[ci][0] <= t:
        cap = caps[ci][1]
        ci += 1
    shown = {"keys": cap["keys"], "note": cap["note"]} if cap else None
    sig = signature(shown)
    if sig != last_sig:
        last_frame, last_sig = render(shown), sig
        unique += 1
    ff.stdin.write(last_frame)
ff.stdin.close()
ff.wait()
print(f"{dst}: {W}x{H}, {n / FPS:.1f}s, {n} frames ({unique} unique)")
