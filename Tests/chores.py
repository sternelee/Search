#!/usr/bin/env python3
"""The bot's tasks for later, checked through the bench's socket in a hidden
probe.

Build first (`./build.sh` or `./build.sh debug`), then run
`python3 Tests/chores.py`. The app is started hidden in a world of its
own (SEARCH_PROBE=chores-tests-<checkout>, see use()), driven through
./bench's socket, and quit; its settings and files are removed afterwards.
Nothing here makes, shows or brings forward a window.

A task for later is what the bot is asked for over a page at a time to
come (see Chores.swift and Bot.swift): the goal in the model's own words,
noted with the page and the time — and when the time comes, the page
opened again, the bot let loose on it, Auto on. A stand-in model on this
Mac (bench ai-mock) plays the model's part — one line of JSON a request —
while a form of the test's own is the page. Checked here:
  the noting   a task asked for in words, noted: the goal, the page, the
               time — kept waiting, and told the time it is
  the time     a time that can't be read, or one already come: said so,
               and nothing noted
  the run      a task come due: its page opened again, the bot let loose
               on it with Auto on — no act held — to its answer, kept
  the missing  a time that passes with Search closed: missed, not run
  the rounds   a task asked for as one that comes round again ("every ten
               minutes"): the gap kept with it, a round that ends setting
               the next, and a time passed with Search closed skipped to
               the next round, not missed; a gap too small said so
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
use("chores-tests")

FORM = """<!doctype html><html><head><title>sign up</title><style>
body { font: 14px system-ui; margin: 40px } label { display: block; margin-top: 12px }
</style></head><body>
<h1>Try it</h1>
<form id="f">
  <label for="first">First name</label><input id="first" name="first">
  <label for="email">Email</label><input id="email" type="email" name="email">
  <label for="month">Month</label><select id="month" name="month">
    <option>January</option><option>April</option><option>July</option>
    <option>October</option><option>December</option></select>
  <label><input type="checkbox" id="terms"> I agree</label>
  <button type="submit" id="go">Sign up</button>
</form>
<p id="done" hidden></p>
<script>
document.getElementById('f').addEventListener('submit', function (e) {
  e.preventDefault();
  var d = document.getElementById('done');
  d.hidden = false;
  d.textContent = 'Signed up ' + document.getElementById('first').value
    + ' <' + document.getElementById('email').value + '> for '
    + document.getElementById('month').value
    + (document.getElementById('terms').checked ? ', agreed' : '');
  document.getElementById('f').hidden = true;
});
</script></body></html>"""

# The stand-in model: one line of the script a request at a time, in the
# openAI way of streaming, over SSE — the one line of JSON the loop asks of
# the model each time it thinks (see Bot.system). Each request carries all
# that has been said and shown so far.
script = []
seen = []
def said(reply):
    body = json.dumps({"choices": [{"delta": {"content": reply}}]})
    return f"data: {body}\n\ndata: [DONE]\n\n".encode()
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/form":
            body = FORM.encode()
        else:
            body = f"<!doctype html><title>{self.path.strip('/')}</title><p>{self.path}".encode()
        self.send_response(200); self.send_header("Content-Type", "text/html"); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        seen.append(json.loads(self.rfile.read(length) or b"{}"))
        line = script.pop(0) if script else '{"answer":"nothing left in the script"}'
        body = said(line)
        self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
srv = ThreadingHTTPServer(("127.0.0.1", 0), H); threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{srv.server_port}"

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
def chores(action, **fields):
    """One chores verb, the answer as it came, errors included."""
    try:
        return cmd({"do": "chores", "action": action, **fields})
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

def words(seen, what):
    """What the model was shown or told, from the stand-in's record of
    requests — one ask of it for each line of the script."""
    for asked in seen:
        for message in asked.get("messages", []):
            if what in message.get("content", ""):
                return message["content"]
    return ""


def case_list(t):
    """a fresh world holds no tasks for later"""
    setup(); launch()
    listing = chores("list")
    t.ok("no tasks yet", listing.get("tasks") == [], listing)

def case_note(t):
    """a task asked for in words, noted: the goal, the page, the time"""
    setup(); launch()
    cmd({"do": "ai", "action": "mock", "url": f"http://127.0.0.1:{srv.server_port}/"})
    opened = cmd({"do": "open", "url": f"{BASE}/form"})
    used = bt("use", provider="ollama")
    t.ok("the bot on, answered locally", used.get("provider") == "ollama", used)
    page = bt("open", id=opened["id"])
    t.ok("the bot opens over the page", page.get("open") is True and not page.get("notice"), page)

    script.clear(); seen.clear()
    script.extend([
        '{"later":{"goal":"Sign the form up for Ada","at":"2100-01-01T08:00:00+00:00"}}',
    ])
    asked = bt("ask", text="Tomorrow at eight in the morning, sign the form up for Ada")
    t.ok("a question in words goes in", asked.get("open") is True, asked)

    # A task set is a task that will run with no one watching: the setting
    # of it is held for the person's Allow, like anything beyond the page.
    held = until(t, lambda s: (s.get("pending") or {}).get("verb") == "later", doing="the task held for allowing")
    t.ok("the task is held for the person's Allow",
         (held.get("pending") or {}).get("text") == "Sign the form up for Ada", held.get("pending"))
    bt("allow")

    noted = until(t, lambda s: any(e["kind"] == "say" and e["words"].startswith("Noted for")
                                  for e in s.get("events", [])))
    t.ok("the task is noted in the bot's own words",
         any(e["kind"] == "say" and e["words"].startswith("Noted for")
             and "Sign the form up for Ada" in e["words"] for e in noted.get("events", [])), noted.get("events"))
    listing = chores("list")
    tasks = listing.get("tasks", [])
    t.ok("…and kept waiting, with its page and its time",
         len(tasks) == 1 and tasks[0]["goal"] == "Sign the form up for Ada"
         and tasks[0]["page"] == f"{BASE}/form" and tasks[0]["state"] == "waiting"
         and tasks[0]["at"].startswith("2100-01-01T08:00:00"), tasks)
    t.ok("the model was told the time it is", bool(words(seen, "NOW 2")), [m.get("content", "")[:60] for m in seen[-1]["messages"]])

    removed = chores("remove", id=tasks[0]["id"])
    t.ok("a task taken off", removed.get("removed") == tasks[0]["id"]
         and chores("list").get("tasks") == [], removed)

def case_time(t):
    """a time that can't be read, or one already come: said so, nothing noted"""
    setup(); launch()
    cmd({"do": "ai", "action": "mock", "url": f"http://127.0.0.1:{srv.server_port}/"})
    opened = cmd({"do": "open", "url": f"{BASE}/form"})
    bt("use", provider="ollama")
    bt("open", id=opened["id"])

    script.clear(); seen.clear()
    script.extend([
        '{"later":{"goal":"A task with no time to it","at":"whenever"}}',
        '{"answer":"the time it gave couldn\'t be read"}',
        '{"later":{"goal":"A task already late","at":"2000-01-01T08:00:00+00:00"}}',
        '{"answer":"the time it gave had already come"}',
    ])
    bt("ask", text="Do something whenever you like")
    until(t, lambda s: any(e["kind"] == "answer" for e in s.get("events", [])))
    t.ok("a time that couldn't be read was said so",
         bool(words(seen, "That time couldn't be read, or it has already come")), [m.get("content", "")[:60] for m in seen[-1]["messages"]])
    bt("ask", text="Do it in the year 2000")
    until(t, lambda s: len([e for e in s.get("events", []) if e["kind"] == "answer"]) == 2)
    noted = [m for a in seen for m in a.get("messages", [])
              if "That time couldn't be read, or it has already come" in m.get("content", "")]
    t.ok("a time already come was said so the same way", len(noted) >= 2, f"{len(noted)} notes")
    t.ok("no task came of either", chores("list").get("tasks") == [], chores("list"))

def case_run(t):
    """a task come due: its page opened again, the bot let loose on it"""
    setup(); launch()
    cmd({"do": "ai", "action": "mock", "url": f"http://127.0.0.1:{srv.server_port}/"})
    bt("use", provider="ollama")

    # A task set by hand the way the bot's own later line would set it, its
    # time already come: the clock runs it at once.
    at = time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime(time.time() - 5))
    added = chores("add", goal="Sign the form up for Ada, ada@lovelace.dev, for October, agreeing",
                   at=at, page=f"{BASE}/form")
    t.ok("a task set for a time already come", bool(added.get("added")), added)

    script.clear(); seen.clear()
    script.extend([
        '{"say":"I\'ll fill the form in for you"}',
        '{"run": "echo no one is there to allow this"}',
        '{"act":{"verb":"fill","target":"css=#first","text":"Ada"}}',
        '{"act":{"verb":"fill","target":"css=#email","text":"ada@lovelace.dev"}}',
        '{"act":{"verb":"select","target":"css=#month","text":"October"}}',
        '{"act":{"verb":"check","target":"css=#terms"}}',
        '{"act":{"verb":"click","target":"text=Sign up"}}',
        '{"read":"css=#done"}',
        '{"answer":"signed up, as asked"}',
    ])
    ticked = chores("tick")
    t.ok("the clock sees it due", any(s.get("state") == "running" for s in ticked.get("tasks", [])), ticked)

    # The task's page opens behind whatever is in front: the person's front
    # page stays theirs, taken from them by nothing that runs on its own.
    front = [tab for tab in cmd({"do": "tabs"}).get("tabs", []) if tab.get("active")]
    t.ok("the task's page works behind the front page",
         bool(front) and "/form" not in front[0].get("url", ""), front)

    answer = until(t, lambda s: any(e["kind"] == "answer" for e in s.get("events", [])), within=60,
                   doing="the task the clock set the bot on")
    t.ok("the bot worked its page to an answer",
         any(e["kind"] == "answer" and e["words"] == "signed up, as asked" for e in answer.get("events", [])),
         answer.get("events"))
    t.ok("Auto on, no act was held", answer.get("auto") is True and not answer.get("pending"), answer)
    acts = [e for e in answer.get("events", []) if e["kind"] == "act"]
    t.ok("every act went ahead on its own",
         len(acts) == 6 and all(a["act"][3] in ("done", "read") for a in acts), answer.get("events"))
    listing = chores("list")
    tasks = listing.get("tasks", [])
    t.ok("the task came to done, its answer kept",
         len(tasks) == 1 and tasks[0]["state"] == "done" and tasks[0]["words"] == "signed up, as asked", tasks)
    asking = words(seen, "The task the person set for this time")
    t.ok("the model asked the goal, told no one was watching",
         "Sign the form up for Ada" in asking and "No one may be watching" in asking, asking[:160])
    t.ok("…and a command beyond the page was refused, no one there to allow it",
         bool(words(seen, "No one is at the keys to allow a command on this Mac")), "")
    t.ok("…and what it read of the page came back to it",
         bool(words(seen, "Signed up Ada <ada@lovelace.dev> for October, agreed")), "")

    # The person comes back to the panel the task left open and asks for
    # themselves: someone is at the keys again, and what goes beyond the
    # page asks instead of being refused. (Auto turned off first — with it
    # on, the asking stays stopped, as ever.)
    bt("auto", on=False)
    script.clear(); seen.clear()
    script.extend([
        '{"run": "echo someone is here now"}',
        '{"answer": "it asked this time"}',
    ])
    bt("ask", text="Run that for me")
    back = until(t, lambda s: (s.get("pending") or {}).get("verb") == "run",
                 doing="the command held, someone back at the keys")
    t.ok("the person's own ask makes someone be at the keys",
         back.get("unattended") is False, back.get("unattended"))
    bt("refuse")
    until(t, lambda s: any(e["kind"] == "answer" and e["words"] == "it asked this time"
                           for e in s.get("events", [])))

def case_person(t):
    """a task come due that ends where only a person can go on"""
    setup(); launch()
    cmd({"do": "ai", "action": "mock", "url": f"http://127.0.0.1:{srv.server_port}/"})
    bt("use", provider="ollama")

    # A task whose page asks for a password: the bot works it until what's
    # left is only a person's to do, and ends there — not failed, not done.
    at = time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime(time.time() - 5))
    added = chores("add", goal="Sign in and read what's behind it",
                   at=at, page=f"{BASE}/form")
    t.ok("a task set for a time already come", bool(added.get("added")), added)

    script.clear(); seen.clear()
    script.extend([
        '{"say":"the sign-in is in my way"}',
        '{"human":"the sign-in wants its password"}',
    ])
    chores("tick")
    answer = until(t, lambda s: any(e["kind"] == "human" for e in s.get("events", [])), within=60,
                   doing="the task the clock set the bot on")
    t.ok("the bot said where only a person can go on",
         any(e["kind"] == "human" and e["words"] == "the sign-in wants its password"
             for e in answer.get("events", [])), answer.get("events"))
    listing = chores("list")
    tasks = listing.get("tasks", [])
    t.ok("the task waits for the person, not failed and not done",
         len(tasks) == 1 and tasks[0]["state"] == "human"
         and tasks[0]["words"] == "the sign-in wants its password", tasks)
    asking = words(seen, "only a person")
    t.ok("the model was told it can hand it back",
         "a person's to do" in asking, asking[:200])


def case_missing(t):
    """a time that passes with Search closed: missed, not run"""
    setup(); launch()
    at = time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime(time.time() + 3))
    added = chores("add", goal="A task whose time comes while Search is closed",
                   at=at, page=f"{BASE}/form")
    t.ok("a task set for a time to come", any(s.get("state") == "waiting" for s in chores("list").get("tasks", [])), added)

    quit(); time.sleep(4); launch()
    tasks = chores("list").get("tasks", [])
    t.ok("its time came while Search wasn't running: missed, not run",
         len(tasks) == 1 and tasks[0]["state"] == "missed"
         and tasks[0]["words"] == "its time came while Search wasn't running", tasks)


def case_round(t):
    """a task that comes round again: the gap kept, each round sets the next"""
    setup(); launch()
    cmd({"do": "ai", "action": "mock", "url": f"http://127.0.0.1:{srv.server_port}/"})
    opened = cmd({"do": "open", "url": f"{BASE}/form"})
    bt("use", provider="ollama")
    bt("open", id=opened["id"])

    # No time given, only a gap: the first round is one gap from now.
    script.clear(); seen.clear()
    script.extend([
        '{"later":{"goal":"Pull the feed and pick out the AI news","every":600}}',
    ])
    bt("ask", text="Every ten minutes, pull the feed and pick out the AI news")
    # Held for the person's Allow, like any task that will run unseen.
    until(t, lambda s: (s.get("pending") or {}).get("verb") == "later", doing="the task held for allowing")
    bt("allow")
    noted = until(t, lambda s: any(e["kind"] == "say" and e["words"].startswith("Noted for")
                                  for e in s.get("events", [])))
    t.ok("a task with a gap is noted like any other",
         any(e["kind"] == "say" and e["words"].startswith("Noted for")
             and "every 10 min" in e["words"] for e in noted.get("events", [])), noted.get("events"))
    tasks = chores("list").get("tasks", [])
    t.ok("the gap kept, the first round one gap away",
         len(tasks) == 1 and tasks[0]["every"] == 600 and tasks[0]["state"] == "waiting"
         and tasks[0]["at"] > time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(time.time() + 590)), tasks)

    # A round that ends sets the next: the answer kept as this round's words.
    chores("remove", id=tasks[0]["id"])
    at = time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime(time.time() - 5))
    added = chores("add", goal="Pull the feed and pick out the AI news", at=at,
                   page=f"{BASE}/form", every=120)
    t.ok("a round set for a time already come", added.get("every") == 120, added)

    script.clear(); seen.clear()
    script.extend(['{"answer":"three AI stories this round"}'])
    chores("tick")
    answer = until(t, lambda s: any(e["kind"] == "answer" for e in s.get("events", [])), within=60,
                   doing="the round the clock set the bot on")
    t.ok("the round came to its answer",
         any(e["kind"] == "answer" and e["words"] == "three AI stories this round"
             for e in answer.get("events", [])), answer.get("events"))
    asking = words(seen, "The task the person set for this time")
    t.ok("the model told the task comes round, and not to run the next round now",
         "comes round every 2 min" in asking and "next round" in asking, asking[:200])
    tasks = chores("list").get("tasks", [])
    t.ok("the next round set, this round's answer kept",
         len(tasks) == 1 and tasks[0]["every"] == 120 and tasks[0]["state"] == "waiting"
         and tasks[0]["at"] > time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(time.time() + 60))
         and tasks[0]["words"] == "three AI stories this round", tasks)


def case_round_gap(t):
    """a gap too small between rounds: said so, nothing noted"""
    setup(); launch()
    cmd({"do": "ai", "action": "mock", "url": f"http://127.0.0.1:{srv.server_port}/"})
    opened = cmd({"do": "open", "url": f"{BASE}/form"})
    bt("use", provider="ollama")
    bt("open", id=opened["id"])

    script.clear(); seen.clear()
    script.extend([
        '{"later":{"goal":"A task too often","every":30}}',
        '{"answer":"the gap was too small"}',
    ])
    bt("ask", text="Every thirty seconds, do it")
    until(t, lambda s: any(e["kind"] == "answer" for e in s.get("events", [])))
    t.ok("a gap too small was said so",
         bool(words(seen, "That gap between rounds is too small")),
         [m.get("content", "")[:60] for m in seen[-1]["messages"]])
    t.ok("no task came of it", chores("list").get("tasks") == [], chores("list"))


def case_round_missed(t):
    """rounds that find Search closed: skipped to the next, not missed"""
    setup(); launch()
    at = time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime(time.time() + 3))
    chores("add", goal="Pull the feed and pick out the AI news", at=at,
           page=f"{BASE}/form", every=120)
    t.ok("a round set for a time to come",
         any(s.get("every") == 120 and s.get("state") == "waiting"
             for s in chores("list").get("tasks", [])), at)

    quit(); time.sleep(4); launch()
    tasks = chores("list").get("tasks", [])
    t.ok("the rounds that passed with Search closed were skipped to the next",
         len(tasks) == 1 and tasks[0]["state"] == "waiting" and tasks[0]["every"] == 120
         and tasks[0]["at"] > time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(time.time())), tasks)


def main():
    t = T()
    for case in [case_list, case_note, case_time, case_run, case_person, case_missing, case_round, case_round_gap, case_round_missed]:
        print(f"— {case.__doc__}")
        try:
            case(t)
        except Exception as error:
            t.ok(f"{case.__name__} ran to the end", False, error)
        finally:
            finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
