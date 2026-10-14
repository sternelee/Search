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
        # A dict in the script holds the reply back a while, to watch the
        # loop between replies: {"sleep": seconds, "say": line}.
        if isinstance(line, dict): time.sleep(line.get("sleep", 0)); line = line["say"]
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

def words(seen, what):
    """What the model was shown or told, from the stand-in's record of
    requests — one ask of it for each line of the script."""
    for asked in seen:
        for message in asked.get("messages", []):
            if what in message.get("content", ""):
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
    t.ok("allowed, and asked no more",
         allowed.get("pending") is False and allowed.get("auto") is True, allowed)
    answer = until(t, lambda s: any(e["kind"] == "answer" for e in s.get("events", [])), within=60)
    t.ok("the task ran to its answer",
         any(e["kind"] == "answer" and e["words"] == "sent" for e in answer["events"]), answer["events"])
    acts = [e for e in answer["events"] if e["kind"] == "act"]
    t.ok("…and nothing after it was held",
         not answer.get("pending") and len(acts) == 3 and all(a["act"][3] in ("done", "read") for a in acts), answer["events"])


def main():
    t = T()
    for case in [case_hands, case_refuse, case_auto, case_always, case_card, case_wrapped, case_notice]:
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
