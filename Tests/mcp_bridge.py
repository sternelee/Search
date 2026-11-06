#!/usr/bin/env python3
"""The MCP bridge, checked end to end: search-mcp spoken to as Claude Code
or Codex would speak to it, over pipes, its calls landing on the bench
socket of a hidden probe.

Build first (`./build.sh` or `./build.sh debug`), then run
`python3 Tests/mcp_bridge.py`. The app is started hidden in a world of its
own (SEARCH_PROBE=mcp-bridge-<checkout>, see use()), driven through the
bridge beside everything the app checks of it, and quit; its settings and
files are removed afterwards. Nothing here makes, shows or brings forward
a window.

Three sides of the bridge are checked:
  the handshake   initialize, ping, tools/list — what it is, what it offers,
                  and a method it doesn't know said so
  the hands       a page opened through it, snapshotted, filled, submitted,
                  read and closed — the same verbs the bench speaks, said
                  as MCP says them
  out of sight    the agents' pages hidden from the row (Settings › Browser
                  Use): nothing drawn, nothing under the number keys — and
                  the hands still working, unseen
  the closed door the browser's socket nowhere to be found: the tools
                  still list, a call says so in words a person can read
"""

import hashlib
import json
import os
import re
import select
import socket
import subprocess
import sys
import threading
import time
import uuid
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = os.environ.get("SEARCH_TEST_APP", str(ROOT / "build" / "Search.app"))
BRIDGE = str(Path(APP) / "Contents" / "MacOS" / "search-mcp")
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
use("mcp-bridge-tests")

# The page the bridge works: a form that says hello to whatever was typed,
# once it is submitted — by a click or by Enter, as the page hears both.
PAGE = """<!doctype html><html><head><title>A form</title></head><body>
<form><input id="who" placeholder="Name"><button type="submit">Say it</button></form>
<p id="said" hidden></p>
<script>
document.forms[0].addEventListener("submit", function (e) {
  e.preventDefault();
  var said = document.getElementById("said");
  said.textContent = "hello " + document.getElementById("who").value;
  said.hidden = false;
});
</script></body></html>"""
class Form(BaseHTTPRequestHandler):
    def do_GET(self):
        body = PAGE.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
form = ThreadingHTTPServer(("127.0.0.1", 0), Form)
threading.Thread(target=form.serve_forever, daemon=True).start()
FORM = f"http://127.0.0.1:{form.server_port}/form"

# Only ever a probe of this world: the one this run started, or one a run
# before left holding this world's socket. Never the Search someone is using,
# even one running from this very build (see running()).
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
# Someone's own Search running from this build: no probe starts beside it
# from here. Run the tests from a worktree of your own instead.
if main_checkout() and any(not probe(p) for p in running()):
    sys.exit(f"{APP} is in use by a Search that isn't a probe. Run the tests from a worktree (git worktree add).")
WEBKIT = f"{HOME}/Library/WebKit/com.officecommun.search"
REAL = f"{HOME}/Library/Application Support/Search"
FIRST_SPACE = "00000000-0000-0000-0000-000000000001"
def guarded():
    """Store ids no wipe removes, whatever stores() names: every space of
    the real Search's own list, and the first space's fixed id."""
    ids = {FIRST_SPACE}
    try:
        ids |= {str(uuid.UUID(space["id"])) for space in json.load(open(f"{REAL}/spaces.json"))}
    except (OSError, ValueError, TypeError, KeyError, AttributeError):
        pass
    return ids
def wipe():
    subprocess.run(["rm", "-rf", SUPPORT]); subprocess.run(["defaults", "delete", SUITE], capture_output=True)
def setup(**prefs):
    for p in pids(): subprocess.run(["kill", p])
    started.clear()
    time.sleep(1); wipe()
    for k in ["bench", "welcomed"]: subprocess.run(["defaults", "write", SUITE, k, "-bool", "true"])
    for k, v in prefs.items(): subprocess.run(["defaults", "write", SUITE, k, "-bool", "true" if v else "false"])
def launch():
    if os.path.exists(SOCK): os.remove(SOCK)
    before = running()
    subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={W}", APP])
    for _ in range(150):
        if os.path.exists(SOCK): break
        time.sleep(0.1)
    time.sleep(2)
    # Whatever came up from this build just now and holds this world's socket.
    started.update((running() - before) & holding())
def quit():
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as c:
            c.settimeout(60); c.connect(SOCK); c.sendall(json.dumps({"do": "quit"}).encode() + b"\n")
    except Exception:
        pass
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

# MARK: - speaking MCP over pipes

def cmd(req):
    """One bench verb over the socket, the answer as it came."""
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

def row():
    """The tabs as the person sees them: drawn in the row, and counted by
    the number keys (see Browser.shownTabs)."""
    state = cmd({"do": "probe"})
    return state.get("rowTabs", []), state.get("keyTabs", [])

def settled_row():
    """The row, once it has stopped changing — a page a case before just
    closed can take a moment to leave it."""
    before = row()
    for _ in range(20):
        time.sleep(0.25)
        now = row()
        if now == before: return now
        before = now
    return before

def tool_text(answer):
    text = answer.get("result", {}).get("content", [{}])[0].get("text", "")
    try:
        return json.loads(text)
    except (ValueError, TypeError):
        return text

class Bridge:
    """The bridge as a process, spoken to a line at a time over pipes: one
    request out, one answer back, matched by its id — raw reads on the
    pipe's own fd, so no buffering sits between this and the bridge."""
    def __init__(self, socket_path=SOCK):
        self.proc = subprocess.Popen(
            [BRIDGE, "--socket", socket_path],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0,
        )
        self.held = b""
        self.given = 0

    def ask(self, method, params=None):
        """One request and its answer — the id it was given is the id it
        comes back with, or the bridge is not speaking as it should."""
        self.given += 1
        self.say({"jsonrpc": "2.0", "id": self.given, "method": method, "params": params or {}})
        answer = json.loads(self.readline() or "{}")
        if answer.get("id") != self.given:
            raise RuntimeError(f"the bridge answered id {answer.get('id')} for {self.given}")
        return answer

    def say(self, request):
        self.proc.stdin.write(json.dumps(request).encode() + b"\n")

    def call(self, name, arguments=None):
        return self.ask("tools/call", {"name": name, "arguments": arguments or {}})

    def readline(self, within=60):
        end = time.time() + within
        fd = self.proc.stdout.fileno()
        while b"\n" not in self.held:
            left = end - time.time()
            if left <= 0: return ""
            ready, _, _ = select.select([fd], [], [], left)
            if not ready: continue
            piece = os.read(fd, 65536)
            if not piece: return ""
            self.held += piece
        line, self.held = self.held.split(b"\n", 1)
        return line.decode().strip()

    def bye(self):
        self.proc.stdin.close()
        try: self.proc.wait(timeout=2)
        except subprocess.TimeoutExpired: self.proc.kill()

# MARK: - the cases

def case_handshake(t):
    """What the bridge says it is, what it offers, and how it says no."""
    bridge = Bridge()
    met = bridge.ask("initialize", {"protocolVersion": "2025-06-18"})
    t.ok("initialize names itself", met.get("result", {}).get("serverInfo", {}).get("name") == "search", met)
    t.ok("initialize offers tools", "tools" in met.get("result", {}).get("capabilities", {}), met)
    t.ok("initialize says what it is for", "pages" in met.get("result", {}).get("instructions", ""), met)
    bridge.say({"jsonrpc": "2.0", "method": "notifications/initialized"})
    pong = bridge.ask("ping")
    t.ok("ping answers", "result" in pong, pong)
    # A client that frames with \r\n is answered as one that frames with \n.
    bridge.proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 900, "method": "ping"}).encode() + b"\r\n")
    crlf = json.loads(bridge.readline() or "{}")
    t.ok("a client framing with \r\n is answered", crlf.get("id") == 900 and "result" in crlf, crlf)
    listed = bridge.ask("tools/list")
    names = {tool.get("name") for tool in listed.get("result", {}).get("tools", [])}
    wanted = {"list_pages", "open_page", "snapshot", "act", "read", "wait", "close_page"}
    t.ok("the tools are the agent's verbs", wanted <= names, names)
    snap = next(tool for tool in listed.get("result", {}).get("tools", []) if tool.get("name") == "snapshot")
    t.ok("a tool says what it takes", snap.get("inputSchema", {}).get("required") == ["page"], snap)
    nothing = bridge.ask("resources/list")
    t.ok("no resources", nothing.get("result", {}).get("resources") == [], nothing)
    unknown = bridge.ask("sampling/createMessage")
    t.ok("a method it doesn't know says so", unknown.get("error", {}).get("code") == -32601, unknown)
    gone = bridge.call("no_such_tool")
    t.ok("a tool it doesn't have is an error answer, not a dead line",
         gone.get("result", {}).get("isError") is True and "no tool called" in tool_text(gone), gone)
    bridge.bye()

def case_pages(t):
    """A page worked from end to end, as an agent CLI would work it."""
    bridge = Bridge()
    page = tool_text(bridge.call("open_page", {"url": FORM, "label": "form"}))
    t.ok("a page opened and named", page.get("label") == "form" and page.get("id"), page)
    came = bridge.call("wait", {"page": "form"})
    t.ok("the page came in", tool_text(came).get("ok") is True, came)
    snap = tool_text(bridge.call("snapshot", {"page": "form"}))
    t.ok("the page in words", 'textbox "Name"' in snap.get("snapshot", ""), snap.get("snapshot", "")[:200])
    ref = re.search(r'textbox "Name" @(\d+)', snap.get("snapshot", ""))
    t.ok("a number to act by", ref is not None, snap.get("snapshot", "")[:200])
    filled = tool_text(bridge.call("act", {"page": "form", "verb": "fill", "target": f"@{ref.group(1)}", "text": "grace"}))
    t.ok("filled", filled.get("value") == "grace", filled)
    read = tool_text(bridge.call("read", {"page": "form", "target": f"@{ref.group(1)}"}))
    t.ok("read back", read.get("value") == "grace", read)
    pressed = bridge.call("act", {"page": "form", "verb": "press", "target": f"@{ref.group(1)}", "text": "Enter"})
    t.ok("Enter submitted", tool_text(pressed).get("submitted") is True, pressed)
    hello = tool_text(bridge.call("wait", {"page": "form", "text": "hello grace"}))
    t.ok("the page said hello", hello.get("ok") is True, hello)
    listed = tool_text(bridge.call("list_pages"))
    t.ok("the page listed by name", any(p.get("label") == "form" for p in listed.get("pages", [])), listed)
    closed = tool_text(bridge.call("close_page", {"page": "form"}))
    t.ok("closed", closed.get("closed", 0) >= 1 or "error" not in closed, closed)
    after = tool_text(bridge.call("list_pages"))
    t.ok("gone when it says so", not any(p.get("label") == "form" for p in after.get("pages", [])), after)
    # An act on a page since gone: said so, not a dead line.
    stale = bridge.call("snapshot", {"page": "form"})
    gone = tool_text(stale)
    said = gone.get("error", "") if isinstance(gone, dict) else str(gone)
    t.ok("a page since closed says so",
         stale.get("result", {}).get("isError") is True and "no such tab" in said, stale)
    bridge.bye()

def case_down(t):
    """The browser nowhere: the bridge still speaks, and says so in words."""
    bridge = Bridge(socket_path=f"{SUPPORT}/nowhere.sock")
    met = bridge.ask("initialize", {"protocolVersion": "2025-06-18"})
    t.ok("the handshake needs no browser", met.get("result", {}).get("serverInfo", {}).get("name") == "search", met)
    gone = bridge.call("open_page", {"url": FORM})
    t.ok("a call says the browser isn't listening",
         gone.get("result", {}).get("isError") is True and "Let a script drive Search" in tool_text(gone), gone)
    bridge.bye()

def case_quiet(t):
    """The agents' pages out of sight: nothing of them in the row or under
    the number keys — and the hands still work, unseen."""
    base_drawn, base_shown = settled_row()
    bridge = Bridge()
    opened = tool_text(bridge.call("open_page", {"url": FORM, "label": "quiet"}))
    page = opened.get("id", "")
    t.ok("a page opened", opened.get("label") == "quiet" and page, opened)
    bridge.call("wait", {"page": "quiet"})
    drawn, shown = row()
    t.ok("seen while the switch is off", page in drawn and page in shown, (drawn, shown))
    cmd({"do": "ui", "quiet": True})
    drawn, shown = row()
    t.ok("out of sight with the switch on", page not in drawn and page not in shown, (drawn, shown))
    t.ok("…and nothing else went with it", drawn == base_drawn and shown == base_shown, (drawn, base_drawn))
    # Unseen is not asleep: the page answers the bridge as ever.
    snap = tool_text(bridge.call("snapshot", {"page": "quiet"}))
    t.ok("the page still answers unseen", 'textbox "Name"' in snap.get("snapshot", ""), snap)
    ref = re.search(r'textbox "Name" @(\d+)', snap.get("snapshot", ""))
    filled = tool_text(bridge.call("act", {"page": "quiet", "verb": "fill", "target": f"@{ref.group(1)}", "text": "grace"}))
    t.ok("…and is still worked unseen", filled.get("value") == "grace", filled)
    cmd({"do": "ui", "quiet": False})
    drawn, _ = row()
    t.ok("back in sight with the switch off", page in drawn, drawn)
    bridge.call("close_page", {"page": "quiet"})
    drawn, _ = row()
    t.ok("gone when it says so, either way", page not in drawn, drawn)
    bridge.bye()

# MARK: -

def main():
    if not os.path.exists(BRIDGE):
        sys.exit(f"{BRIDGE} isn't built — run ./build.sh (or ./build.sh debug) first")
    t = T()
    setup()
    launch()
    for case in (case_handshake, case_pages, case_quiet, case_down):
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
