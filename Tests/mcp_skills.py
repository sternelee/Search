#!/usr/bin/env python3
"""The person's MCP servers and skills, checked through the bench's socket
in a hidden probe.

Build first (`./build.sh` or `./build.sh debug`), then run
`python3 Tests/mcp_skills.py`. The app is started hidden in a world of its
own (SEARCH_PROBE=mcp-tests-<checkout>, see use()), driven through ./bench's
socket, and quit; its settings and files are removed afterwards. Nothing
here makes, shows or brings forward a window.

Three sides of the surface are checked:
  the shelf    skills verbs — a SKILL.md found, listed, switched, read
  the servers  mcp verbs — a stand-in over pipes (a program of the test's
               own) and one over HTTP (paged tools, a session id, an
               event-stream answer, and a header of its own wanted at the
               door), added, met, called, let go
  the talk     the bot calling a tool (held for allowing) and reading a
               skill; the Ask panel calling a read-only tool
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
import uuid
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
use("mcp-tests")

# The stand-in model: one line of the script a request at a time, in the
# openAI way of streaming, over SSE — the one line of JSON the loop asks of
# the model each time it thinks. Each request carries all that has been
# said and shown so far (the system prompt included, as its first message).
script = []
seen = []
def said(reply):
    body = json.dumps({"choices": [{"delta": {"content": reply}}]})
    return f"data: {body}\n\ndata: [DONE]\n\n".encode()
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = f"<!doctype html><title>{self.path.strip('/')}</title><p>{self.path.strip('/')} to read</p>".encode()
        self.send_response(200); self.send_header("Content-Type", "text/html"); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        seen.append(json.loads(self.rfile.read(length) or b"{}"))
        line = script.pop(0) if script else '{"answer":"nothing left in the script"}'
        if isinstance(line, dict): time.sleep(line.get("sleep", 0)); line = line["say"]
        body = said(line)
        self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
srv = ThreadingHTTPServer(("127.0.0.1", 0), H); threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{srv.server_port}"

# The stand-in MCP server over pipes: JSON-RPC 2.0, one object a line on
# stdin and stdout, keeping notes in its own memory — two tools, one that
# writes and one that only reads.
NOTES_SERVER = r'''
import json, sys
notes = []
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    req = json.loads(line)
    method = req.get("method", "")
    if "id" not in req: continue
    out = {"jsonrpc": "2.0", "id": req["id"]}
    if method == "initialize":
        out["result"] = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
                         "serverInfo": {"name": "notes", "version": "1.0"}}
    elif method == "tools/list":
        out["result"] = {"tools": [
            {"name": "add_note", "description": "Keep a note for the person",
             "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}},
             "annotations": {"readOnlyHint": False}},
            {"name": "notes", "description": "Every note the person kept",
             "inputSchema": {"type": "object", "properties": {}},
             "annotations": {"readOnlyHint": True}},
        ]}
    elif method == "tools/call":
        name = req.get("params", {}).get("name", "")
        args = req.get("params", {}).get("arguments", {})
        if name == "add_note":
            notes.append(args.get("text", ""))
            out["result"] = {"content": [{"type": "text", "text": "Noted: " + args.get("text", "")}], "isError": False}
        elif name == "notes":
            out["result"] = {"content": [{"type": "text", "text": "\n".join(notes) if notes else "no notes yet"}], "isError": False}
        else:
            out["error"] = {"code": -32602, "message": "no tool " + name}
    else:
        out["error"] = {"code": -32601, "message": "no " + method}
    sys.stdout.write(json.dumps(out) + "\n")
    sys.stdout.flush()
'''

# The stand-in MCP server over HTTP: initialize hands out a session id, the
# tools come two pages with a cursor, and one call is answered as a stream
# of events instead of plain JSON. What it was asked, whether the session
# id came back, and what it said at the door for a header, is kept in mlog.
mlog = []
class M(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        req = json.loads(self.rfile.read(length) or b"{}")
        method = req.get("method", "")
        mlog.append((method, self.headers.get("Mcp-Session-Id"), self.headers.get("Authorization", "")))
        if self.headers.get("Authorization") != "Bearer shelf":
            body = b'{"error": "who goes there"}'
            self.send_response(401)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers(); self.wfile.write(body)
            return
        if "id" not in req:
            self.send_response(200); self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", "2"); self.end_headers(); self.wfile.write(b"{}")
            return
        out = {"jsonrpc": "2.0", "id": req["id"]}
        if method == "initialize":
            out["result"] = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
                             "serverInfo": {"name": "shelf", "version": "1.0"}}
        elif method == "tools/list":
            if req.get("params", {}).get("cursor") is None:
                out["result"] = {"tools": [
                    {"name": "notes", "description": "Every book on the shelf",
                     "inputSchema": {"type": "object", "properties": {}},
                     "annotations": {"readOnlyHint": True}}],
                    "nextCursor": "2"}
            else:
                out["result"] = {"tools": [
                    {"name": "shelve", "description": "Put a book on the shelf",
                     "inputSchema": {"type": "object", "properties": {"title": {"type": "string"}}},
                     "annotations": {"readOnlyHint": False}}]}
        elif method == "tools/call":
            out["result"] = {"content": [{"type": "text", "text": "one: brassica"}], "isError": False}
        else:
            out["error"] = {"code": -32601, "message": "no " + method}
        if method == "tools/call":
            body = f"data: {json.dumps(out)}\n\n".encode()
            ctype = "text/event-stream"
        else:
            body = json.dumps(out).encode()
            ctype = "application/json"
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        if method == "initialize": self.send_header("Mcp-Session-Id", "test-session")
        self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
msrv = ThreadingHTTPServer(("127.0.0.1", 0), M); threading.Thread(target=msrv.serve_forever, daemon=True).start()
MBASE = f"http://127.0.0.1:{msrv.server_port}"

# Only ever a probe of this world: the one this run started, or one a run
# before left holding this world's socket. Never the Search someone is using,
# even one running from this very build (see running()).
started = set()
def running(): return set(subprocess.run(["pgrep", "-f", APP + "/Contents/MacOS"], capture_output=True, text=True).stdout.split())
def holding(): return set(subprocess.run(["lsof", "-t", "--", SOCK], capture_output=True, text=True).stdout.split()) if os.path.exists(SOCK) else set()
def pids(): return sorted((started & running()) | (holding() & running()))
WEBKIT = f"{HOME}/Library/WebKit/com.officecommun.search"
def stores():
    """The WebKit stores this world's runs made, where WebKit keeps them and
    named as the app names them (Store.probeStore, Spaces.store). Only
    those: a real Search's spaces keep their stores beside them."""
    h = 2166136261
    for byte in W.encode(): h = ((h ^ byte) * 16777619) & 0xFFFFFFFF
    probe = lambda kind: f"5E4C{h >> 16:04X}-{h & 0xFFFF:04X}-4000-8000-{kind:012X}"
    found = [f"{WEBKIT}/WebsiteDataStore/{probe(1).lower()}", f"{WEBKIT}/WebExtensions/{probe(2)}"]
    ids = []
    try:
        ids += [space["id"] for space in json.load(open(f"{SUPPORT}/spaces.json")) if space.get("sharesSignIns") is not True]
    except (OSError, ValueError, TypeError, KeyError):
        pass
    erasing = subprocess.run(["defaults", "read", SUITE, "spaces.erasing"], capture_output=True, text=True).stdout
    ids += re.findall(r"[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}", erasing)
    for id in ids:
        try: id = str(uuid.UUID(id))
        except (ValueError, AttributeError, TypeError): continue
        # The first space is signed in where the world is: no store of its own.
        if id != FIRST_SPACE:
            found.append(f"{WEBKIT}/WebsiteDataStore/{id}")
    return found
# The real Search's folder, beside whose stores these are removed.
REAL = f"{HOME}/Library/Application Support/Search"
FIRST_SPACE = "00000000-0000-0000-0000-000000000001"
def guarded():
    """Store ids no wipe removes, whatever stores() names: every space of the
    real Search's own list, and the first space's fixed id."""
    ids = {FIRST_SPACE}
    try:
        ids |= {str(uuid.UUID(space["id"])) for space in json.load(open(f"{REAL}/spaces.json"))}
    except (OSError, ValueError, TypeError, KeyError, AttributeError):
        pass
    return ids
def wipe():
    # The stores first: which spaces had one is in the folder and settings
    # about to go.
    keep = guarded()
    for path in stores():
        if os.path.basename(path).lower() in keep:
            print(f"wipe: not removing {path}: the real Search's spaces use that id", file=sys.stderr)
            continue
        subprocess.run(["rm", "-rf", path])
    subprocess.run(["rm", "-rf", SUPPORT]); subprocess.run(["defaults", "delete", SUITE], capture_output=True)
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
    try: cmd({"do": "quit"})
    except Exception: pass
    for _ in range(30):
        if not pids(): break
        time.sleep(0.2)
    for p in pids(): subprocess.run(["kill", p])
def cmd(req):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as c:
        c.settimeout(60); c.connect(f"{SUPPORT}/bench.sock"); c.sendall(json.dumps(req).encode() + b"\n")
        data = b""
        while True:
            ch = c.recv(65536)
            if not ch: break
            data += ch
    a = json.loads(data.split(b"\n", 1)[0] or b"{}")
    if "error" in a: raise RuntimeError(f"{req}: {a['error']}")
    return a
def bt(action, **fields):
    """One bot verb, the answer as it came, errors included — so a case
    can ask for them."""
    try:
        return cmd({"do": "bot", "action": action, **fields})
    except RuntimeError as e:
        return {"error": str(e)}
def mcp(action, **fields):
    """One mcp verb, the answer as it came, errors included."""
    try:
        return cmd({"do": "mcp", "action": action, **fields})
    except RuntimeError as e:
        return {"error": str(e)}
def skills(action, **fields):
    """One skills verb, the answer as it came, errors included."""
    try:
        return cmd({"do": "skills", "action": action, **fields})
    except RuntimeError as e:
        return {"error": str(e)}
class T:
    def __init__(self): self.passed = self.failed = 0
    def ok(self, name, cond, extra=""):
        if cond: self.passed += 1; print("  ok  ", name)
        else: self.failed += 1; print("  FAIL", name, extra)
    def done(self):
        print(f"{self.passed} passed, {self.failed} failed")
def finish():
    quit(); time.sleep(0.5); wipe()

def until(t, wanted, within=30, doing="what the loop was doing"):
    """The bot's state, polled until it holds what a case waits for — an
    act held for allowing, an answer, a card. The loop works on the app's
    own queue between asks; this only looks."""
    end = time.time() + within
    state = {}
    while time.time() < end:
        state = bt("state")
        if wanted(state): return state
        time.sleep(0.25)
    t.ok(f"came to {doing}", False, state)
    return state

def page_ready(tab, within=15):
    """The page under the bot, waited for: a snapshot of it holds the page,
    or it isn't there yet (the bot opens over a page still coming in)."""
    end = time.time() + within
    while time.time() < end:
        try:
            if "to read" in cmd({"do": "agent", "action": "snapshot", "id": tab}).get("snapshot", ""):
                return True
        except RuntimeError:
            pass
        time.sleep(0.2)
    return False

def words(seen, what):
    """What the model was shown or told, from the stand-in's record of
    requests — one ask of it for each line of the script."""
    for asked in seen:
        for message in asked.get("messages", []):
            if what in message.get("content", ""):
                return message["content"]
    return ""

def shelve():
    """A skill of the person's own in this world's folder — and a folder
    without a SKILL.md, which is no skill at all."""
    os.makedirs(f"{SUPPORT}/skills/veggies", exist_ok=True)
    open(f"{SUPPORT}/skills/veggies/SKILL.md", "w").write(
        "---\nname: Market Watch\ndescription: Prices from the market stall\n---\nAlways price the leeks before noon.\n")
    os.makedirs(f"{SUPPORT}/skills/junk", exist_ok=True)

def notes_server():
    """The stand-in over pipes, written where this world keeps its files."""
    path = f"{SUPPORT}/notes-server.py"
    os.makedirs(SUPPORT, exist_ok=True)
    open(path, "w").write(NOTES_SERVER)
    return path

def connected(t, name, within=15):
    """A server waited for until it holds its tools — the state a prompt
    needs before it can list them."""
    end = time.time() + within
    state = ""
    while time.time() < end:
        for server in mcp("list").get("servers", []):
            if server.get("name") == name: state = server.get("state", "")
        if "tool" in state: return True
        time.sleep(0.25)
    t.ok(f"{name} came to hold its tools", False, state)
    return False


def case_shelf(t):
    """skills verbs — a SKILL.md found, listed, switched, read"""
    setup(); launch()
    shelve()

    listed = skills("list")
    t.ok("a skill found by its folder, named by its frontmatter",
         listed.get("found") == ["Market Watch"]
         and listed.get("skills") == [{"name": "Market Watch", "description": "Prices from the market stall"}],
         listed)
    t.ok("a folder without a SKILL.md is no skill", "junk" not in listed.get("found", []), listed)

    off = skills("off", name="veggies")
    t.ok("a skill switched off", off.get("on") is False, off)
    listed = skills("list")
    t.ok("an off skill offered to no one", listed.get("skills") == [] and listed.get("found") == ["Market Watch"], listed)

    on = skills("on", name="veggies")
    t.ok("a skill switched back on", on.get("on") is True, on)

    body = skills("read", name="veggies")
    t.ok("a skill's body read, its frontmatter off",
         body.get("body") == "Always price the leeks before noon.", body)


def case_pipes(t):
    """mcp verbs against a stand-in over pipes"""
    setup(); launch()
    path = notes_server()

    added = mcp("add", name="notes", command=sys.executable, args=[path])
    t.ok("a server added by its command", added.get("added") == "notes", added)

    met = mcp("list")
    t.ok("the server listed, on by default",
         len(met.get("servers", [])) == 1 and met["servers"][0]["name"] == "notes"
         and met["servers"][0]["on"] is True, met)

    tools = mcp("tools")
    t.ok("the server's tools listed, qualified by its name",
         any("notes · add_note" in tool for tool in tools.get("tools", []))
         and any("notes · notes" in tool for tool in tools.get("tools", [])), tools)
    t.ok("a tool's description and arguments said with it",
         any("— Keep a note for the person" in tool and '"text":"string"' in tool
             for tool in tools.get("tools", [])), tools)

    kept = mcp("call", tool="notes · add_note", arguments={"text": "lunch"})
    t.ok("a writing tool called", kept.get("text") == "Noted: lunch" and kept.get("failed") is False, kept)
    held = mcp("call", tool="notes · notes")
    t.ok("a reading tool called, saying what was kept", held.get("text") == "lunch", held)

    off = mcp("off", name="notes")
    t.ok("the server switched off", off.get("on") is False, off)
    on = mcp("on", name="notes")
    t.ok("the server switched back on", on.get("on") is True, on)
    # Off, the program was let go of: its notes went with it.
    held = mcp("call", tool="notes · notes")
    t.ok("a program let go of keeps nothing for the next run",
         held.get("text") == "no notes yet", held)

    gone = mcp("remove", name="notes")
    t.ok("the server removed", gone.get("removed") == "notes" and mcp("list").get("servers") == [], gone)


def case_web(t):
    """mcp verbs against a stand-in over HTTP — paged tools, a session id,
    an event-stream answer, and a header of its own wanted at the door"""
    setup(); launch()
    mlog.clear()

    # A server that says nothing at the door is told no — and its state
    # says so plainly.
    bare = mcp("add", name="bare", url=MBASE)
    t.ok("a server added by its address", bare.get("added") == "bare", bare)
    told = mcp("tools")
    bare_state = {k: v for d in told.get("states", []) for k, v in d.items()}.get("bare", "")
    t.ok("a server without its header is told no at the door",
         "401" in bare_state, bare_state)
    gone = mcp("remove", name="bare")
    t.ok("the bare server let go", gone.get("removed") == "bare", gone)
    mlog.clear()

    # One of the headers says it is the session id itself — the one
    # the protocol keeps its bearings by, and never the person's to
    # displace, whatever their settings say.
    added = mcp("add", name="shelf", url=MBASE,
                headers={"Authorization": "Bearer shelf", "Mcp-Session-Id": "an imposter's"})
    t.ok("a server added with headers of its own",
         added.get("added") == "shelf"
         and [d for d in mcp("list").get("servers", []) if d.get("name") == "shelf"][0].get("headers") == 2,
         added)

    tools = mcp("tools")
    t.ok("tools read across pages, by their cursor",
         any("shelf · notes" in tool for tool in tools.get("tools", []))
         and any("shelf · shelve" in tool for tool in tools.get("tools", [])), tools)

    held = mcp("call", tool="shelf · notes")
    t.ok("a call answered as a stream of events, read all the same",
         held.get("text") == "one: brassica", held)

    said = [entry for entry in mlog if entry[0] == "initialize"]
    t.ok("the session id handed out once, at the hello",
         len(said) == 1 and said[0][1] is None, mlog[:2])
    t.ok("the session id kept and said back on every ask after",
         all(entry[1] == "test-session" for entry in mlog[1:]), mlog[1:])
    t.ok("…and a header of the person's own named for it never displaces it",
         all(entry[1] == "test-session" for entry in mlog[1:]), [e[1] for e in mlog[1:]])
    t.ok("the header said with every request, from the hello on",
         all(entry[2] == "Bearer shelf" for entry in mlog), mlog[:3])

    gone = mcp("remove", name="shelf")
    t.ok("the server removed", gone.get("removed") == "shelf" and mcp("list").get("servers") == [], gone)


def case_bot(t):
    """the bot calling a tool, held for allowing, and reading a skill"""
    setup(); launch()
    cmd({"do": "ai", "action": "mock", "url": f"http://127.0.0.1:{srv.server_port}/"})
    shelve()
    path = notes_server()
    mcp("add", name="notes", command=sys.executable, args=[path])
    opened = cmd({"do": "open", "url": f"{BASE}/market"})
    page_ready(opened["id"])
    used = bt("use", provider="ollama")
    t.ok("the bot on, answered locally", used.get("provider") == "ollama", used)
    page = bt("open", id=opened["id"])
    t.ok("the bot opens over the page", page.get("open") is True and not page.get("notice"), page)
    # The bot's coming in is what connects the server: its tools are there
    # to list by the time a task is asked.
    t.ok("the bot's coming in connects the server", connected(t, "notes"))

    script.clear(); seen.clear()
    script.extend([
        '{"tool":{"name":"notes · add_note","arguments":{"text":"buy leeks"}}}',
        '{"answer":"Noted, and priced."}',
    ])
    asked = bt("ask", text="Keep a note to buy leeks")
    t.ok("a question in words goes in", asked.get("open") is True, asked)
    held = until(t, lambda s: s.get("pending", {}).get("verb") == "tool"
                             and "add_note" in s.get("pending", {}).get("target", ""),
                 doing="a tool call held for allowing")
    t.ok("a tool call held for the person's Allow",
         held.get("pending", {}).get("verb") == "tool", held)

    allowed = bt("allow")
    t.ok("the Allow given", allowed.get("pending") in (None, {}, False), allowed)
    done = until(t, lambda s: not s.get("working") and not s.get("pending"), doing="the tool's answer")
    t.ok("the tool's words come back to the model",
         "Noted: buy leeks" in words(seen, "Your tool notes · add_note"), [m.get("content", "")[:120] for a in seen for m in a.get("messages", [])][-3:])
    t.ok("the tools listed for the model in its prompt",
         "notes · add_note" in words(seen, "Beyond the page"), "")
    t.ok("the skills listed for the model in its prompt",
         "Market Watch" in words(seen, "Beyond the page"), "")

    # A skill read: not an act on anything, so held for no one — its words
    # come back to the model, which carries on.
    script.clear(); seen.clear()
    script.extend([
        '{"skill":"Market Watch"}',
        '{"answer":"Before noon, says the skill."}',
    ])
    asked = bt("ask", text="What does the person's market skill say about leeks?")
    until(t, lambda s: not s.get("working") and not s.get("pending"), doing="the skill's answer")
    t.ok("the skill's words read into the next ask",
         "Always price the leeks before noon." in words(seen, "The skill Market Watch"), "")
    t.ok("the answer carried on in words",
         any(event.get("kind", "").find("answer") >= 0 for event in bt("state").get("events", []))
         or words(seen, "Before noon") != "", bt("state").get("events", [])[-2:])


def case_panel(t):
    """the Ask panel calling a tool that only reads"""
    setup(); launch()
    cmd({"do": "ai", "action": "mock", "url": f"http://127.0.0.1:{srv.server_port}/"})
    path = notes_server()
    mcp("add", name="notes", command=sys.executable, args=[path])
    opened = cmd({"do": "open", "url": f"{BASE}/market"})
    page_ready(opened["id"])
    cmd({"do": "ai", "action": "use", "provider": "ollama", "model": "mock"})
    mcp("tools")

    script.clear(); seen.clear()
    script.extend([
        '{"tool":{"name":"notes · notes","arguments":{}}}',
        'Nothing kept yet.',
    ])
    asked = cmd({"do": "ai", "action": "question", "id": opened["id"],
                 "text": "What notes has the person kept?"})
    t.ok("the panel opened on the question", asked.get("open") is True, asked)
    end = time.time() + 30
    turns = []
    while time.time() < end:
        state = cmd({"do": "ai", "action": "state"})
        turns = state.get("turns", [])
        if turns and turns[0].get("done"): break
        time.sleep(0.25)
    t.ok("the panel's answer came, in words",
         turns and turns[0].get("answer") == "Nothing kept yet.", turns)
    t.ok("only the tools that say they read offered to the panel",
         "notes · notes" in words(seen, "Beyond the page you may look things up")
         and "notes · add_note" not in words(seen, "Beyond the page you may look things up"), "")
    t.ok("the tool's words came back into the turn",
         "no notes yet" in words(seen, "The tool notes · notes"), "")


def main():
    t = T()
    for case in [case_shelf, case_pipes, case_web, case_bot, case_panel]:
        print(case.__doc__.strip())
        try: case(t)
        except Exception as e: t.failed += 1; print("  FAIL", case.__name__, e)
        print()
    t.done(); finish()
    sys.exit(1 if t.failed else 0)

if __name__ == "__main__":
    main()
