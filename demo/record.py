#!/usr/bin/env python3
"""Record the kip.nvim demo: run real Neovim in a pty, press the keys, save the session.

    python3 demo/record.py code session.json
    python3 demo/record.py prose session.json

Standard library only. Render the result with demo/render.py.
"""
import base64
import fcntl
import json
import os
import pty
import random
import struct
import subprocess
import sys
import termios
import threading
import time

SCENARIOS = {"code": ("orders.py", 22), "prose": ("notes.md", 24)}
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOCK = os.path.expanduser("~/.cache/kip-demo.sock")

scenario = sys.argv[1] if len(sys.argv) > 1 else "code"
out = sys.argv[2] if len(sys.argv) > 2 else "session.json"
FILE, ROWS = SCENARIOS[scenario]
COLS = 84
os.makedirs(os.path.dirname(SOCK), exist_ok=True)
if os.path.exists(SOCK):
    os.remove(SOCK)

pid, fd = pty.fork()
if pid == 0:
    os.chdir(os.path.join(ROOT, "demo"))
    env = dict(os.environ, TERM="xterm-256color", COLORTERM="truecolor")
    os.execvpe("nvim", ["nvim", "--clean", "-u", "init.lua", "--listen", SOCK, FILE], env)

fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))

t0 = time.time()
output, captions, waits = [], [], []


def now():
    return round(time.time() - t0, 4)


def reader():
    while True:
        try:
            data = os.read(fd, 65536)
        except OSError:
            return
        if not data:
            return
        output.append([now(), base64.b64encode(data).decode()])


threading.Thread(target=reader, daemon=True).start()


def caption(keys, note):
    captions.append({"t": now(), "keys": list(keys), "note": note})


def send(s):
    os.write(fd, s.encode())


def press(pairs, note, gap=0.32):
    """pairs: [(bytes_to_send, keycap_label)], shown one by one."""
    shown = []
    for raw, label in pairs:
        send(raw)
        shown.append(label)
        caption(shown, note)
        time.sleep(gap)


def type_text(text, keys, note):
    caption(keys, note)
    for ch in text:
        send(ch)
        time.sleep(random.uniform(0.035, 0.085))


def buffer_text():
    r = subprocess.run(
        ["nvim", "--server", SOCK, "--remote-expr", "join(getbufline(1, 1, '$'), \"\\n\")"],
        capture_output=True,
        text=True,
    )
    return r.stdout


def wait_edit(before, keys, note, timeout=90):
    caption(keys, note)
    start = now()
    deadline = time.time() + timeout
    while time.time() < deadline:
        if buffer_text() != before:
            waits.append([start, now()])
            return
        time.sleep(0.05)
    raise SystemExit("timed out waiting for the model")


SPACE_K = [(" ", "space"), ("k", "k")]
URL = "github.com/kulichevskiy/kip.nvim"


def prompt_and_apply(text, keys):
    time.sleep(0.9)
    type_text(text, keys, "say what you want")
    time.sleep(0.6)
    before = buffer_text()
    press([("\r", "⏎")], "apply")
    wait_edit(before, ["⏎"], "waiting for the model (wait shortened)")
    caption([], "rewritten in place")
    time.sleep(2.4)


def search(word, note):
    press([("/", "/")], note, gap=0.2)
    type_text(word, ["/", word], note)
    press([("\r", "⏎")], note)
    caption(["/", word, "⏎"], note)
    time.sleep(0.8)


def dot_repeat():
    before = buffer_text()
    press([(".", ".")], "repeat: same instruction, no prompt")
    wait_edit(before, ["."], "repeat: same instruction, no prompt (wait shortened)")
    caption(["."], "repeat: same instruction, no prompt")
    time.sleep(2.6)


def code():
    press(SPACE_K + [("i", "i"), ("p", "p")], "edit inner paragraph")
    prompt_and_apply("add type hints and a docstring", ["space", "k", "i", "p"])
    search("average", "jump to the next function")
    dot_repeat()
    search("hey", "any text object works")
    press(SPACE_K + [("i", "i"), ("(", "(")], "edit inside the parens")
    prompt_and_apply("f-string, and fix the spelling", ["space", "k", "i", "("])
    press([("u", "u")], "one edit, one undo step")
    time.sleep(1.6)
    press([("\x12", "ctrl-r")], "and redo")
    time.sleep(2.0)


def prose():
    press([("j", "j"), ("j", "j")], "works on prose too", gap=0.25)
    time.sleep(0.5)
    press(SPACE_K + [("i", "i"), ("p", "p")], "edit inner paragraph")
    prompt_and_apply("cut this in half, keep the facts", ["space", "k", "i", "p"])
    press([("}", "}"), ("j", "j")], "next paragraph")
    time.sleep(0.6)
    dot_repeat()
    search("synerg", "sentences are text objects too")
    press(SPACE_K + [("i", "i"), ("s", "s")], "edit inner sentence")
    prompt_and_apply("say it like a human", ["space", "k", "i", "s"])
    search("The sync", "or just select something")
    press([("V", "V"), ("j", "j"), ("j", "j")], "or just select something", gap=0.3)
    time.sleep(0.4)
    press(SPACE_K, "edit the selection")
    prompt_and_apply("start each bullet with a verb", ["V", "j", "j", "space", "k"])


time.sleep(1.5)  # let nvim start and paint
start = now()
caption([], "kip.nvim: AI edits as a Vim operator")
time.sleep(2.0)
{"code": code, "prose": prose}[scenario]()
caption([], URL)
time.sleep(3.0)
end = now()

send("\x1b:qa!\r")
time.sleep(0.3)

with open(out, "w") as f:
    json.dump({"cols": COLS, "rows": ROWS, "title": "nvim " + FILE, "start": start, "end": end, "output": output, "captions": captions, "waits": waits}, f)
print(f"saved {out}: {end:.1f}s, waits {[round(b - a, 1) for a, b in waits]}")
