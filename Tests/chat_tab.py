#!/usr/bin/env python3
"""The Agent Chat tab: a tab that is a talk with the agent, not a page —
made from the File menu's item (stood in for by the chat verbs here), its
reach over every tab, its rules the bot's own.

Build first (`./build.sh` or `./build.sh debug`), then run
`python3 Tests/chat_tab.py`. The app is started hidden in a world of its
own (SEARCH_PROBE=chat-tests-<checkout>, see use()), driven through
./bench's socket, and quit; its settings and files are removed afterwards.
Nothing here makes, shows or brings forward a window.

What is checked:
  the tab       made, standing in the row by name, gone with its talk
  the reach     every tab listed to the model, the chat itself never among
                them; no page in front while the person talks, every act
                naming its tab
  the rules     an act held for the person's Allow, a command beyond the
                page held the same, a close always asked
"""

import hashlib
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = str(ROOT / "build" / "Search.app")
HOME = os.path.expanduser("~")
def use(name):
    """This checkout's own world for a suite: the name, then a tag made from
    the checkout's path. Two checkouts testing at once (a worktree beside
    the main one, another session's) share no socket, settings or folder,
    so a run in one is never answered by the other's build."""
    global W, SUPPORT, SUITE, SOCK
    W = f"{name}-{hashlib.sha1(str(ROOT).encode()).hexdigest()[:8]}"
    SUPPORT = f"{HOME}/Library/Application Support/Search ({W})"
    SUITE = f"com.officecommun.search.test.{W}"
    SOCK = f"{SUPPORT}/bench.sock"
use("chat-tests")

# The page the chat works: a form that says who signed up, once submitted.
PAGE = """<!doctype html><html><head><title>sign up</title></head><body>
<form><input id="first" placeholder="Name"><button type="submit">Sign up</button></form>
<p id="done" hidden></p>
<script>
document.forms[0].addEventListener("submit", function (e) {
  e.preventDefault();
  var done = document.getElementById("done");
  done.textContent = "signed " + document.getElementById("first").value;
  done.hidden = false;
});
</script></body></html>"""

# The stand-in model: one line of the script a request at a time, in the
# openAI way of streaming, over SSE (see Bot.system). Each request carries
# all that has been said and shown so far.
script = []
seen = []
def said(reply):
    body = json.dumps({"choices": [{"delta": {"content": reply}}]})
    return f"data: {body}\n\ndata: [DONE]\n\n".encode()
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = PAGE.encode() if self.path == "/form" else f"<!doctype html><title>{self.path.strip('/')}</title>".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        seen.append(json.loads(self.rfile.read(length) or b"{}"))
        line = script.pop(0) if script else '{"answer":"nothing left in the script"}'
        # A tab's real id stood in for {tab}, from the TABS listing the
        # model was last shown.
        if isinstance(line, dict) and "tab_from" in line:
            real = tab_of(words(seen, "TABS", role="user"), line["tab_from"]) or ""
            body = said(line["say"].replace("{tab}", real))
        else:
            body = said(line)
        self.send_response(200); self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
srv = ThreadingHTTPServer(("127.0.0.1", 0), H); threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{srv.server_port}"

started = set()
def running(): return set(subprocess.run(["pgrep", "-f", APP + "/Contents/MacOS"], capture_output=True, text=True).stdout.split())
def holding(): return set(subprocess.run(["lsof", "-t", "--", SOCK], capture_output=True, text=True).stdout.split()) if os.path.exists(SOCK) else set()
def pids(): return sorted((started & running()) | (holding() & running()))
def probe(pid):
    names = subprocess.run(["lsof", "-a", "-U", "-p", pid, "-Fn"], capture_output=True, text=True).stdout
    return any(n.startswith("n") and "/Search (" in n and n.endswith("/bench.sock") for n in names.splitlines())
def main_checkout():
    git = lambda *a: subprocess.run(["git", "-C", str(ROOT), "rev-parse", *a], capture_output=True, text=True).stdout.strip()
    return git("--git-dir") != "" and Path(git("--absolute-git-dir")) == Path(ROOT, git("--git-common-dir")).resolve()
if main_checkout() and any(not probe(p) for p in running()):
    sys.exit(f"{APP} is in use by a Search that isn't a probe. Run the tests from a worktree (git worktree add).")
def wipe():
    subprocess.run(["rm", "-rf", SUPPORT]); subprocess.run(["defaults", "delete", SUITE], capture_output=True)
def setup():
    for p in pids(): subprocess.run(["kill", p])
    started.clear()
    time.sleep(1); wipe()
    for k in ["bench", "welcomed"]: subprocess.run(["defaults", "write", SUITE, k, "-bool", "true"])
def launch():
    if os.path.exists(SOCK): os.remove(SOCK)
    before = running()
    subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={W}", APP])
    for _ in range(150):
        if os.path.exists(SOCK): break
        time.sleep(0.1)
    time.sleep(2)
    started.update((running() - before) & holding())
def cmd(req):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as c:
        c.settimeout(60); c.connect(SOCK); c.sendall(json.dumps(req).encode() + b"\n")
        data = b""
        while True:
            ch = c.recv(65536)
            if not ch: break
            data += ch
    a = json.loads(data.split(b"\n", 1)[0] or b"{}")
    if "error" in a: raise RuntimeError(f"{req}: {a['error']}")
    return a
def bt(action, **fields):
    try: return cmd({"do": "bot", "action": action, **fields})
    except RuntimeError as e: return {"error": str(e)}
def chat(action, **fields):
    try: return cmd({"do": "chat", "action": action, **fields})
    except RuntimeError as e: return {"error": str(e)}
def quit():
    try: cmd({"do": "quit"})
    except Exception: pass
    for _ in range(30):
        if not pids(): break
        time.sleep(0.2)
    for p in pids(): subprocess.run(["kill", p])
def finish():
    quit(); time.sleep(0.5); wipe()

class T:
    def __init__(self): self.passed = self.failed = 0
    def ok(self, name, cond, extra=""):
        if cond: self.passed += 1; print("  ok  ", name)
        else: self.failed += 1; print("  FAIL", name, extra)
    def done(self):
        print(f"{self.passed} passed, {self.failed} failed")

def until(t, wanted, within=30, doing="what the loop was doing"):
    """The chat's state, polled until it holds what a case waits for."""
    end = time.time() + within
    state = {}
    while time.time() < end:
        state = chat("state")
        if wanted(state): return state
        time.sleep(0.25)
    t.ok(f"came to {doing}", False, state)
    return state

def words(records, what, role=None):
    """What the model was shown or told, from the stand-in's record of
    requests — one ask of it for each line of the script."""
    for asked in records:
        for message in asked.get("messages", []):
            if role and message.get("role") != role: continue
            if what in message.get("content", ""):
                return message["content"]
    return ""

def tab_of(listing, url):
    """A tab's id, taken from the TABS listing the model was shown — the
    first whose address holds the url."""
    for line in listing.splitlines():
        if url in line:
            return line.split(" · ")[0].strip()
    return None

def form_ready(tab, within=15):
    end = time.time() + within
    while time.time() < end:
        try:
            if "Name" in cmd({"do": "agent", "action": "snapshot", "id": tab}).get("snapshot", ""):
                return True
        except RuntimeError:
            pass
        time.sleep(0.2)
    return False

# MARK: - the cases

def case_tab(t):
    """the tab itself: made from the File menu's place, standing in the row,
    gone with its talk when it closes"""
    setup(); launch()
    cmd({"do": "ai", "action": "mock", "url": f"http://127.0.0.1:{srv.server_port}/"})
    bt("use", provider="ollama")
    made = chat("new")
    t.ok("a chat tab is made", made.get("open") is True and made.get("id"), made)
    row = [tab.get("label") for tab in cmd({"do": "tabs"}).get("tabs", [])]
    t.ok("it stands in the row by name", "Agent Chat" in row, row)
    state = chat("state")
    t.ok("its talk is over every tab, unattended never",
         state.get("open") is True and state.get("place", "").startswith("over every tab")
         and state.get("unattended") is False, state)

    # A word with the agent, so the talk is more than empty when it goes.
    script.clear(); seen.clear()
    script.append('{"answer": "standing by"}')
    chat("ask", text="Are you there?")
    until(t, lambda s: any(e["kind"] == "answer" and e["words"] == "standing by"
                           for e in s.get("events", [])), doing="the chat's first answer")

    # Closed like any tab: the talk goes with it.
    chat("close")
    after = chat("state")
    t.ok("closed, its talk goes with it", after.get("open") is False, after)
    row = [tab.get("label") for tab in cmd({"do": "tabs"}).get("tabs", [])]
    t.ok("…and the row holds it no more", "Agent Chat" not in row, row)

def case_reach(t):
    """the reach: every tab listed to the model, itself never among them;
    no page in front while the person talks, so every act names its tab"""
    setup(); launch()
    cmd({"do": "ai", "action": "mock", "url": f"http://127.0.0.1:{srv.server_port}/"})
    bt("use", provider="ollama")
    form = cmd({"do": "open", "url": f"{BASE}/form"})
    form_ready(form["id"])
    chat("new")

    script.clear(); seen.clear()
    script.extend([
        '{"say": "I\'ll fill the form in on its tab"}',
        {"tab_from": f"{BASE}/form", "say": '{"act":{"verb":"fill","tab":"{tab}","target":"css=#first","text":"Ada"}}'},
        {"tab_from": f"{BASE}/form", "say": '{"read":"css=#first","tab":"{tab}"}'},
        '{"answer": "filled in, as asked"}',
    ])
    chat("ask", text="Fill the form in for Ada")
    shown = until(t, lambda s: words(seen, "TABS", role="user") != "", doing="the tabs being shown")
    listing = words(seen, "TABS", role="user")
    t.ok("every tab is listed to the model", f"{BASE}/form" in listing, listing)
    t.ok("…and the chat itself never is", "Agent Chat" not in listing, listing)
    t.ok("no page in front while the person talks",
         "No page is in front" in words(seen, "No page is in front", role="user"), "")

    held = until(t, lambda s: (s.get("pending") or {}).get("verb") == "fill", doing="the act held for allowing")
    t.ok("an act on a named tab is held like any other",
         (held.get("pending") or {}).get("text") == "Ada", held.get("pending"))
    chat("allow")
    read = until(t, lambda s: any(e["kind"] == "act" and e["act"][0] == "read"
                                  for e in s.get("events", [])), doing="the read coming back")
    t.ok("…done, and read back from the tab it was for",
         any(e["kind"] == "act" and e["act"][0] == "read" and e["act"][3] == "read"
             for e in read.get("events", []))
         and "Ada" in words(seen, "You read"), read.get("events"))
    until(t, lambda s: any(e["kind"] == "answer" and e["words"] == "filled in, as asked"
                           for e in s.get("events", [])))

def case_rules(t):
    """the rules: a command beyond the page held, a close always asked"""
    setup(); launch()
    cmd({"do": "ai", "action": "mock", "url": f"http://127.0.0.1:{srv.server_port}/"})
    bt("use", provider="ollama")
    form = cmd({"do": "open", "url": f"{BASE}/form"})
    form_ready(form["id"])
    chat("new")

    # A command beyond the page: held for the person's Allow, refused.
    script.clear(); seen.clear()
    script.extend([
        '{"run": "echo from the chat"}',
        '{"answer": "it asked"}',
    ])
    chat("ask", text="Run that")
    until(t, lambda s: (s.get("pending") or {}).get("verb") == "run", doing="the command held for allowing")
    chat("refuse")
    until(t, lambda s: any(e["kind"] == "answer" and e["words"] == "it asked"
                           for e in s.get("events", [])))

    # A close: always asked — Auto on, and still asked.
    chat("auto", on=True)
    script.clear(); seen.clear()
    script.append({"tab_from": f"{BASE}/form", "say": '{"close":"{tab}"}'})
    chat("ask", text="Close the form tab")
    held = until(t, lambda s: (s.get("pending") or {}).get("verb") == "close", doing="the close held under Auto")
    t.ok("Auto doesn't skip a close here either",
         (held.get("pending") or {}).get("verb") == "close", held.get("pending"))
    chat("allow")
    until(t, lambda s: not any(tab["id"] == form["id"] for tab in cmd({"do": "tabs"}).get("tabs", [])),
          doing="the form tab to close")
    t.ok("allowed, the tab closes",
         not any(tab["id"] == form["id"] for tab in cmd({"do": "tabs"}).get("tabs", [])))

def bands(path):
    """How many bands of words a picture of the chat's window holds:
    one per row of text (an ask, a saying, an answer) — for checking a
    reply stayed on the screen after the next one arrived. The PNG is
    RGBA with the usual five filters; a bright pixel is a word's."""
    import struct, zlib
    with open(path, "rb") as f:
        png = f.read()
    assert png[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    pos, width, height, idat = 8, 0, 0, b""
    while pos < len(png):
        length = struct.unpack(">I", png[pos:pos + 4])[0]
        kind = png[pos + 4:pos + 8]
        if kind == b"IHDR":
            width, height = struct.unpack(">II", png[pos + 8:pos + 16])
        elif kind == b"IDAT":
            idat += png[pos + 8:pos + 8 + length]
        pos += 12 + length
    raw = zlib.decompress(idat)
    stride = width * 4 + 1

    def paeth(a, b, c):
        p = a + b - c
        pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
        if pa <= pb and pa <= pc: return a
        if pb <= pc: return b
        return c

    # Each row, unfiltered on the row before it (Up) and the byte
    # before it in the same row (Sub); Average and Paeth mix both.
    prev = bytearray(width * 4)
    lines = []
    for y in range(height):
        start = y * stride
        f = raw[start]
        line = bytearray(raw[start + 1:start + stride])
        bpp = 4
        for i in range(len(line)):
            left = line[i - bpp] if i >= bpp else 0
            up = prev[i]
            corner = prev[i - bpp] if i >= bpp else 0
            if f == 1: line[i] = (line[i] + left) & 0xFF
            elif f == 2: line[i] = (line[i] + up) & 0xFF
            elif f == 3: line[i] = (line[i] + (left + up) // 2) & 0xFF
            elif f == 4: line[i] = (line[i] + paeth(left, up, corner)) & 0xFF
        lines.append(line)
        prev = line
    found, in_band, band_top = 0, False, 0
    for y in range(80, min(1400, height)):
        line = lines[y]
        bright = sum(1 for x in range(width)
                     if line[x * 4] + line[x * 4 + 1] + line[x * 4 + 2] > 420)
        if bright > 8 and not in_band:
            in_band, band_top = True, y
        elif bright <= 8 and in_band:
            if y - band_top >= 6: found += 1
            in_band = False
    if in_band and min(1400, height) - band_top >= 6: found += 1
    return found

def case_selection(t):
    """the words of a reply, takeable out of the talk: drawn under a
    selection layer (the one ⌘C reads a selection from), and still on
    the screen when the next reply arrives"""
    setup(); launch()
    cmd({"do": "ai", "action": "mock", "url": f"http://127.0.0.1:{srv.server_port}/"})
    bt("use", provider="ollama")
    chat("new")

    # An answer in markdown, so what is takeable is the words of a
    # rendered reply, not a string of marks.
    script.clear(); seen.clear()
    script.append('{"answer": "**Copied words** from a `reply`"}')
    chat("ask", text="Say something worth taking")
    until(t, lambda s: any(e["kind"] == "answer" and e["words"] == "**Copied words** from a `reply`"
                           for e in s.get("events", [])), doing="the markdown answer")

    # The words of the reply, drawn as selectable text: the selection
    # layer SwiftUI puts under takeable words is there.
    first = chat("select")
    t.ok("a reply's words are drawn as selectable text",
         first.get("selectable", 0) > 0 and "Copied words" in (first.get("lastWords") or ""), first)

    # The next reply arrives: the one before it stays on the screen,
    # its bands of words still standing — a redraw that names every
    # markdown block as new can drop what stood (see MarkdownBlock's id).
    script.clear(); seen.clear()
    script.append('{"answer": "a second answer comes after"}')
    chat("ask", text="And again")
    until(t, lambda s: len([e for e in s.get("events", []) if e["kind"] == "answer"]) == 2,
          doing="the second answer")
    # Two asks and two answers, each a band of its own, both turns on
    # the screen together (the picture's own count of bands of words).
    cmd({"do": "pages", "on": True})
    time.sleep(1)
    cmd({"do": "picture", "path": "/tmp/chat-keeps.png"})
    cmd({"do": "pages", "on": False})
    kept = bands("/tmp/chat-keeps.png")
    t.ok("the reply before it still stands on the screen", kept >= 4, f"bands: {kept}")
    chat("close")

# MARK: -

def main():
    t = T()
    for case in (case_tab, case_reach, case_rules, case_selection):
        print(case.__name__)
        try:
            case(t)
        except Exception as e:
            t.failed += 1; print("  FAIL", case.__name__, e)
    finish()
    t.done()
    sys.exit(1 if t.failed else 0)

if __name__ == "__main__":
    main()
