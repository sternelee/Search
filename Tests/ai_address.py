#!/usr/bin/env python3

"""An address of your own for a provider, checked through the bench's socket.

Build first (`./build.sh` or `./build.sh debug`), then run
`python3 Tests/ai_address.py`. The app is started hidden in a world of its
own (SEARCH_PROBE=ai-address-<checkout>, see use()), driven through
./bench's socket, and quit; its settings, folder and stores are removed
afterwards. Nothing here makes, shows or brings forward a window.

OpenAI and Anthropic take an address of their own (see AIProvider.named,
AIProvider.address, Preferences.aiBases, AISettings.address): requests go
to the address named for them in Settings, and a key is kept for that
address's host and sent nowhere else. Checked here:
  the address  an address named for OpenAI is where its requests go — a
               stand-in on this Mac answers one, and is asked at the path
               the provider's own address would have been asked at
  the key      the key goes with the request, kept for the host named
  the row      the row that names one is drawn for the two providers that
               take one, and for no other
  the test     the Test row's own one message goes the same way, and a
               provider with no key kept for it is told so rather than
               left hanging
"""

import hashlib
import json
import os
import re
import socket
import struct
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
use("ai-address")

# The stand-in the named address points at: one answer in the openAI way of
# streaming, over SSE, and the requests it saw kept for the cases to read.
seen = []
def said(reply):
    body = json.dumps({"choices": [{"delta": {"content": reply}}]})
    return f"data: {body}\n\ndata: [DONE]\n\n".encode()
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode(errors="replace")
        seen.append({"path": self.path, "host": self.headers.get("Host"),
                     "auth": self.headers.get("Authorization"), "body": body})
        blob = said("hello from the relay")
        self.send_response(200); self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(blob))); self.end_headers(); self.wfile.write(blob)
    def log_message(self, *a): pass
srv = ThreadingHTTPServer(("127.0.0.1", 0), H); threading.Thread(target=srv.serve_forever, daemon=True).start()
RELAY = f"http://127.0.0.1:{srv.server_port}/v1"

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
        if id != FIRST_SPACE:
            found.append(f"{WEBKIT}/WebsiteDataStore/{id}")
    return found
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
def setup():
    for p in pids(): subprocess.run(["kill", p])
    started.clear()
    time.sleep(1); wipe()
    for k in ["bench", "welcomed", "bot"]: subprocess.run(["defaults", "write", SUITE, k, "-bool", "true"])
def launch():
    if os.path.exists(SOCK): os.remove(SOCK)
    before = running()
    subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={W}", APP])
    for _ in range(150):
        if os.path.exists(SOCK): break
        time.sleep(0.1)
    time.sleep(2)
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
        c.settimeout(60); c.connect(SOCK); c.sendall(json.dumps(req).encode() + b"\n")
        data = b""
        while True:
            ch = c.recv(65536)
            if not ch: break
            data += ch
    a = json.loads(data.split(b"\n", 1)[0] or b"{}")
    if "error" in a: raise RuntimeError(f"{req}: {a['error']}")
    return a
def ai(action, **fields):
    """One ai verb, the answer as it came, errors included."""
    try: return cmd({"do": "ai", "action": action, **fields})
    except RuntimeError as e: return {"error": str(e)}
def provider(name):
    subprocess.run(["defaults", "write", SUITE, "ai.provider", name])
def address(url):
    subprocess.run(["defaults", "write", SUITE, "ai.base", "-dict", "openAI", url])
def picture(where):
    """The AI page drawn off screen, and how tall it came out: the row that
    names an address is a row, so the page is taller for a provider that
    takes one."""
    os.makedirs(where, exist_ok=True)
    made = ai("picture", path=where)
    path = os.path.join(where, "ai-settings.png")
    with open(path, "rb") as f: head = f.read(24)
    return made, struct.unpack(">II", head[16:24])[1]
class T:
    def __init__(self): self.passed = self.failed = 0
    def ok(self, name, cond, extra=""):
        if cond: self.passed += 1; print("  ok  ", name)
        else: self.failed += 1; print("  FAIL", name, extra)
    def done(self):
        print(f"{self.passed} passed, {self.failed} failed")
def finish():
    quit(); time.sleep(0.5); wipe()

def main():
    t = T()
    setup()
    provider("openAI"); address(RELAY)
    launch()
    t.ok("the key is kept for the host named", ai("key", provider="openAI", key="sk-made-up-for-the-relay").get("saved") == "kept")
    asked = ai("ask", provider="openAI", model="gpt-5.4-mini", text="hello")
    t.ok("an address named is where requests go", asked.get("text") == "hello from the relay", asked)
    request = seen[-1] if seen else {}
    t.ok("asked at the path the provider's own address would be",
         request.get("path") == "/v1/chat/completions" and request.get("host") == f"127.0.0.1:{srv.server_port}",
         request.get("path", "nothing was asked"))
    t.ok("with the key kept for that host", request.get("auth") == "Bearer sk-made-up-for-the-relay", request.get("auth", "no key"))
    t.ok("and the model asked for", json.loads(request.get("body", "{}")).get("model") == "gpt-5.4-mini", request.get("body", ""))
    # The Test row in Settings › AI, asked through the bench the same way the
    # row asks it (see AITest).
    tested = ai("test", provider="openAI", model="gpt-5.4-mini")
    t.ok("the Test row's message goes to the address named", tested.get("text") == "hello from the relay", tested)
    t.ok("and it is asked with the model chosen",
         json.loads(seen[-1].get("body", "{}")).get("model") == "gpt-5.4-mini", seen[-1].get("body", ""))
    # A provider with no key kept for it: said, not waited on.
    unkeyed = ai("test", provider="anthropic")
    t.ok("a test with no key says so", "no key" in (unkeyed.get("error") or "").lower(), unkeyed)
    made, with_row = picture("/tmp/ai-address-openai")
    t.ok("the page is drawn", os.path.exists(os.path.join("/tmp/ai-address-openai", "ai-settings.png")), made)
    quit()

    # A provider that takes no address of its own: the row is not drawn for
    # it, so its page comes out a row shorter.
    provider("gemini"); address("")
    launch()
    made, without_row = picture("/tmp/ai-address-gemini")
    t.ok("no row for a provider that takes none", without_row < with_row, f"{without_row} against {with_row}")
    t.ok("and the row is a row, not a hairline", with_row - without_row > 60, f"{with_row - without_row} pixels")
    t.done()
    finish()
    return t.failed

if __name__ == "__main__":
    sys.exit(main())
