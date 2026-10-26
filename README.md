# Search

A small, fast, quiet web browser for the Mac, by [Office Commun](https://officecommun.com).

![Search, with its tabs down the left and a page taking the rest of the window](.github/screenshot.png)

**[Download for macOS →](https://officecommun.com/search)** · macOS 14 or later · free · about 6 MB

Or with [Homebrew](https://brew.sh): `brew install --cask driceroland/tap/search`

---

## What it is

Search is a browser with nothing in the way. A row of tabs — across the top or down the left, your choice — and the page. There is no toolbar, no start page, no sidebar of suggestions, no account to sign into, nothing that wants your attention. You type an address or a few words in one field and you are on the page.

It uses **WebKit**, the engine already inside every Mac (it is what Safari runs on). That is why the whole app is about 3 MB on disk and opens instantly: there is no second copy of Chromium to download, update and keep in memory.

It was built by a design studio that spends its whole day in a browser and was tired of the ones that had become products. This one is a tool.

## What it does

- **One field.** Type an address and you go there; type words and you search. It finishes addresses from your own history and never sends what you type anywhere until you press Return.
- **Tabs that stay out of the way.** Pin the pages you keep open all day and they shrink to a letter or their icon. Tabs from your last session come back instantly and cost nothing until you click them. `⌘K` lists your open tabs by name.
- **Two pages side by side.** Turn on Split View in Settings › Tabs, then drag a tab onto a page or choose Tabs › Split Current Page. Drag the divider to resize the panes; the outlined pane receives page commands. Pairs and their widths come back with their Space, including after a restart.
- **Reading mode.** `⇧⌘R` strips a page down to the article.
- **Hide anything, for good.** `⇧⌘H`, then click a cookie banner, a newsletter overlay, a rail of "related" nonsense — it goes, and it is still gone on that site next time, before the page has drawn a single frame.
- **An ad blocker that runs before the page.** Third-party trackers and ad networks are stopped at the network level, so there is nothing to render and nothing to slow down. On by default, off per site if something breaks.
- **Video that follows you.** `⇧⌘P` lifts the video out of the page into a small window that stays above everything, including other apps.
- **Passwords, in your keychain.** Search offers to save a sign-in once it has actually worked, and offers your saved accounts, and the Mac's passkeys for the site, under the field when you click it — the way Safari does, never filling anything on its own. Everything lives in the macOS keychain, encrypted by the system, readable only by Search. Bring yours in from Chrome, Arc, Dia, Brave or Edge in one click; nothing leaves the Mac.
- **Light, dark, or the Mac's own.** The frame and the pages follow.
- **Bookmarks, history, downloads** — each a panel, each searchable, each one keystroke away.
- **Chrome extensions, without Chrome.** Paste a Chrome Web Store link in Settings › Extensions, or open the extension's page in Search and press Add. It runs on WebKit's own extension engine — the one Safari uses — and where Chrome has APIs WebKit doesn't (bookmarks, history, downloads, side panel, offscreen documents, fonts, notifications, speech, OAuth sign-in), Search fills them in itself. They live behind the puzzle button; pin the ones you use often. Building your own? Load its folder as an unpacked extension and press Reload after each change, as in Chrome's developer mode. macOS 15.4 or later.
- **Updates itself, quietly.** Once a day it checks for a newer build, downloads it, verifies it is signed by Office Commun, and swaps it in for the next launch. Nothing restarts on its own.

## What it doesn't do

On purpose:

- No extension you have to install to feel at home. Blocking ads, hiding clutter, reading mode, picture-in-picture and passwords are built in; extensions are there for everything else.
- No sync, no account, no cloud. Your tabs, history and passwords are on your Mac and nowhere else.
- No telemetry, no analytics, no crash reports sent anywhere. The only things that leave your Mac are the pages you ask for, their icons, and one small request a day to see whether there is a newer version.
- One window. Tabs are the only kind of "new" there is.

## Privacy, concretely

| What | Where it is | Who can read it |
|---|---|---|
| Passwords | The macOS login keychain, as ordinary keychain items tagged `Search` | Search, signed by Office Commun. Any other app triggers the system's permission dialog. |
| History, bookmarks, open tabs, hidden elements | Small JSON files in `~/Library/Application Support/Search/` | You. |
| Cookies and site data | WebKit's own store for the app | The sites that set them, as in any browser. |
| Extensions | Unpacked in `~/Library/Application Support/Search/Extensions/`, their data in WebKit's extension store | Each extension, within the permissions you accepted when adding it. |
| Anything else | Nowhere. There is no server. | — |

A **private tab** (`⇧⌘N`) has its own cookie jar and leaves nothing behind when it closes.

Apps you allow in System Settings › Privacy & Security › Automation can read the address and title of your tabs with AppleScript; private tabs are never shown.

## Keyboard

| | |
|---|---|
| `⌘L` address · `⌘K` switch tab · `⌘T` new tab · `⌘W` close · `⇧⌘T` reopen | `⌘[` `⌘]` back, forward · `⇧⌘[` `⇧⌘]` previous, next tab · `⌘1`–`⌘9` jump |
| `⇧⌘S` tabs across the top or down the left · `⌘S` fold the sidebar away · `⇧⌘B` bookmark this page | `⇧⌘R` reading mode · `⇧⌘P` float the video · `⇧⌘H` hide something · `⇧⌘U` what is hidden here |
| `⌘F` find · `⌘D` duplicate tab · `⇧⌘C` copy address · `⇧⌘V` paste and go | `⌘Y` history · `⇧⌘J` downloads · `⌘,` settings · `⌥⌘L` passwords |

`⌘R` reloads the page; `⌥⌘R` reloads it from origin, checking everything cached with the site again, as Safari's Reload Page From Origin.

`⌃Tab` and `⌃⇧Tab` walk along the row of tabs; `Tab` stays the page's, for moving through a form. `esc` puts away whatever is open.

With Split View on, `⌥⌘N` splits the current page and `⌃⌘←` / `⌃⌘→` go from one page to the other. `⌘W` closes the focused tab and gives the remaining page the whole area. Tabs › Separate Split Tabs keeps both tabs open separately.

---

## For developers

### Why the source is here

So anyone can read exactly what a browser handling their passwords and history is doing, build it themselves, or fix something that bothers them. The code is small enough to actually read — about 42,000 lines of Swift, no dependencies beyond what Apple ships with macOS, one file per concern.

### Building it

- macOS 14 or later, Xcode 16 / Swift 6 toolchain
- `swift build` — runs the app straight from the SwiftPM binary
- `./build.sh` — assembles a real, double-clickable `Search.app` in `build/`, ad-hoc signed so it runs on your own Mac

A build you make yourself won't be notarized or carry Office Commun's Developer ID, so the first launch needs a right-click → Open (or an allow in System Settings → Privacy & Security). That's expected — it's the same thing that happens with any app that isn't from the App Store or a notarized DMG. Your own build also keeps its passwords apart from a signed Search's: the keychain tells the two apart by their signatures.

`./build.sh release dmg` also makes `Search.dmg` / `Search.zip`. `./build.sh release ship` additionally notarizes and staples — that step needs a Developer ID certificate and Apple credentials, so it only really does anything for Office Commun's own releases.

### How it's put together

- **SwiftUI** for everything drawn, **AppKit** for the handful of things SwiftUI doesn't reach on macOS (the window's title bar, dragging the window by an empty part of the tab row), **WKWebView** for pages.
- One `Tab` per page. Its web view is built lazily — a tab restored from last session doesn't cost a process until you switch to it. That's most of why launching with twenty tabs is still instant. Each page runs in WebKit's own content process, as in Safari; a tab you close is really gone.
- The ad blocker is a `WKContentRuleList` compiled once at launch and enforced inside WebKit's networking, before a request is made — zero cost at run time, unlike a JavaScript blocker.
- Hidden elements are a per-site list of selectors injected as a stylesheet at document start, so nothing is ever seen appearing and vanishing.
- Every colour is a light/dark pair in `Design.swift`, resolved by the window's appearance; nothing else in the code knows which mode it is in.
- Extensions run on `WKWebExtension` (macOS 15.4+). `Crx.swift` fetches an extension from the Chrome Web Store's public update address and checks the CRX3 signature against the extension's id before anything is unpacked. `Extensions.swift` is the browser's side of WebKit's contract — tabs, the window, permissions, popups. `ExtensionShims.swift` adds, at install, a small script to the extension's worker, pages and content scripts: it defines the Chrome APIs WebKit lacks — `userScripts`, `privacy`, `browsingData`, `sessions`, the old FileSystem API and more — as calls answered natively by Search, and mends the places where WebKit behaves differently from Chrome: replies from pages that don't answer, listeners added after a worker starts, workers WebKit loses track of, members and constants it leaves out. Extension pages are served from `chrome-extension://<id>/`, the address they have in Chrome, so servers and sites recognise them. `./bench ext-*` drives all of it from the shell against a test run. `ExtensionNative.swift` speaks Chrome's native messaging to hosts registered in Chrome's `NativeMessagingHosts` folders.
- `Sources/Search/` is one file per concern: `Vault.swift` is the keychain, `Shield.swift` the ad blocker, `Curtain.swift` the hidden elements, `Session.swift` what comes back at launch, `Updater.swift` the update, `Bench.swift` the test socket, `Agent.swift` the agent's hands over it, `Bot.swift` the bot over the page, and so on. There's no framework of its own to learn first.

### Testing it without closing it

Turn on **Settings › General › Let a script drive Search** and the running app listens on a Unix socket in its own folder (readable by your user only). `./bench` at the root of the repository speaks it:

```
./bench open https://example.com     # a tab of its own, at the end of your row, marked with a flask
./bench wait 2e7e7e89                 # until it has loaded
./bench text 2e7e7e89                 # the page's text
./bench shot 2e7e7e89 out.png         # a picture of it
./bench click 2e7e7e89 "button.go"    # click, type, submit — through the page's own events
./bench probe                         # the window's state: open panels, a modal, every window
./bench close all
```

Bench tabs are never selected for you, never enter the session or the history, and go when the script says so. It is how this browser is tested while somebody is using it.

`python3 Tests/split_view.py`, after `./build.sh`, checks Split View through the app's own model in a hidden test run with its own settings and files, all removed afterwards. It never makes or shows a window; what can only be seen (dragging onto a page's edge, the divider under the pointer, the motion) is checked by hand on a release candidate.

### An agent at the wheel

The same socket, under the same consent switch, speaks an agent's view of the browser — `Agent.swift`, one file, no service of ours behind it. A model, or a shell script, opens pages of its own, names them, and works them:

```
./bench agent open https://example.com signin   # a page of the agent's, named
./bench agent pages                             # its pages, by name
./bench agent snapshot signin                   # the page in words, a number a thing
./bench agent act signin fill "@3" "me@here.com"  # …by that number, by role and name, or by words
./bench agent act signin click "text=Sign in"
./bench agent read signin "@3"                  # the words at a thing, its value, where a link goes — a table as its rows, a list as its items
./bench agent console signin 30                # the page's own story: its console, its errors, its network, the last 30 lines
./bench agent wait signin target "#done"
./bench agent close signin                      # one of its own, gone
```

A snapshot is the page as a model reads it — `button "Sign in" @12`, `textbox "Email" @3`, states such as `[checked]` in brackets — one line a thing, hidden things not listed, numbers good until the next snapshot; what a page holds in a shadow host of its own is walked under a line of its own (`shadow @5`), found like the page's own. A target is a number from the list (`@3`), words on the thing (`text=Sign in`), a role and a name (`loc=role:button[name='Sign in']`), or a plain selector. Filling types the way pages listen for (React hears it); Enter submits the form the field is in; a `<label>` stands for its field. A click counts only where a person could make it — something drawn over the thing is refused, an overlay that lets clicks through goes. Agent pages are bench pages: never selected for you, out of the session and the history, gone when the script says so.

`./bench agent run` hands a task in words to a model and lets it work: one act a line (`ACT fill @3 me@here.com`), the page back after each, until it answers in words (`ANSWER …`) — twelve steps by default, forty at most — or ends where only a person can go on (`HUMAN <words>`: a password, a code from another place, a payment), answering `{"human": "…"}` instead of burning its steps. `ACT console 30` reads the page's own story — its console, its errors, its network — and what went badly rides along with every snapshot besides: the last few warnings, errors and failed fetches, said beside the page's looks without being asked for. The provider is whichever the AI add-on speaks, a local one included; the add-on is still held back from release, and tests point it at a stand-in. Nothing leaves the Mac but the model's own request, when one is asked for.

`python3 Tests/agent_automation.py` checks both sides of it — the hands against a form of the test's own, and the carrier against a stand-in model that plays the model's part, the same hidden way every suite here runs — and a third case against a page with a shadow host, a button buried under something and one under an overlay that lets clicks through, and a fourth against a page that talks: console lines, a thrown error, a fetch that comes back 404, and the snapshot that carries what went badly with it.

### The browser as an agent CLI's tool

The same story the other way round, for Claude Code, Codex and any agent that speaks MCP. Inside the app sits `search-mcp`, a small MCP server over stdio with the agent surface's own verbs as its tools — `open_page`, `snapshot`, `act`, `read`, `wait`, `close_page`, `list_pages` — each one a `do: "agent"` request to the same socket, so nothing the bench stands for changes: the switch, the flask-marked pages of the agent's own, this Mac's user only. The bridge runs nothing on the Mac itself — no shell, no files, only pages.

**Settings › Browser Use** is where it is met: the switch (the bench's own, one consent in both places), the config that registers the server with Claude Code (`.mcp.json`, or a `claude mcp add` line) or Codex (`config.toml`) — copyable, the path filled in from wherever this app is — the skills folder with its shelf, which one button links into `~/.claude/skills` so the same `SKILL.md` folders serve the browser's bot and Claude Code alike, the MCP servers the bot itself keeps (shown, not shared), and the words that explain what all of it does. **Agents' pages out of sight**, on the same page, takes the agents' tabs out of the row entirely: they work on as ever — the bridge, `./bench`, every verb — but nothing of them is drawn, no flask and no titles, and ⌘K and the number keys reach only what you can see; the page says how many are at work, unseen.

`python3 Tests/mcp_bridge.py` speaks to the bridge as an agent CLI would, over pipes against a hidden run: the handshake, a page opened and snapshotted and filled and submitted and read and closed, and the browser nowhere to be found — said so, not a dead line.

### Bots and independent conversations

**Bots**, at the bottom of the sidebar (or File › Bots), opens a workspace rather than a web tab. A Bot is a reusable profile: its name, standing role, provider, model, thinking depth, step budget, and explicitly granted capabilities. Create, edit, duplicate, pin, archive or delete a Bot from its roster. Deleted Bots remain under Show archived so their conversations can still be read.

Each Bot can have many independent conversations. Open one from its conversation list, or use **Open beside** to display another alongside it. Up to four panes can be visible, with draggable dividers; narrow windows scroll horizontally rather than squeezing the conversations into unreadable columns. Closing a pane or returning to the browser does not stop its work. Each conversation has its own draft, transcript, streaming answer, thinking display, cards, approval and Stop.

Different conversations can run concurrently, including conversations with the same Bot. A conversation runs one turn at a time; the app admits four simultaneous turns, with one slot for the built-in local model, and queues the rest. Stop cancels only the selected conversation. Late replies from a stopped turn cannot continue a tool call or write into a newer turn.

Conversations do not automatically read every tab. **Pages** on a pane explicitly attaches pages from a window and Space, or opens a work page. Those pages use the Space's existing sign-ins, not an isolated computer or browser profile. Switching the front window does not change a conversation's targets. Two conversations working the same page wait for one another; snapshot references are scoped to a run, and changed targets are refused rather than clicked under an old approval.

Bot instructions do not grant authority: browser work, shell commands, clipboard, history, memory, scheduling, MCP tools and Skills have runtime capability checks. Auto cannot enable a capability the Bot was not given. Closing a user's tab still asks. Unattended tasks remain restricted to their own pages. Private-page conversations require a local model, are not saved, and cannot later be switched to a cloud provider with their private history.

Profiles and conversations are stored separately under the app's `Bots` folder, with owner-only permissions and atomic writes. Drafts, answers, action results and cards are restored; raw thinking and keys are not stored there. Runs left active or awaiting approval restore as interrupted, never replaying a click, command or approval. Bot memory belongs to its profile; clearing one conversation does not erase every Bot's memory.

File › New Agent Chat creates a conversation in this workspace; Bot on This Page attaches the explicit page. The old tab/panel interfaces below are retained only as probe adapters for regression testing, using the same execution engine, not a second production chat system.

`python3 Tests/bots_workspace.py` checks concurrent streaming, history isolation, pane lifetime, cancellation, session/run-bound approvals, independent pages, page-lease handoff and restart recovery against a local stand-in model. `swift test --filter BotsTests` covers the data model, capabilities and protected storage. To test while your usual app is running, build to another directory with `SEARCH_BUILD_ROOT=/tmp/search-bots ./build.sh` and point the Python suites at it with `SEARCH_TEST_APP=/tmp/search-bots/Search.app`.

### Legacy bot probe surface

The agent's socket works a page at arm's length; the bot is the same hands over the page you're on. ⌥⌘B summons it (`Bot.swift`): a small panel where you say what you want done — "sign this up with my usual email" — and the model reads the page, says what it's about to do, and does it, act by act, with the same numbers and words a snapshot gives. Every click and every filled field waits for your Allow; reads are free; Auto on the panel stops the asking until you turn it off again. While it works, the stop at the panel's foot cuts the reply where it stands — the words gone, nothing of them carried to the model, no question asked again; a command it started is stopped with it, and an act still waiting is let go, and told so. The Agent Chat's own stop cuts the same way. The Works on switch sets its reach: the page you're on, or one talk over every tab — every tab listed to it by a short name, the one you're shown marked, each act carrying the tab it's for.

When it has something better than words — a form checked over, a choice to pick — it draws a card in the panel, native controls drawn from [A2UI](https://bbc6bae9.github.io/a2ui-swift/) messages: `{"ui":[…]}`, a list of `createSurface` / `updateComponents` and the rest, rendered by the one dependency the app carries (`a2ui-swift`). A card is a picture with controls, never code from a model; a button you tap goes back as an event, with what the card holds.

Beyond the page it can ask for four more things. `{"run": "…"}` runs a command on this Mac — zsh, a minute at most, what it printed going back with the next showing — and `{"copy": "…"}` puts words on your clipboard, both held for your Allow like any act, Auto aside. `{"history": 20}` is where you've been, the last pages told most recent first, a hundred at most — a read of your own going-about, held for your Allow like the rest. `{"note": "…"}` keeps a thought about you for every talk to come — what you prefer, what you're after — held for your Allow, told to the bot from the start of every talk on any page, a hundred thoughts at most, and let go with the rest when the talk is cleared. And `{"close": "…"}` closes a tab, `this` for the page you're on — the one act that asks even under Auto, for a tab is yours to close. An Always on a held act covers the page's own acts only; everything here still asks, Auto aside. And `{"human": "…"}` says where only you can go on — a password, a code from another place, a payment — and ends the turn there, the words shown as an answer's own shape with an edge around it; it touches nothing, so it waits for no Allow, and it is never for what's merely hard.

A model that thinks shows its thoughts as they come — muted, in italics, over the saying they were on the way to — and they are never read back to it; what a command or a tool said is shown under its act, the command and what it printed, a tool's reply, so what the model was shown is read on the panel.

The bot is off until asked for (Settings › AI, "The bot on pages"), and independent of the AI add-on's holdback — it ships. It speaks the same providers, a local one included, under the same first-use notice before anything leaves the Mac, and a private tab takes only what runs on this Mac. A talk closed is set down for the page it was on, taken up again when the panel comes back — the trash on the panel lets it go for good.

`python3 Tests/bot_panel.py` checks it the same hidden way — a task carried act by act against a form of the test's own, each act held for allowing and once refused, Auto on, a card drawn and tapped, the notice a provider off this Mac is asked first, a talk set down and taken up again, a command run and its telling gone back, where you've been read for the asking, words to the clipboard, a thought kept and told in the next talk, a thinking model's thoughts shown before its answer and not read back, and a turn stopped midway with nothing of it carried after, an act let go when the turn is stopped, and a command stopped with it before it can finish.

### Legacy Agent Chat probe surface

**File › New Agent Chat** makes a tab that is a talk, not a page: the bot's own conversation, in the column it's read in or across the whole tab as the switch at its top right sets it, there for as long as you keep the tab. Its reach is every tab you have open — the row is listed to it (itself never among the listing), and the page in front is its page of the moment; when you're on the chat itself, none is, and every act names its tab. The rules are the bot's own, unchanged: every act waits for your Allow, an Always covers the page's own acts, everything beyond the page asks, and a close always asks. A model that thinks shows its thoughts as they come — muted, over the saying they were on the way to — and they are never read back to it. The tab is closed like any tab and its talk goes with it; it pins to nothing, splits with nothing, is scripted to nobody, and is not kept for the next time the browser opens.

`python3 Tests/chat_tab.py` checks it the same hidden way — the tab made and standing in the row by name, every tab listed to the model with the chat itself left out, an act on a named tab held for allowing and read back, a command beyond the page refused, a close asked even under Auto, the talk gone with its tab, the width switch set either way and back again, and a thought shown before its answer and never read back to the model.

### Tools beyond the page, and skills of your own

Settings › AI now speaks in tabs: AI itself, MCP, Skills, and Tasks. The MCP tab holds servers — the tool-bearers of the Model Context Protocol — by a command to run on this Mac (stdio, one JSON object a line of its pipes) or an address to ask over HTTP (the streamable way: pages of tools by their cursor, a session id kept and said back), with headers of your own given along with every request — a token to say who's asking, or whatever else the server wants to hear. A server is switched on or off as it stands; its tools are listed when it's called on, and come to the model qualified by the server's name — `notes · add_note`, what it takes with it. A tool called from the bot waits for your Allow like any other act, Auto aside; the Ask panel offers only the tools a server says read only.

A skill is a folder of your own with a `SKILL.md` in it — a name and a description in the frontmatter, the rest its words — kept in the app's own skills folder, wherever the tab says. Enabled skills are listed to the model with the page; the body is read only when called on, and it comes back to the model as its briefing, not as an act on anything. Skills live on this Mac and go no further than the model's prompt.

`python3 Tests/mcp_skills.py` checks both against stand-ins of the test's own — one over pipes, one over HTTP with paged tools, a session id and a header of its own wanted at the door, the bot calling a tool held for allowing and a skill read into the next ask, the panel offered only what reads — the same hidden way every suite here runs.

### A task for later

Ask the bot for something at a time to come — *buy this ticket at eight tomorrow morning*, or *every ten minutes, pull the feed and pick out the AI news* — and the model sums the task up in its own words and sets it before you for your Allow: `{"later": {"goal": "…", "at": "…", "every": 600}}`, the time ISO 8601 and, for a task that comes round again, the gap in seconds (a minute at least; the first time can be left out and is one gap from now). The task is kept on this Mac with the page it was asked over (Settings › AI › Tasks); when the time comes, the page is opened again — behind whatever you are doing, taking nothing from you — and the bot let loose on it with Auto on: its acts on the page go ahead, and nothing beyond the page goes at all, for there is no one there to allow it. Its answer is kept with the task; a round that ends at what only a person can do — a password, a code from another place, a payment — is kept as waiting for you, neither failed nor done, its words kept with it. A time that can't be read, or one already come, is said so and nothing kept; a time that passes with Search closed is marked missed, not run late. A task with a gap comes round until you take it off: each round's answer is kept with it, rounds that find Search closed are skipped to the next rather than piled up, and a round that goes wrong tries again at its next time.

`python3 Tests/chores.py` checks it the same hidden way — a task noted from the words that asked for it, a time said so, a task come due let loose on a form of the test's own to its answer, a missed one, and a task that comes round again setting its next round — against a stand-in model on this Mac.

### Contributing

Issues and pull requests are genuinely welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for how this is reviewed and what tends to get merged. The short version: small changes, no new dependencies, nothing that phones home. Found a security problem? Please report it privately, as [SECURITY.md](SECURITY.md) says.

### License

MIT — see [LICENSE](LICENSE). Do what you want with the code. "Search" and the app icon are Office Commun's; please rename a fork before distributing it under another name.
