#!/usr/bin/env python3

"""The bot, checked through the bench's socket in a hidden probe.

Build first (`./build.sh` or `./build.sh debug`), then run
`python3 Tests/bot_panel.py`. The app is started hidden in a world of its
own (SEARCH_PROBE=bot-tests-<checkout>, see use()), driven through
./bench's socket, and quit; its settings and files are removed afterwards.
Nothing here makes, shows or brings forward a window.

The bot is the panel a key brings over a page (see Bot.swift): a talk, a
page to work on, and hands. A stand-in model on this Mac (bench ai-mock)
plays the model's part — one line of JSON a request — while a form of the
test's own is the page. Checked here:
  the hands    a task asked in words, carried out act by act — each act
               held for the probe to allow, and refused once, refused well
  the auto     with Auto on, no act waits
  the card     a card drawn (A2UI: native controls, no code), a tap sent
               back to the model as an event
  the notice   a provider off this Mac is asked first, before anything goes
  the every    the bot over every tab (see Bot.Mode): one talk, every tab —
               the tabs listed for the model, a "tab" taken by its id, an
               act on a tab the person isn't on working all the same, and
               the talk kept across switching tabs, one bot only
  the switch  the panel's switch turned mid-talk (see browser.botEverywhere):
               the open bot follows it, the talk kept, the tabs shown or not
               from the next ask on
  the again    the talk held while the panel's away (see Bot.Held): the same
               page takes it up again — shown as it stood, told to the model
               as it stood — another page meets a fresh one, and clear
               empties the talk and holds nothing
  the run      a command run on this Mac (see Bot.shell): held for Allow, the
               command itself shown, and what it printed told back to the model
  the where    where the person has been (see History): read for the asking,
               and words a summary goes by put on the clipboard, held for Allow
  the kept     a thought kept for every talk to come (see Bot.notes): held for
               Allow, kept in the settings, told to every bot from the start —
               and let go of with the trash on the panel
  the coming  the reply coming in (see Loop.wordsComing): plain words shown on
              the panel as they're said, and the say or answer inside a JSON
              line shown while the line is still arriving — carried once whole
  the thinking  a thinking model's thoughts, shown muted as they come, spent
              when the answer is in — never read back to the model
  the stop    a turn stopped midway (see Bot.stop): the reply cut where it is,
              quietly, and nothing of it carried after; an act let go, told so;
              a command stopped with it, stopped where it runs
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
use("bot-tests")

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
# A thought on the way to the next reply, spent once (see case_thought).
thought = []
def said(reply):
    body = json.dumps({"choices": [{"delta": {"content": reply}}]})
    first = ""
    if thought:
        thought_body = json.dumps({"choices": [{"delta": {"content": "", "reasoning": thought.pop()}}]})
        first = f"data: {thought_body}\n\n"
    return f"{first}data: {body}\n\ndata: [DONE]\n\n".encode()
def piece_event(reply):
    # One event of a reply, not the whole of it (see `pieces` below).
    body = json.dumps({"choices": [{"delta": {"content": reply}}]})
    return f"data: {body}\n\n".encode()
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
        # A dict in the script holds the reply back a while, to watch the
        # loop between replies: {"sleep": seconds, "say": line}.
        if isinstance(line, dict) and "sleep" in line: time.sleep(line.get("sleep", 0)); line = line["say"]
        # A reply a piece at a time: {"pieces": ["…", …], "hold": seconds}
        # — one event a piece, held between pieces, so a stream that shows
        # its words as they come can be watched coming (see Bot.drafting).
        if isinstance(line, dict) and "pieces" in line:
            self.send_response(200); self.send_header("Content-Type", "text/event-stream")
            self.send_header("Transfer-Encoding", "chunked"); self.end_headers()
            for piece in line["pieces"]:
                time.sleep(line.get("hold", 0))
                body = piece_event(piece)
                self.wfile.write(f"{len(body):X}\r\n".encode() + body + b"\r\n"); self.wfile.flush()
            time.sleep(line.get("hold", 0))
            done = b"data: [DONE]\n\n"
            self.wfile.write(f"{len(done):X}\r\n".encode() + done + b"\r\n"); self.wfile.flush()
            self.wfile.write(b"0\r\n\r\n"); self.wfile.flush()
            return
        # A dict can also stand a tab's real id in for a stand-in name, so a
        # reply can come for a tab the person isn't on: {"tab_from": url,
        # "say": line} — {tab} in the line becomes tab-a1b2c3, from the
        # TABS listing the model was last shown.
        elif isinstance(line, dict) and "thought" in line:
            thought.append(line["thought"])
            body = said(line["say"])
        elif isinstance(line, dict) and "tab_from" in line:
            real = tab_of(words(seen, "TABS", role="user"), line["tab_from"]) or ""
            body = said(line["say"].replace("{tab}", real))
        else:
            body = said(line)
        self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
srv = ThreadingHTTPServer(("127.0.0.1", 0), H); threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{srv.server_port}"

# The card a scripted model draws: A2UI v0.9 messages, one line of the
# script — a surface made, then a column of a saying and a button.
CARD = [
    {"version": "v0.9", "createSurface": {
        "surfaceId": "card", "catalogId": "https://a2ui.org/specification/v0_9/basic_catalog.json",
        "sendDataModel": True}},
    {"version": "v0.9", "updateComponents": {"surfaceId": "card", "components": [
        {"id": "root", "component": "Column", "children": ["words", "send"]},
        {"id": "words", "component": "Text", "text": "Check this over"},
        {"id": "send", "component": "Button", "child": "sendText",
         "action": {"event": {"name": "send", "context": {"name": {"path": "name"}}}}},
        {"id": "sendText", "component": "Text", "text": "Send it"},
    ]}},
]

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
    while time.time() < end:
        state = bt("state")
        if wanted(state): return state
        time.sleep(0.25)
    t.ok(f"came to {doing}", False, state)
    return state

def form_ready(tab, within=15):
    """The page under the bot, waited for: a snapshot of it holds the
    form, or it isn't there yet (the bot opens over a page still coming
    in, and a snapshot of a page half-loaded holds half a page)."""
    end = time.time() + within
    while time.time() < end:
        try:
            if 'button "Sign up"' in cmd({"do": "agent", "action": "snapshot", "id": tab}).get("snapshot", ""):
                return True
        except RuntimeError:
            pass
        time.sleep(0.2)
    return False

def words(seen, what, role=""):
    """What the model was shown or told, from the stand-in's record of
    requests — one ask of it for each line of the script."""
    for asked in seen:
        for message in asked.get("messages", []):
            if what in message.get("content", "") and (not role or message.get("role") == role):
                return message["content"]
    return ""


def case_hands(t):
    """a task in words, act by act, each held for allowing"""
    setup(); launch()
    cmd({"do": "ai", "action": "mock", "url": f"http://127.0.0.1:{srv.server_port}/"})
    opened = cmd({"do": "open", "url": f"{BASE}/form"})
    form_ready(opened["id"])
    used = bt("use", provider="ollama")
    t.ok("the bot on, answered locally", used.get("provider") == "ollama", used)
    page = bt("open", id=opened["id"])
    t.ok("the bot opens over the page", page.get("open") is True and not page.get("notice"), page)

    script.clear(); seen.clear()
    script.extend([
        '{"say":"I\'ll fill the form in for you"}',
        '{"act":{"verb":"fill","target":"css=#first","text":"Ada"}}',
        '{"act":{"verb":"fill","target":"loc=role:textbox[name=\'Email\']","text":"ada@lovelace.dev"}}',
        '{"act":{"verb":"select","target":"css=#month","text":"October"}}',
        '{"act":{"verb":"check","target":"css=#terms"}}',
        '{"act":{"verb":"click","target":"text=Sign up"}}',
        '{"read":"css=#done"}',
        '{"answer":"signed up, as asked"}',
    ])
    asked = bt("ask", text="Sign the form up for Ada, ada@lovelace.dev, for October, agreeing")
    t.ok("a question in words goes in", asked.get("open") is True, asked)

    held = until(t, lambda s: s.get("pending"))
    t.ok("the first act is held for allowing", held.get("pending", {}).get("verb") == "fill"
         and held.get("pending", {}).get("text") == "Ada", held)
    t.ok("nothing touched the page yet", held.get("pending", {}).get("target") == "css=#first", held)

    # Held in order: the first fill (held above), the email, the month, the
    # box — each allowed — then the click, held last.
    for what in ["the first fill", "the email", "the month", "the box"]:
        until(t, lambda s: s.get("pending"))
        bt("allow")
    done = until(t, lambda s: s.get("pending"))
    t.ok("the click is held too", done.get("pending", {}).get("verb") == "click", done)
    bt("allow")

    answer = until(t, lambda s: any(e["kind"] == "answer" for e in s.get("events", [])))
    t.ok("the task is answered in words",
         any(e["kind"] == "answer" and e["words"] == "signed up, as asked" for e in answer["events"]), answer["events"])
    acts = [e for e in answer["events"] if e["kind"] == "act"]
    t.ok("every act was allowed and done", len(acts) == 6 and all(a["act"][3] in ("done", "read") for a in acts), acts)

    t.ok("the turn is over", answer.get("working") is False and not answer.get("pending"), answer)
    t.ok("the talk is kept for the next ask", answer.get("events", [{}])[0]["kind"] == "ask", answer["events"][:1])

    reading = words(seen, "Signed up Ada <ada@lovelace.dev> for October, agreed")
    t.ok("the model was shown what it read", bool(reading), [m.get("content", "")[:80] for m in seen[-1]["messages"]])
    task = words(seen, "Sign the form up")
    t.ok("…and the page, under the question", "sign up" in task and "textbox" in task, task[:120])

def case_refuse(t):
    """an act refused, refused well"""
    setup(); launch()
    cmd({"do": "ai", "action": "mock", "url": f"http://127.0.0.1:{srv.server_port}/"})
    opened = cmd({"do": "open", "url": f"{BASE}/form"})
    form_ready(opened["id"])
    bt("use", provider="ollama")
    bt("open", id=opened["id"])

    script.clear(); seen.clear()
    script.extend([
        '{"act":{"verb":"fill","target":"css=#first","text":"Ada"}}',
        '{"answer":"could not: the first fill was refused"}',
    ])
    bt("ask", text="Sign the form up for Ada")
    until(t, lambda s: s.get("pending"))
    refused = bt("refuse")
    t.ok("refused, nothing left held", refused.get("pending") is False, refused)
    answer = until(t, lambda s: any(e["kind"] == "answer" for e in s.get("events", [])))
    t.ok("…and told so", any(e["kind"] == "act" and e["act"][3] == "refused" for e in answer["events"]), answer["events"])
    told = words(seen, "refused your fill")
    t.ok("the model was shown the refusal", bool(told), told[:120])
    t.ok("…and answered with what it had",
         any(e["kind"] == "answer" and "refused" in e["words"] for e in answer["events"]), answer["events"])

def case_auto(t):
    """with Auto on, no act waits"""
    setup(); launch()
    cmd({"do": "ai", "action": "mock", "url": f"http://127.0.0.1:{srv.server_port}/"})
    opened = cmd({"do": "open", "url": f"{BASE}/form"})
    form_ready(opened["id"])
    bt("use", provider="ollama")
    bt("open", id=opened["id"])
    auto = bt("auto", on=True)
    t.ok("Auto on", auto.get("auto") is True, auto)

    script.clear(); seen.clear()
    script.extend([
        '{"act":{"verb":"fill","target":"css=#first","text":"Ada"}}',
        '{"act":{"verb":"fill","target":"css=#email","text":"ada@lovelace.dev"}}',
        '{"act":{"verb":"click","target":"text=Sign up"}}',
        '{"answer":"sent"}',
    ])
    bt("ask", text="Sign up for Ada")
    answer = until(t, lambda s: any(e["kind"] == "answer" for e in s.get("events", [])), within=60)
    t.ok("the task ran to its answer",
         any(e["kind"] == "answer" and e["words"] == "sent" for e in answer["events"]), answer["events"])
    t.ok("…without holding a single act", not answer.get("pending")
         and all(a["act"][3] == "done" for a in answer["events"] if a["kind"] == "act"), answer["events"])

def case_card(t):
    """a card drawn, a tap sent back as an event"""
    setup(); launch()
    cmd({"do": "ai", "action": "mock", "url": f"http://127.0.0.1:{srv.server_port}/"})
    opened = cmd({"do": "open", "url": f"{BASE}/form"})
    form_ready(opened["id"])
    bt("use", provider="ollama")
    bt("open", id=opened["id"])

    script.clear(); seen.clear()
    script.extend([
        '{"say":"Here is a card to check over"}',
        json.dumps({"ui": CARD}),
        '{"answer":"sent it, as asked"}',
    ])
    bt("ask", text="Send it for Grace")
    card = until(t, lambda s: s.get("surfaces"))
    t.ok("a card is drawn", card.get("surfaces") == ["card"], card)
    t.ok("…and the turn ends on it", card.get("working") is False, card)

    tap = bt("tap", name="send", context={"name": "Grace"})
    t.ok("a tap goes to the model", tap.get("tapped") == "send" and tap.get("working") is True, tap)
    answer = until(t, lambda s: any(e["kind"] == "answer" for e in s.get("events", [])))
    t.ok("…and comes back an answer",
         any(e["kind"] == "answer" and e["words"] == "sent it, as asked" for e in answer["events"]), answer["events"])
    t.ok("…and the card, answered, goes",
         answer.get("surfaces") == [], answer.get("surfaces"))
    sent = words(seen, '"tap"')
    t.ok("the tap was an event, never code", "Grace" in sent and "tap" in sent, sent)

def case_coming(t):
    """the reply coming in: words shown as they're said"""
    setup(); launch()
    cmd({"do": "ai", "action": "mock", "url": f"http://127.0.0.1:{srv.server_port}/"})
    opened = cmd({"do": "open", "url": f"{BASE}/form"})
    form_ready(opened["id"])
    bt("use", provider="ollama")
    bt("open", id=opened["id"])

    # A saying a piece at a time, held a while between pieces: the draft
    # grows on the panel while the turn is still working.
    script.clear(); seen.clear()
    script.extend([{"pieces": ["I'll look ", "at the page ", "and fill it in."],
                    "hold": 0.3}])
    bt("ask", text="Sign the form up for Ada")
    mid = until(t, lambda s: s.get("draft") == "I'll look ", within=8,
               doing="the saying grown as it came")
    t.ok("words are shown as they're said", mid.get("draft") == "I'll look ", mid.get("draft"))
    t.ok("…while the turn is still working", mid.get("working") is True, mid)
    grown = until(t, lambda s: s.get("draft") == "I'll look at the page and fill it in.", within=8,
                doing="the saying grown whole")
    t.ok("the saying grows, it doesn't pile up",
         grown.get("draft") == "I'll look at the page and fill it in.", grown.get("draft"))
    # The whole line is one reply (the pieces joined), so the loop takes it
    # as its saying — said once, not once a piece.
    answer = until(t, lambda s: any(e["kind"] == "say" for e in s.get("events", [])))
    t.ok("the saying stands once, whole",
         [e["words"] for e in answer["events"] if e["kind"] == "say"] == ["I'll look at the page and fill it in."],
         answer["events"])
    t.ok("…and the draft is gone with it", answer.get("draft") == "", answer.get("draft"))

    # A JSON line a piece at a time: the say inside it is shown as it
    # comes — half a line isn't shown, but its words are — and the whole
    # of it is carried once, standing in the talk as one saying.
    script.clear(); seen.clear()
    script.extend([{"pieces": ['{"say":', '"On it"}'], "hold": 0.3}])
    bt("ask", text="Go on then")
    mid = until(t, lambda s: s.get("draft") == "On it", within=8,
               doing="the words inside the line, shown as they came")
    t.ok("the say inside a JSON line is shown as it comes", mid.get("draft") == "On it", mid.get("draft"))
    t.ok("…while the turn is still working", mid.get("working") is True, mid)
    held = until(t, lambda s: any(e["kind"] == "say" and e["words"] == "On it" for e in s.get("events", [])))
    said = [e["words"] for e in held["events"][held["events"].index(next(e for e in held["events"] if e["kind"] == "ask" and e["words"] == "Go on then")):]
            if e["kind"] == "say"]
    t.ok("…and the line, carried whole, is said once", said == ["On it"], held["events"])


def case_again(t):
    """the talk held while the panel's away: the same page meets it again"""
    setup(); launch()
    cmd({"do": "ai", "action": "mock", "url": f"http://127.0.0.1:{srv.server_port}/"})
    opened = cmd({"do": "open", "url": f"{BASE}/form"})
    form_ready(opened["id"])
    bt("use", provider="ollama")
    bt("open", id=opened["id"])

    # A word said, the panel closed — then asked for again over the same
    # page: the talk is taken up, not a fresh one.
    script.clear(); seen.clear()
    script.append('{"say":"The page is up"}')
    bt("ask", text="Is the page up?")
    until(t, lambda s: any(e["kind"] == "say" and e["words"] == "The page is up" for e in s.get("events", [])))
    shut = bt("close")
    t.ok("the panel closes", shut.get("open") is False, shut)
    bt("open", id=opened["id"])
    back = bt("state")
    # (The loop asked on after its saying, and the empty script answered —
    # the talk stands as it stood, that asking included.)
    t.ok("the talk is taken up again — shown as it stood",
         [(e["kind"], e["words"]) for e in back["events"][:2]] == [("ask", "Is the page up?"), ("say", "The page is up")],
         back["events"])

    # And the model is told what it was told: the ask that follows carries
    # the talk that went before it.
    mark = len(seen)
    script.append('{"say":"And so it is"}')
    bt("ask", text="Say it again")
    until(t, lambda s: any(e["kind"] == "say" and e["words"] == "And so it is" for e in s.get("events", [])))
    t.ok("the model is told what it was told — the talk goes on",
         words(seen[mark:], "The page is up", role="assistant") != "", seen[mark:])

    # Another page meets a fresh talk — and the first page's waits for it.
    second = cmd({"do": "open", "url": f"{BASE}/form"})
    form_ready(second["id"])
    bt("open", id=second["id"])
    fresh = bt("state")
    t.ok("another page, another talk: nothing held for it", fresh["events"] == [], fresh["events"])
    cmd({"do": "select", "id": opened["id"]})
    bt("open", id=opened["id"])
    waiting = bt("state")
    t.ok("the first page's talk waited for it",
         any(e["kind"] == "say" and e["words"] == "And so it is" for e in waiting["events"]), waiting["events"])

    # Cleared by hand: the panel empties, and nothing is held for the
    # page — the next panel over it starts from nothing.
    gone = bt("clear")
    t.ok("clear empties the talk, the panel staying", gone.get("events") == 0 and gone.get("open") is True, gone)
    bt("close")
    bt("open", id=opened["id"])
    after = bt("state")
    t.ok("…and holds nothing for the page", after["events"] == [], after["events"])


def case_run(t):
    """a command run on this Mac: held for Allow, its telling goes back"""
    setup(); launch()
    cmd({"do": "ai", "action": "mock", "url": f"http://127.0.0.1:{srv.server_port}/"})
    opened = cmd({"do": "open", "url": f"{BASE}/form"})
    form_ready(opened["id"])
    bt("use", provider="ollama")
    bt("open", id=opened["id"])

    # A command asked for: it waits for the person's Allow, the command
    # itself shown — never run in the dark.
    script.clear(); seen.clear()
    script.append('{"run": "echo shell-said-hi"}')
    bt("ask", text="Say hi through the shell")
    held = until(t, lambda s: s.get("pending", {}).get("verb") == "run")
    t.ok("the command waits for Allow — the command itself shown",
         held.get("pending", {}).get("text") == "echo shell-said-hi", held.get("pending"))
    # (the answer queued before it's let go: the loop asks again the
    # moment the command is done)
    script.append('{"answer": "It said hi"}')
    bt("allow")
    until(t, lambda s: any(e["kind"] == "answer" and e["words"] == "It said hi" for e in s.get("events", [])))
    t.ok("what the command printed goes back to the model",
         words(seen, "shell-said-hi", role="user") != "", seen[-1] if seen else {})
    ran = bt("state")
    t.ok("…and it is on the act, to read",
         any(e["kind"] == "act" and e["act"][0] == "run" and "shell-said-hi" in e["act"][4]
             for e in ran.get("events", [])), ran.get("events"))


def case_where(t):
    """where the person has been: read for the asking, copied for the sharing"""
    setup(); launch()
    cmd({"do": "ai", "action": "mock", "url": f"http://127.0.0.1:{srv.server_port}/"})
    opened = cmd({"do": "open", "url": f"{BASE}/form"})
    form_ready(opened["id"])
    bt("use", provider="ollama")
    bt("open", id=opened["id"])

    # Where the person has been: a read of the person's own going-about,
    # held for their Allow like anything beyond the page — and the telling
    # goes back to the model. (The listing itself is empty here: pages
    # the bench opens stay out of the history by design — Browser's
    # record is skipped for them — so it's the asking that's checked,
    # not the pages.)
    script.clear(); seen.clear()
    script.append('{"history": 5}')
    bt("ask", text="Where have I been?")
    until(t, lambda s: (s.get("pending") or {}).get("verb") == "history", doing="the history held for allowing")
    bt("allow")
    until(t, lambda s: words(seen, "Where the person has been", role="user") != "")
    telling = words(seen, "Where the person has been", role="user")
    t.ok("where the person has been is read with the person's Allow, and told",
         "most recent first" in telling, telling[:120])
    # The turn runs on to its answer after the telling; the next ask waits
    # for it, or the ask is dropped on a busy loop.
    until(t, lambda s: not s.get("working"))

    # A summary shared out of the browser: words to the clipboard, held
    # for the person's Allow.
    script.append('{"copy": "been around, it says"}')
    bt("ask", text="Copy that up")
    until(t, lambda s: s.get("pending", {}).get("verb") == "copy")
    bt("allow")
    after = until(t, lambda s: s.get("clipboard") == "been around, it says")
    t.ok("the words land on the clipboard", after.get("clipboard") == "been around, it says")


def case_kept(t):
    """a thought kept: every talk to come is told it, whatever page"""
    setup(); launch()
    cmd({"do": "ai", "action": "mock", "url": f"http://127.0.0.1:{srv.server_port}/"})
    opened = cmd({"do": "open", "url": f"{BASE}/form"})
    form_ready(opened["id"])
    bt("use", provider="ollama")
    bt("open", id=opened["id"])
    bt("forget")

    # A thought kept: held for Allow first, like anything beyond the page.
    script.clear(); seen.clear()
    script.append('{"note": "The person prefers dark mode"}')
    bt("ask", text="Keep this: I prefer dark mode")
    until(t, lambda s: s.get("pending", {}).get("verb") == "note")
    script.append('{"answer": "Kept"}')
    bt("allow")
    until(t, lambda s: any(e["kind"] == "answer" and e["words"] == "Kept" for e in s.get("events", [])))
    t.ok("what's kept is kept", bt("state").get("notes") == ["The person prefers dark mode"], bt("state").get("notes"))

    # Another page, another talk: told from the start.
    second = cmd({"do": "open", "url": f"{BASE}/form"})
    form_ready(second["id"])
    bt("open", id=second["id"])
    mark = len(seen)
    script.append('{"answer": "dark mode"}')
    bt("ask", text="What do I prefer?")
    until(t, lambda s: any(e["kind"] == "answer" and e["words"] == "dark mode" for e in s.get("events", [])))
    t.ok("every talk is told what's kept, from the start",
         words(seen[mark:], "The person prefers dark mode", role="system") != "", seen[mark:] if seen[mark:] else {})

    # And let go of with the trash on the panel, that's to say.
    bt("clear")
    t.ok("…and let go of with the trash", bt("state").get("notes") == [], bt("state").get("notes"))


def case_wrapped(t):
    """a model that talks around its answer: still heard — and the loop said"""
    setup(); launch()
    cmd({"do": "ai", "action": "mock", "url": f"http://127.0.0.1:{srv.server_port}/"})
    opened = cmd({"do": "open", "url": f"{BASE}/form"})
    form_ready(opened["id"])
    bt("use", provider="ollama")
    bt("open", id=opened["id"])

    script.clear(); seen.clear()
    script.extend([
        "I'll have a look at the page and sign them up.",                       # words only: out of shape
        {"sleep": 1.2, "say": 'Sure — here goes:\n```json\n{"say":"On it"}\n```'},   # fenced: still heard
        {"sleep": 1.2, "say": 'All done: {"answer":"signed up"}'},             # wrapped in words: still heard
    ])
    asked = bt("ask", text="Sign the form up for Ada")
    t.ok("a question in words goes in", asked.get("open") is True, asked)

    # The loop is said, not silent: while an ask is out, the panel says
    # what it's doing in place of a bare "working…", and the out-of-shape
    # reply is told to the model rather than dropped without a word.
    asking = until(t, lambda s: s.get("status"))
    t.ok("the panel says what the loop is doing", "asking" in asking.get("status", ""), asking.get("status"))
    t.ok("…while the turn keeps working", asking.get("working") is True, asking)

    answer = until(t, lambda s: any(e["kind"] == "answer" for e in s.get("events", [])))
    t.ok("the model's words are shown even out of shape",
         any(e["kind"] == "say" and e["words"] == "I'll have a look at the page and sign them up."
            for e in answer["events"]), answer["events"])
    t.ok("a fenced reply is still heard",
         any(e["kind"] == "say" and e["words"] == "On it" for e in answer["events"]), answer["events"])
    t.ok("…and one wrapped in words",
         any(e["kind"] == "answer" and e["words"] == "signed up" for e in answer["events"]), answer["events"])
    told = words(seen, "wasn't JSON")
    t.ok("an out-of-shape reply is said, not dropped silently",
         bool(told), [m.get("content", "")[:60] for asked in seen for m in asked.get("messages", []) if m.get("role") == "user"])
    t.ok("the turn is over, the saying gone with it",
         answer.get("working") is False and not answer.get("status"), answer)


def case_notice(t):
    """a provider off this Mac is asked first"""
    setup(); launch()
    cmd({"do": "ai", "action": "mock", "url": f"http://127.0.0.1:{srv.server_port}/"})
    cmd({"do": "ai", "action": "key", "provider": "openAI", "key": "a made-up key"})
    opened = cmd({"do": "open", "url": f"{BASE}/form"})
    form_ready(opened["id"])
    bt("use", provider="openAI")
    bt("open", id=opened["id"])

    script.clear(); seen.clear()
    script.extend(['{"answer":"done"}'])
    bt("ask", text="What does this page hold?")
    state = until(t, lambda s: s.get("notice"))
    t.ok("nothing goes before it's agreed to", state.get("notice") and not state.get("working"), state)
    t.ok("…and it says where words go", "127.0.0.1" in state.get("notice", ""), state["notice"])
    seen.clear()
    agreed = bt("agree")
    answer = until(t, lambda s: any(e["kind"] == "answer" for e in s.get("events", [])))
    t.ok("agreed once, it carries on", agreed.get("open") is True
         and any(e["kind"] == "answer" for e in answer["events"]), answer["events"])


def case_always(t):
    """an Always on a held act: allowed now, and never asked again"""
    setup(); launch()
    cmd({"do": "ai", "action": "mock", "url": f"http://127.0.0.1:{srv.server_port}/"})
    opened = cmd({"do": "open", "url": f"{BASE}/form"})
    form_ready(opened["id"])
    bt("use", provider="ollama")
    bt("open", id=opened["id"])

    script.clear(); seen.clear()
    script.extend([
        '{"act":{"verb":"fill","target":"css=#first","text":"Ada"}}',
        '{"act":{"verb":"fill","target":"css=#email","text":"ada@lovelace.dev"}}',
        '{"act":{"verb":"click","target":"text=Sign up"}}',
        '{"answer":"sent"}',
    ])
    bt("ask", text="Sign up for Ada")
    until(t, lambda s: s.get("pending"))
    allowed = bt("always")
    t.ok("allowed, and the page's acts asked no more",
         allowed.get("pending") is False and allowed.get("always") is True, allowed)
    answer = until(t, lambda s: any(e["kind"] == "answer" for e in s.get("events", [])), within=60)
    t.ok("the task ran to its answer",
         any(e["kind"] == "answer" and e["words"] == "sent" for e in answer["events"]), answer["events"])
    acts = [e for e in answer["events"] if e["kind"] == "act"]
    t.ok("…and nothing after it was held",
         not answer.get("pending") and len(acts) == 3 and all(a["act"][3] in ("done", "read") for a in acts), answer["events"])

    # An Always covers the page's own acts, and nothing beyond it: a
    # command still asks, Always or no.
    script.clear(); seen.clear()
    script.extend([
        '{"run": "echo still asking"}',
        '{"answer": "it still asks"}',
    ])
    bt("ask", text="Run that again")
    until(t, lambda s: (s.get("pending") or {}).get("verb") == "run", doing="the command still held after an Always")
    refused = bt("refuse")
    t.ok("a command beyond the page still asks after an Always", refused.get("pending") is False, refused)
    until(t, lambda s: any(e["kind"] == "answer" and e["words"] == "it still asks" for e in s.get("events", [])))


def tab_here(id):
    """Whether a tab stands in the row, by its bench id."""
    return any(tab["id"] == id for tab in cmd({"do": "tabs"}).get("tabs", []))

def case_close(t):
    """a tab closed at the model's asking: held for the person — always,
    even under Auto, for a tab is the person's own to close"""
    setup(); launch()
    cmd({"do": "ai", "action": "mock", "url": f"http://127.0.0.1:{srv.server_port}/"})
    opened = cmd({"do": "open", "url": f"{BASE}/form"})
    form_ready(opened["id"])
    bt("use", provider="ollama")
    bt("open", id=opened["id"])

    # Refused: the tab stays.
    script.clear(); seen.clear()
    script.extend([
        '{"close": "this"}',
        '{"answer": "kept it, then"}',
    ])
    bt("ask", text="Close this tab")
    until(t, lambda s: (s.get("pending") or {}).get("verb") == "close", doing="the close held for allowing")
    bt("refuse")
    until(t, lambda s: any(e["kind"] == "answer" and e["words"] == "kept it, then" for e in s.get("events", [])))
    t.ok("refused, the tab stays", tab_here(opened["id"]))

    # Auto on: still held — the one act Auto doesn't skip.
    bt("auto", on=True)
    script.clear(); seen.clear()
    script.append('{"close": "this"}')
    bt("ask", text="Close it now")
    still = until(t, lambda s: (s.get("pending") or {}).get("verb") == "close", doing="the close held under Auto")
    t.ok("Auto doesn't skip a close", (still.get("pending") or {}).get("verb") == "close", still.get("pending"))
    bt("allow")
    # Closing its own page takes the panel with it — the tab itself is
    # what there is to see.
    until(t, lambda s: not tab_here(opened["id"]), doing="the tab to close")
    t.ok("allowed, the tab closes", not tab_here(opened["id"]))


def tab_of(listing, url):
    """A tab's id, taken from the TABS listing the model was shown — the
    first whose address holds the url."""
    for line in listing.splitlines():
        if url in line:
            return line.split(" · ")[0].strip()
    return None


def last_shown(records):
    """What the model was last shown: the newest user message of the newest
    ask. The talk it carries counts too — a listing from an earlier turn
    stays in the history — so only the fresh showing is asked."""
    for asked in reversed(records):
        for message in reversed(asked.get("messages", [])):
            if message.get("role") == "user":
                return message.get("content", "")
    return ""


def case_every(t):
    """the bot over every tab: one talk, every tab"""
    setup(); launch()
    cmd({"do": "ai", "action": "mock", "url": f"http://127.0.0.1:{srv.server_port}/"})
    first = cmd({"do": "open", "url": f"{BASE}/form"})
    second = cmd({"do": "open", "url": f"{BASE}/other"})
    form_ready(first["id"])
    bt("use", provider="ollama")

    # Opened over every tab, on the second one.
    opened = bt("open", id=second["id"], every=True)
    t.ok("the bot opens over every tab", opened.get("open") is True and opened.get("every") is True, opened)

    script.clear(); seen.clear()
    script.extend([
        '{"say":"I see two tabs; I\'ll fill the form in on the first"}',
        {"tab_from": f"{BASE}/form",
         "say": '{"act":{"verb":"fill","tab":"{tab}","target":"css=#first","text":"Ada"}}'},
        # The answer the turn comes to once the act is let go — loaded
        # before, for the loop asks the model again the moment it is.
        '{"answer":"filled in on the other tab, as asked"}',
    ])
    bt("ask", text="Fill in the form on the other tab, for Ada")
    held = until(t, lambda s: s.get("pending"))
    t.ok("an act on a tab the person isn't on is held like any other",
         held.get("pending", {}).get("verb") == "fill" and held.get("pending", {}).get("text") == "Ada", held)
    listing = words(seen, "TABS", role="user")
    real = tab_of(listing, f"{BASE}/form")
    t.ok("…and it says which tab it was held on",
         real and held.get("pending", {}).get("tab") == real, held.get("pending", {}))
    t.ok("the model was shown every tab, with the one it's on now marked",
         "tab-" in listing and "the page you're shown" in listing and "/form" in listing and "/other" in listing,
         listing[:200])
    t.ok("…and the page it's on, as ever", "sign up" in listing, listing[:300])

    # A held act let go: it goes to the tab it was held on — the first one —
    # not the one the person is on.
    before = len(bt("state").get("events", []))
    bt("allow")
    answer = until(t, lambda s: len(s.get("events", [])) > before
                   and any(e["kind"] == "act" and e["act"][3] == "done"
                          for e in s.get("events", [])[before:]))
    t.ok("an act on another tab works all the same",
         any(e["kind"] == "act" and e["act"][1] == "css=#first" and e["act"][3] == "done"
            for e in answer["events"][before:]),
         answer["events"])
    # The act is done before the page is shown again for it — poll for the
    # telling itself, not the act, or the two can be read apart.
    until(t, lambda s: words(seen, "Your fill on css=#first came out done") != "")
    fill = words(seen, "Your fill on css=#first came out done")
    t.ok("…and what came of it goes back with the next showing", bool(fill), fill[:120])
    answered = until(t, lambda s: any(e["kind"] == "answer" and e["words"] == "filled in on the other tab, as asked"
                                      for e in s.get("events", [])[before:]))
    t.ok("the turn comes to its answer",
         any(e["kind"] == "answer" and e["words"] == "filled in on the other tab, as asked"
            for e in answered["events"]),
         answered["events"])

    # The talk kept across switching tabs — and one bot only, wherever you go.
    cmd({"do": "select", "id": first["id"]})
    state = bt("state")
    t.ok("switching tabs keeps the bot, and its talk",
         state.get("open") is True and state.get("every") is True
         and any(e["kind"] == "answer" and e["words"] == "filled in on the other tab, as asked"
                for e in state.get("events", [])), state.get("events"))
    t.ok("…and the tabs are listed again, the other one now the one shown",
         "the page you're shown" in words(seen, "TABS", role="user"), "")

    # A tab id that isn't one: said so, nothing done.
    script.clear(); seen.clear()
    script.extend([
        '{"act":{"verb":"fill","tab":"tab-nothing","target":"css=#first","text":"Ada"}}',
        '{"answer":"no tab of that name"}',
    ])
    bt("ask", text="Fill the form on tab-nothing")
    fresh = len(bt("state").get("events", []))
    answer = until(t, lambda s: any(e["kind"] == "answer" and e["words"] == "no tab of that name"
                                   for e in s.get("events", [])[fresh:]))
    t.ok("a tab that isn't one is said so",
         any(e["kind"] == "answer" and e["words"] == "no tab of that name" for e in answer["events"]),
         answer["events"])
    t.ok("…and nothing was done", not any(e["kind"] == "act" for e in answer["events"][fresh:]),
         answer["events"][fresh:])


def case_page_kept(t):
    """the bot on this page: switching tabs puts it away, as ever"""
    setup(); launch()
    cmd({"do": "ai", "action": "mock", "url": f"http://127.0.0.1:{srv.server_port}/"})
    first = cmd({"do": "open", "url": f"{BASE}/form"})
    second = cmd({"do": "open", "url": f"{BASE}/other"})
    form_ready(first["id"])
    bt("use", provider="ollama")
    opened = bt("open", id=first["id"])
    t.ok("the bot opens on this page", opened.get("open") is True and opened.get("every") is False, opened)
    script.clear(); seen.clear()
    script.extend(['{"answer":"a page, as ever"}'])
    bt("ask", text="What is this?")
    until(t, lambda s: any(e["kind"] == "answer" for e in s.get("events", [])))
    t.ok("the model wasn't shown the tabs", not words(seen, "TABS", role="user"), "")

    cmd({"do": "select", "id": second["id"]})
    state = bt("state")
    t.ok("switching tabs puts the page's bot away, as ever", state.get("open") is False, state)


def case_switched(t):
    """the switch turned mid-talk: the open bot follows it"""
    setup(); launch()
    cmd({"do": "ai", "action": "mock", "url": f"http://127.0.0.1:{srv.server_port}/"})
    first = cmd({"do": "open", "url": f"{BASE}/form"})
    second = cmd({"do": "open", "url": f"{BASE}/other"})
    form_ready(first["id"])
    bt("use", provider="ollama")
    opened = bt("open", id=first["id"])
    t.ok("the bot opens on this page", opened.get("open") is True and opened.get("every") is False, opened)
    script.clear(); seen.clear()
    script.extend(['{"answer":"a page"}'])
    bt("ask", text="What is this?")
    until(t, lambda s: any(e["kind"] == "answer" for e in s.get("events", [])))
    t.ok("the model wasn't shown the tabs", not words(seen, "TABS", role="user"), "")

    # Turned to every tab, mid-talk: the same bot, the same talk — the next
    # ask is for every tab.
    switched = bt("every", on=True)
    state = bt("state")
    t.ok("the open bot follows the switch",
         switched.get("every") is True and state.get("every") is True, (switched, state))
    t.ok("…and the talk it already had is kept",
         any(e["kind"] == "answer" and e["words"] == "a page" for e in state.get("events", [])),
         state.get("events"))
    script.clear(); seen.clear()
    script.extend(['{"answer":"every tab now"}'])
    bt("ask", text="And now?")
    until(t, lambda s: any(e["kind"] == "answer" and e["words"] == "every tab now" for e in s.get("events", [])))
    t.ok("the next ask shows the tabs", "the page you're shown" in last_shown(seen), last_shown(seen)[:120])

    # And back to this one page: the tabs go from the asking again, and a
    # switch of tabs puts it away, as ever.
    back = bt("every", on=False)
    t.ok("and back to this page", back.get("every") is False, back)
    script.clear(); seen.clear()
    script.extend(['{"answer":"just this again"}'])
    bt("ask", text="What about now?")
    until(t, lambda s: any(e["kind"] == "answer" and e["words"] == "just this again" for e in s.get("events", [])))
    t.ok("the tabs aren't shown again", "TABS" not in last_shown(seen), last_shown(seen)[:120])
    cmd({"do": "select", "id": second["id"]})
    t.ok("switching tabs puts it away, as ever", bt("state").get("open") is False, bt("state"))


def case_thought(t):
    """a thinking model's thoughts: shown as they come, muted, over the answer
    they were on the way to — and never read back to the model"""
    setup(); launch()
    cmd({"do": "ai", "action": "mock", "url": f"http://127.0.0.1:{srv.server_port}/"})
    opened = cmd({"do": "open", "url": f"{BASE}/form"})
    form_ready(opened["id"])
    bt("use", provider="ollama")
    bt("open", id=opened["id"])

    script.clear(); seen.clear(); thought.clear()
    script.append({"thought": "Weighing the page over.",
                   "say": '{"answer": "thought it over and answered"}'})
    bt("ask", text="Think first")
    answer = until(t, lambda s: any(e["kind"] == "answer" and e["words"] == "thought it over and answered"
                                    for e in s.get("events", [])))
    kinds = [e["kind"] for e in answer["events"] if e["kind"] in ("think", "answer")]
    t.ok("a thought comes before the answer, as its own entry", kinds == ["think", "answer"], answer["events"])
    t.ok("…with the words it was thought in",
         any(e["kind"] == "think" and "Weighing" in e["words"] for e in answer["events"]), answer["events"])

    script.clear(); seen.clear()
    script.append('{"answer": "a second answer"}')
    bt("ask", text="And again")
    until(t, lambda s: any(e["kind"] == "answer" and e["words"] == "a second answer"
                           for e in s.get("events", [])))
    asked = seen[-1] if seen else {"messages": []}
    t.ok("the thought is never read back to the model",
         "Weighing" not in json.dumps(asked), asked.get("messages", []))
    t.ok("the answer is what follows",
         any(m.get("role") == "assistant" and "thought it over" in m.get("content", "")
             for m in asked.get("messages", [])), asked.get("messages", []))

def case_stop(t):
    """a turn stopped midway: the reply cut where it is, quietly, and
    nothing of it carried after; an act held, stopped: let go and told so"""
    setup(); launch()
    cmd({"do": "ai", "action": "mock", "url": f"http://127.0.0.1:{srv.server_port}/"})
    opened = cmd({"do": "open", "url": f"{BASE}/form"})
    form_ready(opened["id"])
    bt("use", provider="ollama")
    bt("open", id=opened["id"])

    # A reply a piece at a time, held a while between pieces: the panel has
    # a saying to cut midway.
    script.clear(); seen.clear()
    script.extend([{"pieces": ['{"answer": "A saying cut before', ' it is done"}'],
                    "hold": 0.6}])
    bt("ask", text="Say something long")
    until(t, lambda s: bool(s.get("draft")), within=10, doing="the saying coming")
    t.ok("the stop is offered while it works", bt("state").get("busy") is True)

    stopped = bt("stop")
    t.ok("the turn is stopped", stopped.get("working") is False and not stopped.get("pending"), stopped)
    t.ok("…and the stop goes with it", stopped.get("busy") is False, stopped)
    after = bt("state")
    t.ok("…the saying it had come to is gone", after.get("draft") == "", after.get("draft"))
    t.ok("…and the cut is no trouble", after.get("trouble") == "", after.get("trouble"))
    had = len(after.get("events", []))

    # The pieces it would have gone on said come and go: none of them is
    # carried, and the turn is not asked again.
    time.sleep(2.0)
    later = bt("state")
    t.ok("…and nothing of the reply comes after the stop",
         len(later.get("events", [])) == had
         and not any(e["kind"] == "answer" for e in later.get("events", [])), later.get("events"))
    t.ok("…nor is the turn taken up again", later.get("working") is False, later)

    # An act held for allowing, and the person stops instead: let go, told
    # so, and nothing done after it.
    script.clear(); seen.clear()
    script.append('{"act":{"verb":"fill","target":"css=#first","text":"Ada"}}')
    bt("ask", text="Fill the name in")
    held = until(t, lambda s: s.get("pending"))
    t.ok("an act waits to be allowed", held.get("pending", {}).get("verb") == "fill", held)
    let = bt("stop")
    t.ok("…stopped, the act is let go", let.get("pending") is False, let)
    t.ok("…and the letting go is told", "let go" in let.get("trouble", ""), let)
    let_go = bt("state")
    t.ok("…with no act done after it",
         not any(e["kind"] == "act" for e in let_go.get("events", [])), let_go.get("events"))
    bt("close")


def case_kill(t):
    """a command stopped with the turn: stopped where it runs, not left
    to finish its work"""
    setup(); launch()
    cmd({"do": "ai", "action": "mock", "url": f"http://127.0.0.1:{srv.server_port}/"})
    opened = cmd({"do": "open", "url": f"{BASE}/form"})
    form_ready(opened["id"])
    bt("use", provider="ollama")
    bt("open", id=opened["id"])

    # A command that writes its proof only if it is left to finish.
    proof = f"/tmp/search-stop-{uuid.uuid4().hex}.txt"
    script.clear(); seen.clear()
    script.append(json.dumps({"run": f"sleep 3; touch {proof}"}))
    bt("ask", text="Run a slow command")
    held = until(t, lambda s: s.get("pending"))
    t.ok("the command waits for Allow", held.get("pending", {}).get("verb") == "run", held)
    bt("allow")
    until(t, lambda s: s.get("status", "").startswith("running"), within=10,
          doing="the command running")
    bt("stop")
    time.sleep(4.0)
    t.ok("a command stopped with the turn doesn't finish its work", not os.path.exists(proof))
    t.ok("…and nothing of it is told after", bt("state").get("status") == "", bt("state"))


def main():
    t = T()
    for case in [case_hands, case_refuse, case_auto, case_always, case_close, case_card, case_coming, case_again, case_run, case_where, case_kept, case_wrapped, case_notice, case_every, case_switched, case_page_kept, case_thought, case_stop, case_kill]:
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
