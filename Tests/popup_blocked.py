#!/usr/bin/env python3
"""A refused pop-up, its sign, Open and Always Allow, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/popup_blocked.py`. The app
starts hidden in a world of its own (bld-pop-<checkout>, see
split_view.use), is driven through ./bench's socket, and is quit; its world
is removed afterwards. Local pages only. The page's own windows are asked
for by page script, never by `eval` (which counts as a click), and clicks
are `tap`'s trusted ones. Nothing here shows a window or a popover: the
sign is read from the tab (`popups ID`), and drawn by the unit tests.

Pages on http://localhost:PORT are "the site"; a frame on
http://127.0.0.1:PORT is a third party on it.
"""
import sys
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bld-pop")
PORT = sv.srv.server_port
SITE = f"http://localhost:{PORT}"
OTHER = f"http://127.0.0.1:{PORT}"


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        page = urlparse(self.path).path
        if page == "/auto":
            body = "<script>setTimeout(() => window.open('/opened-auto'), 300)</script>auto"
        elif page == "/schemes":
            body = """<script>setTimeout(() => {
              window.open('javascript:void(0)'); window.open('data:text/html,x'); window.open('about:blank');
            }, 300)</script>schemes"""
        elif page == "/third":
            body = f"<iframe src='{OTHER}/third-frame'></iframe>third"
        elif page == "/third-frame":
            body = "<script>setTimeout(() => window.open('/opened-third'), 300)</script>ad"
        elif page == "/same":
            body = f"<iframe src='{SITE}/same-frame'></iframe>same"
        elif page == "/same-frame":
            body = "<script>setTimeout(() => window.open('/opened-same'), 300)</script>own frame"
        elif page == "/twice":
            body = """<button id="go" onclick="window.open('/opened-first'); window.open('/opened-second')"
            style="font-size:60px">Two</button>"""
        else:
            body = f"plain {page}"
        data = ("<!doctype html><meta charset=utf-8>" + body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


sv.srv.RequestHandlerClass = H


def tabs():
    return sv.cmd({"do": "tabs"})["tabs"]


def opened(name):
    return [t for t in tabs() if urlparse(t["url"]).path == f"/opened-{name}"]


def state(tab):
    return sv.cmd({"do": "popups", "id": tab})


# The first page's tab: a normal one, the source of every other normal
# page here (a private tab in front would make the next one private).
anchor = None


def visit(path, source=None):
    req = {"do": "split", "action": "open", "url": f"{SITE}{path}"}
    if source or anchor:
        req["from"] = source or anchor
    tab = sv.cmd(req)["resultID"]
    time.sleep(1.5)
    return tab


def go(tab, path):
    sv.cmd({"do": "go", "id": tab, "url": f"{SITE}{path}"})
    time.sleep(1.5)


def main():
    global anchor
    t = sv.T()
    try:
        sv.setup(); sv.launch()

        # A: refused, the sign says so; Open makes one plain tab.
        page = anchor = visit("/auto")
        st = state(page)
        t.ok("a window with no click is refused", not opened("auto"))
        t.ok("the tab shows the sign", st["sign"] is True, st)
        t.ok("the refused address is kept", st["blocked"] == [f"{SITE}/opened-auto"], st)
        t.ok("the site is the page's", st["site"] == "localhost", st)
        before = len(tabs())
        st = sv.cmd({"do": "popups", "id": page, "action": "open", "index": 0})
        time.sleep(1.5)
        made = opened("auto")
        t.ok("Open makes exactly one tab", len(tabs()) == before + 1 and len(made) == 1, (before, len(tabs())))
        t.ok("at the address WebKit gave", st.get("opened", {}).get("url") == f"{SITE}/opened-auto", st)
        t.ok("with no opener in Search", st.get("openedOpener") == "", st)
        t.ok("and none in the page", made and sv.ev(made[0]["id"], "window.opener === null") is True)
        t.ok("in front", made and made[0]["active"] is True)
        t.ok("the sign goes once nothing is left", state(page)["sign"] is False)

        # B: only web addresses are offered.
        page = visit("/schemes")
        st = state(page)
        t.ok("non-web windows are noted", st["sign"] is True and len(st["blocked"]) >= 1, st)
        t.ok("but none can be opened", not any(st["openable"]), st)
        before = len(tabs())
        for _ in st["blocked"]:
            sv.cmd({"do": "popups", "id": page, "action": "open", "index": 0})
        time.sleep(1)
        t.ok("Open on them makes no tab", len(tabs()) == before, (before, len(tabs())))

        # C: a new page clears the list.
        page = visit("/auto")
        t.ok("noted again", state(page)["sign"] is True)
        go(page, "/plain")
        st = state(page)
        t.ok("navigation clears the list", st["sign"] is False and st["blocked"] == [], st)

        # D: one click, one window: the second isn't a pop-up to offer.
        page = visit("/twice")
        sv.cmd({"do": "tap", "id": page, "selector": "#go"})
        time.sleep(1.5)
        t.ok("a click opens its one window", len(opened("first")) == 1 and not opened("second"))
        t.ok("the same click's second window shows no sign", state(page)["sign"] is False, state(page))

        # E: Always Allow.
        page = visit("/auto")
        st = sv.cmd({"do": "popups", "id": page, "action": "allow"})
        t.ok("Always Allow saves the site", st["allowed"] == ["localhost"] and st["sign"] is False, st)
        count = len(opened("auto"))
        go(page, "/auto")
        t.ok("the next pop-up from the site opens", len(opened("auto")) == count + 1)
        t.ok("and shows no sign", state(page)["sign"] is False)
        page = visit("/same")
        t.ok("a frame of the same site opens too", len(opened("same")) == 1)
        page = visit("/third")
        st = state(page)
        t.ok("a third-party frame on the allowed site is still refused", not opened("third"), opened("third"))
        t.ok("and noted", st["blocked"] == [f"{OTHER}/opened-third"], st)

        # F: the saved list applies in a private tab.
        sv.sp("private")
        shy = next(x["id"] for x in tabs() if x["shy"] and x["active"])
        count = len(opened("auto"))
        page = visit("/auto", source=shy)
        t.ok("the page is private", next(x for x in tabs() if x["id"] == page)["shy"] is True)
        t.ok("the saved list applies there", len(opened("auto")) == count + 1)

        # G: removed in Settings, refused again.
        st = sv.cmd({"do": "popups", "action": "remove", "site": "localhost"})
        t.ok("removed from the list", st["allowed"] == [], st)
        count = len(opened("auto"))
        page = visit("/auto")
        t.ok("refused again", len(opened("auto")) == count and state(page)["sign"] is True)

        # H: a private tab's own choices.
        count = len(opened("auto"))
        page = visit("/auto", source=shy)
        st = state(page)
        t.ok("refused in a private tab, with the sign", len(opened("auto")) == count and st["sign"] is True, st)
        st = sv.cmd({"do": "popups", "id": page, "action": "open", "index": 0})
        time.sleep(1.5)
        t.ok("Open from a private tab is private", st.get("opened", {}).get("shy") is True, st)
        page = visit("/auto", source=shy)
        st = sv.cmd({"do": "popups", "id": page, "action": "allow"})
        t.ok("Allow in a private tab saves nothing", st["allowed"] == [] and st["tabAllowed"] == ["localhost"], st)
        t.ok("nothing written to the settings", sv.cmd({"do": "popups", "action": "sites"})["allowed"] == [])
        count = len(opened("auto"))
        go(page, "/auto")
        t.ok("that private tab's next pop-up opens", len(opened("auto")) == count + 1)
        count = len(opened("auto"))
        other = visit("/auto")
        t.ok("other tabs are still refused", len(opened("auto")) == count and state(other)["sign"] is True)
    finally:
        t.done(); sv.finish()
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())
