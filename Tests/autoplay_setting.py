#!/usr/bin/env python3
"""Settings › Videos wait for a click, followed by every tab, checked in a
hidden probe.

Build first (`./build.sh`), then `python3 Tests/autoplay_setting.py`. Needs
ffmpeg for the test video. The app starts hidden in a world of its own (see
split_view.use), is driven through ./bench's socket and quit; its world is
removed afterwards. Local pages only. `--app PATH` runs another build (a
release's Search.app) for the cases a relaunch can show.

The page holds a muted <video autoplay>, an unmuted one, and two that the
page's own script starts with play(), no click: one muted, one not. With
the switch off, a muted video may start by itself and one with sound waits
(Safari's default); with it on, none may start. A hidden page can hold a
video back for not being seen, so what counts is WebKit's answer, not the
clock: play()'s promise rejected with NotAllowedError, or an autoplay
video never sent "play", is the policy; one that sent "play" was let start.

WebKit fixes mediaTypesRequiringUserActionForPlayback when a page's view is
made, so a tab made before the switch moved, and a link opened from it with
a copy of its configuration, kept the old answer until it slept (19 Oct
2026: "Video needs to be clicked to play, disregarding the option"). Each
page's own autoplay policy, set as it loads, now says the same as the
switch, so every tab follows from its next page or reload.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("autoplay-tests")
if "--app" in sys.argv:
    sv.APP = str(Path(sys.argv[sys.argv.index("--app") + 1]).resolve())
WAITS = "media.click"
VIDEO = b""

PAGE = """<!doctype html><meta charset=utf-8><title>autoplay</title>
<video id=m src=/v.mp4 autoplay muted loop playsinline width=120></video>
<video id=u src=/v.mp4 autoplay loop playsinline width=120></video>
<video id=sm src=/v.mp4 muted loop playsinline width=120></video>
<video id=s src=/v.mp4 loop playsinline width=120></video>
<a id=go target=_blank href=/page?child style="display:block;font-size:60px;line-height:120px">open</a>
<script>
const r = {vis: document.visibilityState, ev: {}, promise: {}};
for (const v of document.querySelectorAll('video')) {
  r.ev[v.id] = [];
  for (const e of ['play', 'playing', 'pause']) v.addEventListener(e, () => r.ev[v.id].push(e));
}
for (const id of ['sm', 's']) {
  r.promise[id] = 'pending';
  document.getElementById(id).play().then(() => r.promise[id] = 'ok', e => r.promise[id] = e.name);
}
window.__r = r;
</script>"""


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if urlparse(self.path).path == "/v.mp4":
            start, end = 0, len(VIDEO) - 1
            header = self.headers.get("Range", "")
            partial = header.startswith("bytes=")
            if partial:
                first, _, last = header[6:].partition("-")
                start = int(first or 0)
                end = min(int(last), end) if last else end
            chunk = VIDEO[start:end + 1]
            self.send_response(206 if partial else 200)
            self.send_header("Content-Type", "video/mp4")
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(len(chunk)))
            if partial:
                self.send_header("Content-Range", f"bytes {start}-{end}/{len(VIDEO)}")
            self.end_headers()
            try:
                self.wfile.write(chunk)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        data = PAGE.encode()
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


def state(tab, settle=3.0):
    """What WebKit answered for each video on the tab's page."""
    time.sleep(settle)
    raw = sv.ev(tab, "JSON.stringify(Object.assign({}, window.__r, {t: Object.fromEntries("
                     "[...document.querySelectorAll('video')].map(v => [v.id, [v.paused, v.currentTime]]))}))")
    return json.loads(raw) if raw else {}


def verdict(s):
    """'waits' when no video started without a click, 'follows Safari' when
    muted ones may and sound waits, else what was seen."""
    if not s or "promise" not in s:
        return f"no page: {s}"
    ev, p = s["ev"], s["promise"]
    muted_ok = p.get("sm") == "ok" and "play" in ev.get("m", [])
    muted_refused = p.get("sm") == "NotAllowedError" and "play" not in ev.get("m", [])
    sound_refused = p.get("s") == "NotAllowedError" and "play" not in ev.get("u", [])
    if muted_refused and sound_refused:
        return "waits"
    if muted_ok and sound_refused:
        return "muted plays"
    return f"mixed: {json.dumps(s)}"


def flip(t, on):
    """The switch, as Settings moves it (needs the bench's ui waits)."""
    sv.cmd({"do": "ui", "waits": on})
    time.sleep(0.5)
    got = subprocess.run(["defaults", "read", sv.SUITE, WAITS], capture_output=True, text=True).stdout.strip()
    t.ok(f"switch {'on' if on else 'off'}", got == ("1" if on else "0"), got)


def open_page(name):
    tab = sv.page(f"page?{name}")
    return tab


def by_link(tab):
    sv.cmd({"do": "select", "id": tab})
    time.sleep(0.7)
    before = {x["id"] for x in tabs()}
    sv.cmd({"do": "tap", "id": tab, "selector": "#go"})
    time.sleep(2.5)
    new = [x["id"] for x in tabs() if x["id"] not in before]
    return new[0] if len(new) == 1 else None


def reload(tab):
    """The tab's next page, loaded as Search loads one. Not location.reload()
    from eval: a script the bench runs counts as a click, and the page it
    reloads may play anything."""
    # On screen first: a page out of the window holds every video back,
    # play() left pending, whatever the policy.
    sv.cmd({"do": "select", "id": tab})
    time.sleep(0.5)
    sv.cmd({"do": "go", "id": tab, "url": f"{sv.BASE}/page?again"})
    time.sleep(1.0)


def runtime(t):
    """The switch moved while tabs are open."""
    want = {False: "muted plays", True: "waits"}
    for start in (False, True):
        end = not start
        sv.setup(**{WAITS: start}); sv.launch()
        old = open_page("old")
        t.ok(f"[{start}] a tab made before: {want[start]}", verdict(state(old)) == want[start], state(old, 0))
        flip(t, end)
        new = open_page("new")
        t.ok(f"[{start}->{end}] a new tab: {want[end]}", verdict(state(new)) == want[end], state(new, 0))
        # Before any click on it: WebKit lets a page clicked in pass its
        # leave to play on to the next page of the same site.
        reload(old)
        t.ok(f"[{start}->{end}] the old tab, its next page: {want[end]}", verdict(state(old)) == want[end], state(old, 0))
        child = by_link(old)
        t.ok(f"[{start}->{end}] a link opened from the old tab: {want[end]}",
             child is not None and verdict(state(child)) == want[end], child and state(child, 0))
        sv.cmd({"do": "select", "id": old})
        time.sleep(0.5)
        slept = sv.cmd({"do": "sleep", "id": new})
        sv.cmd({"do": "select", "id": new})  # woken, as a click on it wakes it
        woke = state(new)  # eval builds the page again
        t.ok(f"[{start}->{end}] a tab slept and woken: {want[end]}",
             verdict(woke) == want[end], (slept, woke))
        sv.quit()


def relaunch(t):
    """The switch changed between two launches: restored tabs follow."""
    want = {False: "muted plays", True: "waits"}
    for start in (False, True):
        end = not start
        sv.setup(**{WAITS: start}); sv.launch()
        tab = open_page("kept")
        t.ok(f"[launch {start}] a tab: {want[start]}", verdict(state(tab)) == want[start], state(tab, 0))
        time.sleep(1.5)  # the session saved
        sv.quit()
        subprocess.run(["defaults", "write", sv.SUITE, WAITS, "-bool", "true" if end else "false"])
        sv.launch()
        kept = next((x["id"] for x in tabs() if "kept" in x.get("url", "")), None)
        t.ok(f"[relaunch {end}] the restored tab: {want[end]}",
             kept is not None and verdict(state(kept)) == want[end], kept and state(kept, 0))
        new = open_page("fresh")
        t.ok(f"[relaunch {end}] a new tab: {want[end]}", verdict(state(new)) == want[end], state(new, 0))
        sv.quit()


def main():
    global VIDEO
    ffmpeg = shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg"
    if not os.path.exists(ffmpeg):
        sys.exit("Tests/autoplay_setting.py needs ffmpeg to make its test video")
    with tempfile.TemporaryDirectory() as folder:
        out = f"{folder}/v.mp4"
        subprocess.run([ffmpeg, "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=320x180:rate=30",
                        "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo", "-t", "6", "-c:v", "libx264",
                        "-pix_fmt", "yuv420p", "-c:a", "aac", "-movflags", "+faststart", out], check=True)
        VIDEO = Path(out).read_bytes()
    t = sv.T()
    try:
        relaunch(t)
        if "--relaunch-only" not in sys.argv:
            runtime(t)
    finally:
        t.done(); sv.finish()
    return 1 if t.failed else 0


if __name__ == "__main__":
    if sys.platform != "darwin":
        sys.exit("Tests/autoplay_setting.py requires macOS and a built Search.app")
    sys.exit(main())
