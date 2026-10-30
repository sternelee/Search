# Review context — Bots workspace redesign

## Intent
Upgrade the single page-attached bot panel into a persistent Bots workspace that lives
beside the page (right-hand split panel). Three model layers: BotProfile (reusable bot
config) / BotSession (durable independent conversation) / BotRun (one execution). Key
requirements from the design doc `Bots 工作区重设计：Bot 列表、多会话并排与独立运行.md`
(repo root, added in this diff):

- Sidebar-foot Bots door; tab-bar door; View > Bots menu; all are toggles.
- Panel is ONE conversation at a time, at the panel's own width, with the conversation
  list beside it (navigator column). Full-screen door makes the conversation take the
  whole stage; page yields (maxWidth 0), width restored on exit.
- Session-level run scheduling: up to 4 concurrent runs; runs on local models serialize.
- BotContext binds an explicit page (Space + tab UUID), never "the front window".
- BotPageLease serializes work on the same page.
- Approvals carry sessionID/runID so an approval can never cross to a sibling pane.
- Capabilities are checked at execution time, not at enqueue time.
- Persistence is private: 0600 files / 0700 dir. Private-page conversations never hit
  disk and may only use local models. No raw thinking text or API keys written into
  conversation files.
- Interrupted runs restore their history without replaying any action.
- Old entry points (page bot, scheduled Chores, the ⌥⌘B shortcut, menus) converge on the
  new session service. A Chore trigger creates its own independent session.
- Closing a pane never stops its run; only Stop, archive-while-running, delete, or quit
  end a run. Human takeover is recorded as its own ending and is not lost when a periodic
  task is re-queued.
- Also in this diff (most recent work): the conversation's foot line
  "AI — may be wrong · page" was being drawn over by a horizontal NSScroller when the
  panel was narrower than the pane minimum; the horizontal ScrollView was removed and
  `tests/bots_workspace.py` now asserts no sideways scroller plus the foot line's own rows.

## Diff scope
Diff base is `git diff HEAD` — the entire feature is uncommitted-but-staged working-tree
change on top of commit 465beed. Full unified diff (context 10) is saved at
`DIFF_PATH` (see the run directory). 40 files, +2825 / −141.

## Changed files
Sources (Swift): AI.swift, AIAssist.swift, AIClient.swift, Agent.swift, App.swift,
Bench.swift, Bot.swift, BotChatView.swift (new), BotContext.swift (new),
BotPermissions.swift (new), BotPersistence.swift (new), BotSession.swift (new),
Bots.swift (new), BotsBench.swift (new), BotsDoor.swift (new), BotsWorkspace.swift (new),
Browser.swift, ChatTab.swift, Chores.swift, Design.swift, MCP.swift, Prefs.swift,
Shortcuts.swift, Side.swift, Store.swift, TabBar.swift

Tests: Tests/SearchTests/AIAddressTests.swift, Tests/SearchTests/BotsTests.swift (new),
Tests/agent_automation.py, Tests/bot_panel.py, Tests/bots_workspace.py (new),
Tests/chat_tab.py, Tests/chores.py, Tests/mcp_bridge.py, Tests/mcp_skills.py,
Tests/site_search.py, build.sh

Docs: CHANGELOG.md, README.md, the design doc.

## How to read the code
Read the actual files in /Users/sternelee/www/github/search — the repo is the macOS
SwiftUI browser. `swift build` compiles. Python suites under Tests/ drive the built app
through a JSON bench.

## Schema + rules you must follow
- Findings schema: /Users/sternelee/.pi/agent/skills/ce-code-review/references/findings-schema.json
- Shared diff-scope rules: /Users/sternelee/.pi/agent/skills/ce-code-review/references/diff-scope.md
