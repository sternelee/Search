#!/usr/bin/env python3
"""Independent conversations, streamed concurrently through the real app.

Build first. Uses bot_panel's isolated probe lifecycle, never the user's
settings, keys, cookies or running browser. The model and pages are local.
"""
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import bot_panel as probe

probe.use("bots-workspace")
lock = threading.Lock()
requests = []
active = 0
maximum = 0


class Model(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        global active, maximum
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        users = "\n".join(m.get("content", "") for m in body.get("messages", []) if m.get("role") == "user")
        marker = next((m for m in ["APPROVE_ALPHA", "APPROVE_BETA", "CONVERSATION_ALPHA", "CONVERSATION_BETA"] if m in users), "UNKNOWN")
        with lock:
            requests.append((marker, body))
            active += 1
            maximum = max(maximum, active)
        acted = any('"act"' in m.get("content", "") for m in body.get("messages", []) if m.get("role") == "assistant")
        if marker.startswith("APPROVE_") and not acted:
            reply = {"act": {"verb": "fill", "target": "css=#first", "text": marker}}
        else:
            reply = {"answer": "Answer for " + marker}
        text = json.dumps(reply)
        pieces = [text[:12], text[12:24], text[24:]]
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        try:
            for piece in pieces:
                time.sleep(0.35)
                data = ("data: " + json.dumps({"choices": [{"delta": {"content": piece}}]}) + "\n\n").encode()
                self.wfile.write(f"{len(data):X}\r\n".encode() + data + b"\r\n")
                self.wfile.flush()
            done = b"data: [DONE]\n\n"
            self.wfile.write(f"{len(done):X}\r\n".encode() + done + b"\r\n0\r\n\r\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            with lock:
                active -= 1

    def log_message(self, *args):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Model)
threading.Thread(target=server.serve_forever, daemon=True).start()


def bots(action, **fields):
    return probe.cmd({"do": "bots", "action": action, **fields})


def wait_for(session, predicate, timeout=20):
    end = time.monotonic() + timeout
    state = {}
    while time.monotonic() < end:
        state = bots("state", id=session)
        if predicate(state):
            return state
        time.sleep(0.1)
    raise AssertionError(f"session did not settle: {state}")


def settle(predicate, timeout=20):
    """Wait for the split's own geometry: a width is laid out on the pass
    after it is set, as it is on screen, so one reading proves nothing."""
    end = time.monotonic() + timeout
    state = {}
    while time.monotonic() < end:
        state = bots("page")
        if predicate(state):
            return state
        time.sleep(0.1)
    raise AssertionError(f"the split did not settle: {state}")


def png_rows(path):
    """A picture's rows of pixels, unfiltered: one bytearray a row, four
    bytes a pixel. The usual five PNG filters, undone (see chat_tab's
    bands)."""
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

    prev = bytearray(width * 4)
    rows = []
    for y in range(height):
        start = y * stride
        f = raw[start]
        line = bytearray(raw[start + 1:start + stride])
        for i in range(len(line)):
            left = line[i - 4] if i >= 4 else 0
            up = prev[i]
            corner = prev[i - 4] if i >= 4 else 0
            if f == 1: line[i] = (line[i] + left) & 0xFF
            elif f == 2: line[i] = (line[i] + up) & 0xFF
            elif f == 3: line[i] = (line[i] + (left + up) // 2) & 0xFF
            elif f == 4: line[i] = (line[i] + paeth(left, up, corner)) & 0xFF
        rows.append(line)
        prev = line
    return rows, width, height


def png_ground(rows, width, height):
    """The colour most of the picture is: the ground the words are drawn
    on, whatever the theme puts there."""
    import collections
    seen = collections.Counter()
    for y in range(0, height, 7):
        line = rows[y]
        for x in range(0, width, 7):
            seen[(line[x * 4], line[x * 4 + 1], line[x * 4 + 2])] += 1
    return seen.most_common(1)[0][0]


def inked(rows, ground, x0, x1, y):
    """Whether a row of the picture carries ink across the conversation's
    width: words, a scroller, a rule. Ink is anything that isn't the
    ground — a scroller's trough is drawn over the ground, so it counts."""
    line = rows[y]
    count = 0
    for x in range(x0, x1):
        r, g, b = line[x * 4], line[x * 4 + 1], line[x * 4 + 2]
        if abs(r - ground[0]) + abs(g - ground[1]) + abs(b - ground[2]) > 12:
            count += 1
    return count >= 3


def band_over(path):
    """How many rows of ink lie just over the foot line, in one solid band
    — the scroller that used to be drawn there. A band is a run of rows
    each inked across the conversation's width, ended by a stretch of bare
    ground."""
    rows, width, height = png_rows(path)
    ground = png_ground(rows, width, height)
    # Words are drawn down the left; the conversation runs to the panel's
    # edge, and it is the whole width a band spans.
    x0, x1 = int(width * 0.25), width - 3
    foot = foot_line(path)
    if not foot:
        return 0
    solid = 0
    for y in range(foot[0] - 1, max(-1, foot[0] - 60), -1):
        if inked(rows, ground, x0, x1, y):
            solid += 1
        else:
            break
    # One row of near-ink is the bottom of a letter; a band is what a
    # scroller draws.
    return solid if solid >= 3 else 0


def foot_covered(path):
    """The most of the foot line's width any one row of it covers, 0 to 1.
    A line of small faint words covers a fifth of it at most; a scroller's
    trough drawn over the line covers all of it. What the bug looked like,
    said as a number."""
    rows, width, height = png_rows(path)
    ground = png_ground(rows, width, height)
    x0, x1 = int(width * 0.25), width - 3
    foot = foot_line(path)
    if not foot:
        return 1.0
    span = x1 - x0
    most = 0.0
    for y in range(foot[0], foot[1] + 1):
        line = rows[y]
        n = sum(1 for x in range(x0, x1)
                if abs(line[x * 4] - ground[0]) + abs(line[x * 4 + 1] - ground[1])
                 + abs(line[x * 4 + 2] - ground[2]) > 12)
        most = max(most, n / span)
    return most


def foot_line(path):
    """The foot line's own rows: the lowest band of words in the picture
    that is not the bottom edge's own divider — where the line that says
    the AI may be wrong is drawn. Returns (top, bottom, rows tall), or
    None when no such band stands."""
    rows, width, height = png_rows(path)
    ground = png_ground(rows, width, height)
    x0, x1 = int(width * 0.25), width - 3
    bands, in_band, top = [], False, 0
    for y in range(max(0, int(height * 0.5)), height):
        here = inked(rows, ground, x0, x1, y)
        if here and not in_band:
            in_band, top = True, y
        elif not here and in_band:
            bands.append((top, y - 1))
            in_band = False
    if in_band:
        bands.append((top, height - 1))
    # The foot line is a band of small words near the bottom, and the
    # lowest one that isn't the picture's own edge.
    bands = [b for b in bands if b[1] < height - 4 and b[1] - b[0] >= 2]
    if not bands:
        return None
    bottom = bands[-1]
    return (bottom[0], bottom[1], bottom[1] - bottom[0] + 1)


def run():
    probe.setup()
    probe.launch()
    probe.cmd({"do": "ai", "action": "mock", "url": f"http://127.0.0.1:{server.server_port}/"})
    profile = bots("profile", name="Research Bot", provider="ollama", model="test")["id"]
    a = bots("new", bot=profile, title="Conversation Alpha")["id"]
    b = bots("new", bot=profile, title="Conversation Beta")["id"]
    bots("show", id=a)
    assert bots("list")["panes"] == [a]
    bots("show", id=b)
    assert bots("list")["panes"] == [b], "one conversation at a time in the panel"
    bots("ask", id=a, text="CONVERSATION_ALPHA")
    bots("ask", id=b, text="CONVERSATION_BETA")
    wait_for(a, lambda s: bool(s["stream"]))
    assert bots("state", id=b)["busy"], "B should run while A streams"
    bots("hide", id=b)
    assert bots("state", id=b)["busy"], "closing a pane must not stop its conversation"
    bots("stop", id=a)
    done = wait_for(b, lambda s: not s["busy"])
    assert done["state"] == "completed", done
    assert any(e["words"] == "Answer for CONVERSATION_BETA" for e in done["events"]), done
    time.sleep(1)
    stopped = bots("state", id=a)
    assert stopped["state"] == "cancelled"
    assert not any(e["kind"] == "answer" for e in stopped["events"])
    assert maximum >= 2, "the provider never saw concurrent streams"
    for marker, request in requests:
        content = json.dumps(request["messages"])
        if marker == "CONVERSATION_ALPHA":
            assert "CONVERSATION_BETA" not in content
        if marker == "CONVERSATION_BETA":
            assert "CONVERSATION_ALPHA" not in content
    print("ok: simultaneous streaming, isolated history, pane lifetime and cancellation")

    page_a = probe.cmd({"do": "open", "url": probe.BASE + "/form"})["id"]
    page_b = probe.cmd({"do": "open", "url": probe.BASE + "/form"})["id"]
    probe.form_ready(page_a)
    probe.form_ready(page_b)
    c = bots("new", bot=profile, pages=[page_a], title="Approval Alpha")["id"]
    d = bots("new", bot=profile, pages=[page_b], title="Approval Beta")["id"]
    bots("ask", id=c, text="APPROVE_ALPHA")
    bots("ask", id=d, text="APPROVE_BETA")
    ca = wait_for(c, lambda s: bool(s["pending"]))
    db = wait_for(d, lambda s: bool(s["pending"]))
    try:
        bots("allow", id=c, run=db["run"], pending=db["pending"]["id"])
        raise AssertionError("cross-session approval was accepted")
    except RuntimeError as error:
        assert "stale approval" in str(error)
    bots("allow", id=c, run=ca["run"], pending=ca["pending"]["id"])
    wait_for(c, lambda s: not s["busy"])
    first = probe.cmd({"do": "agent", "action": "read", "id": page_a, "target": "css=#first"})
    second = probe.cmd({"do": "agent", "action": "read", "id": page_b, "target": "css=#first"})
    assert first.get("value") == "APPROVE_ALPHA", first
    assert second.get("value") == "", second
    assert bots("state", id=d)["pending"]["id"] == db["pending"]["id"]
    bots("stop", id=d)
    print("ok: independent page contexts and session/run-bound approvals")

    # Same-page contention waits rather than replacing another run's refs.
    e = bots("new", bot=profile, pages=[page_b], title="Same page one")["id"]
    f = bots("new", bot=profile, pages=[page_b], title="Same page two")["id"]
    bots("ask", id=e, text="APPROVE_ALPHA")
    wait_for(e, lambda s: bool(s["pending"]))
    bots("ask", id=f, text="APPROVE_BETA")
    wait_for(f, lambda s: "waiting for this page" in s["status"])
    bots("stop", id=e)
    wait_for(f, lambda s: bool(s["pending"]))
    bots("stop", id=f)
    print("ok: page lease handoff and cancellation")

    bots("show", id=a)
    bots("show", id=b)
    # The panel sits beside the page, not over it: the page keeps its own
    # room, and the edge between them is pulled to a width that is kept.
    listing = bots("list")
    assert listing["showing"], listing
    assert listing["panes"] == [b], listing
    beside = bots("page")
    assert beside["room"], "the panel has no room in the window"
    panel = beside["room"]
    page = beside["page"]
    assert panel[0] >= page[0] + page[2] - 12, f"the page is drawn under the panel: {page} {panel}"
    assert page[2] > 0 and page[3] > 0, page
    # A width is taken on the next pass of the layout, as it is on screen.
    narrow = bots("width", width=360)
    assert abs(narrow["width"] - 360) < 1, narrow
    narrowed = settle(lambda s: abs(s["room"][2] - 360) < 2)["page"]
    assert narrowed[2] > page[2] - 1, "the page did not take the room the panel gave back"
    wide = bots("width", width=4000)
    assert wide["width"] <= 901, wide
    # Pulled as wide as it goes, the panel takes what is left once the page
    # has its least and not a point more: the panel is what yields, so a
    # narrow window never crushes the page into a strip.
    wided = settle(lambda s: s["page"][2] <= 281)["page"]
    assert 278 <= wided[2] <= 282, f"the page did not keep its least: {wided}"
    assert wided[2] < narrowed[2], "the page did not give the room up"
    bots("width", width=420)
    restored = settle(lambda s: abs(s["room"][2] - 420) < 2)["page"]
    assert abs(restored[2] - page[2]) < 2, "the width is not kept"
    print("ok: the panel is a room beside the page, and its edge is pulled")

    # Full screen is the conversation filling the stage, page and all: the
    # page gives its room up rather than being drawn over, and going back
    # puts it beside the panel exactly as wide as it was.
    full = bots("full", on=True)
    assert full["full"] and full["showing"], full
    filled = settle(lambda s: s["page"][2] < 1 and s["room"][2] > 900)
    assert filled["page"][2] < 1, f"the page kept its room in full screen: {filled['page']}"
    assert filled["room"][2] > 900, f"the panel did not take the stage: {filled['room']}"
    bots("full", on=False)
    back = settle(lambda s: abs(s["room"][2] - 420) < 2)
    assert back["page"][2] > 200, f"the page did not come back beside the panel: {back['page']}"
    assert abs(back["page"][2] - restored[2]) < 2, "the page came back a different width"
    print("ok: full screen fills the stage with the conversation, and gives the page back")

    # The address field stands over the page and the panel is left alone:
    # ⌘L, and typing, do not put the conversations away.
    typed = probe.cmd({"do": "field", "text": "example"})
    assert typed["field"] == "example", typed
    assert bots("list")["showing"], "the address field put the panel away"
    assert probe.cmd({"do": "probe"})["field"], "the field never came up"
    # Put away, the page takes the room back and every conversation runs on.
    before = bots("state", id=a)
    gone = bots("hide")
    assert not gone["showing"], gone
    assert len(gone["panes"]) == 1, gone
    after = bots("state", id=a)
    assert after["state"] == before["state"] and after["run"] == before["run"], after
    bots("show", id=a)
    assert bots("list")["showing"]
    print("ok: the field is over the page, and the panel goes and comes back")

    # The door is a switch, on the foot and in the tab bar alike.
    off = bots("toggle")
    assert not off["showing"], off
    assert not off["full"], off
    on = bots("toggle")
    assert on["showing"] and not on["full"], on
    print("ok: the door puts the panel away and brings it back")

    # The workspace drawn off screen at three widths — the panel's own
    # narrowest among them, where a scroller over the conversation is what
    # used to happen.
    pictures = {}
    for name, width, height in [("wide", 1180, 780), ("narrow", 640, 420),
                                ("panel", 420, 780), ("least", 300, 780)]:
        path = f"/tmp/search-bots-workspace-{name}.png"
        pictures[path] = bots("picture", path=path, width=width, height=height)
        assert Path(path).stat().st_size > 1000, path
    # Nothing is drawn over the conversation's own foot — the line that
    # says the AI may be wrong. What lay over it was a scroller, drawn
    # over the last rows of the conversation when the panel was narrower
    # than a pane; asked of the view tree, for an overlay scroller only
    # draws while it is used, and so of the picture too, where the line's
    # own rows are counted.
    for path, made in pictures.items():
        assert not made.get("sideways"), f"the workspace scrolls sideways: {made}"
        foot = foot_line(path)
        assert foot, f"the foot line is not in the picture: {path}"
        top, bottom, rows = foot
        assert 6 <= rows <= 34, f"the foot line is drawn crushed or merged, {rows} rows tall: {path}"
        covered = foot_covered(path)
        # A line of small faint words covers half its width at most, the
        # narrow panel's half being the wider share; a scroller's trough
        # drawn over it covers the whole of a row.
        assert covered < 0.7, f"something is drawn across the foot line: {covered:.0%} of a row: {path}"
        assert not band_over(path), \
            f"a band of ink lies over the foot line, above row {top}: {path}"
    print("ok: the foot line has its own rows, with nothing drawn over them")
    probe.quit()
    probe.launch()
    restored = bots("state", id=b)
    assert restored["title"] == "Conversation Beta"
    assert not restored["busy"]
    assert any(e["words"] == "Answer for CONVERSATION_BETA" for e in restored["events"])
    print("ok: history restored without replaying work")


if __name__ == "__main__":
    try:
        run()
    finally:
        probe.finish()
        server.shutdown()
