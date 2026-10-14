#!/usr/bin/env python3
"""An agent's hands, checked through the bench's socket in a hidden probe.

Build first (`./build.sh` or `./build.sh debug`), then run
`python3 Tests/agent_automation.py`. The app is started hidden in a world of
its own (SEARCH_PROBE=agent-tests-<checkout>, see use()), driven through
./bench's socket, and quit; its settings and files are removed afterwards.
Nothing here makes, shows or brings forward a window.

Two sides of the agent surface are checked:
  the hands    pages, labels, snapshot, act, read and wait — against a page
               of the test's own, with a form a model would be asked to fill
  the carrier  `agent run` — a stand-in model on this Mac (bench ai-mock)
               that says one act at a time, as the loop asks of it, until it
               answers in words
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
use("agent-tests")

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

MONTHS = ("January", "April", "July", "October", "December")
OPTIONS = "".join(f"<option>{m}</option>" for m in MONTHS)
FORM = FORM.replace(
    "    <option>January</option><option>April</option><option>July</option>\n    <option>October</option><option>December</option></select>",
    f"    {OPTIONS}</select>",
)

# The stand-in model: one line from the script a request at a time, in the
# openAI way of streaming, over SSE. The script is the acts a model would
# take to fill the form; each request carries all that has been said so far,
# and the next line of it is the answer.
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
        line = script.pop(0) if script else "ANSWER nothing left to do"
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
    named as the app names them (Store.probeStore, Spaces.store): its
    websites', its extensions', and one for each of its spaces with sign-ins
    of its own, read from its own list of spaces and of spaces it was still
    erasing. Only those: a real Search's spaces keep their stores beside
    them, and a store is never guessed at by its look."""
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
    real Search's own list, and the first space's fixed id. A wrong hash, or
    a test world's list holding a real space's id, then never reaches a real
    space's sign-ins: rm -rf runs in the folder where those live."""
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
def ag(action, **fields):
    """One agent verb, the answer as it came, errors included — so a case
    can ask for them."""
    try:
        return cmd({"do": "agent", "action": action, **fields})
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

def ref(snapshot, what):
    """The number a snapshot gave a thing described as `role "Name"` —
    `textbox "First name" @3` for what."""
    hit = re.search(rf"^{re.escape(what)}(?: \[[^\]]*\])* @\d+", snapshot, re.M)
    return hit.group(0).rsplit(" ", 1)[1] if hit else None

def wait_load(t, label, within=15):
    until = time.time() + within
    while time.time() < until:
        page = next((p for p in ag("pages")["pages"] if p["label"] == label), None)
        if page and not page["loading"]: return page
        time.sleep(0.2)
    return None


def case_hands(t):
    """pages, labels, snapshot, act, read, wait"""
    setup(); launch()
    opened = ag("open", url=f"{BASE}/form")
    t.ok("open gives the first label", opened.get("label") == "p1" and opened.get("id"), opened)

    second = ag("open", url=f"{BASE}/other", **{"as": "notes"})
    t.ok("open takes a name of its own", second.get("label") == "notes", second)
    third = ag("open", url=f"{BASE}/third")
    t.ok("the next one out of the numbers", third.get("label") == "p2", third)

    pages = {p["label"]: p for p in ag("pages")["pages"]}
    t.ok("pages lists all three, the bench's only", set(pages) == {"p1", "notes", "p2"}, pages)
    t.ok("…with the page under its address", pages.get("p1", {}).get("url", "").endswith("/form"), pages.get("p1"))

    renamed = ag("label", id="p2", **{"as": "last words"})
    t.ok("label renames, kept short and plain", renamed.get("label") == "lastwords", renamed)
    pages = {p["label"]: p for p in ag("pages")["pages"]}
    t.ok("…and the old name is gone", "p2" not in pages and "lastwords" in pages, sorted(pages))

    page = wait_load(t, "p1")
    t.ok("the form is there", page and page["title"] == "sign up", page)

    snap = ag("snapshot", id="p1")
    tree = snap.get("snapshot", "")
    t.ok("snapshot sees the heading", 'heading "Try it"' in tree, tree)
    t.ok("…a box by its label", ref(tree, 'textbox "First name"') and ref(tree, 'textbox "Email"'), tree)
    t.ok("…no hidden thing", "hidden" not in tree.lower() and "#done" not in tree, tree)

    first = ref(tree, 'textbox "First name"')
    email = ref(tree, 'textbox "Email"')
    month = ref(tree, 'combobox "Month"')
    terms = ref(tree, 'checkbox "I agree"')
    button = ref(tree, 'button "Sign up"')
    t.ok("…a combobox, a checkbox and the button",
        month and terms and button, tree)

    done = ag("act", id="p1", verb="fill", target=first, text="Ada")
    t.ok("fill by number", done.get("ok") and done.get("value") == "Ada", done)
    t.ok("fill by role and name", ag("act", id="p1", verb="fill", target="loc=role:textbox[name='Email']", text="ada@lovelace.dev").get("value") == "ada@lovelace.dev")
    t.ok("fill by words on the thing", ag("act", id="p1", verb="fill", target="text=First name", text="Ada").get("value") == "Ada")
    picked = ag("act", id="p1", verb="select", target=month, text="October")
    t.ok("select an option by its name", picked.get("ok") and picked.get("label") == "October", picked)
    t.ok("check the box", ag("act", id="p1", verb="check", target=terms).get("checked") is True)
    t.ok("read sees what fill put", ag("read", id="p1", target=email).get("value") == "ada@lovelace.dev")

    stale = ag("act", id="p1", verb="fill", target="@9999", text="no")
    t.ok("a number the page never gave is refused in words", "snapshot" in stale.get("error", ""), stale)

    pressed = ag("act", id="p1", verb="press", target=email, text="Enter")
    t.ok("Enter in a form submits it", pressed.get("submitted") is True, pressed)
    waited = ag("wait", id="p1", target="#done", seconds=5)
    t.ok("wait until the page says so", waited.get("ok") is True, waited)
    words = ag("read", id="p1", target="#done")
    t.ok("the form was filled and sent", words.get("text") == "Signed up Ada <ada@lovelace.dev> for October, agreed", words)
    after = ag("snapshot", id="p1").get("snapshot", "")
    t.ok("a hidden form is not on the page", 'button "Sign up"' not in after, after)

def case_carrier(t):
    """a task in words, carried by a stand-in model"""
    setup(); launch()
    cmd({"do": "ai", "action": "mock", "url": f"http://127.0.0.1:{srv.server_port}/"})
    opened = ag("open", url=f"{BASE}/form")
    t.ok("the page is there", opened.get("label") == "p1", opened)
    wait_load(t, "p1")

    script.clear(); seen.clear()
    script.extend([
        "ACT fill css=#first Ada",
        "ACT fill loc=role:textbox[name='Email'] ada@lovelace.dev",
        "ACT select #month October",
        "ACT check #terms",
        "ACT click text=Sign up",
        "ACT read css=#done",
        "ANSWER signed up, as asked",
    ])
    done = ag("run", id="p1", provider="ollama", task="Sign the form up for Ada, ada@lovelace.dev, for October, agreeing")
    t.ok("the task is carried out", done.get("answer") == "signed up, as asked", done)
    t.ok("…in as many acts as the script had", done.get("steps") == 7, done)
    asked = seen[-1]["messages"]
    reading = next((m["content"] for m in asked if "read:" in m["content"]), "")
    t.ok("the model was shown what it read", "Signed up Ada <ada@lovelace.dev> for October, agreed" in reading, reading)
    task_seen = next(m["content"] for m in seen[0]["messages"] if m["role"] == "user")
    t.ok("…and the task, with the page under it", task_seen.startswith("TASK: Sign the form up") and "THE PAGE HOLDS:" in task_seen, task_seen[:120])

def case_bounds(t):
    """what is not the bench's is not touched"""
    setup(); launch()
    nobody = ag("snapshot", id="99999999")
    t.ok("a page that isn't there says so", "no such tab" in nobody.get("error", ""), nobody)
    plain = cmd({"do": "open", "url": f"{BASE}/form"})
    t.ok("the bench's own open is not one of the agent's", "agent" not in json.dumps(plain), plain)
    taken = ag("snapshot", id=plain["id"])
    t.ok("…but the agent can see it by its id", "snapshot" in taken, taken)


def main():
    t = T()
    for case in [case_hands, case_carrier, case_bounds]:
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
