import AppKit

// The chat view's place in a terminal: the switch that names both views,
// and the plate that lays the conversation over the grid.
//
// Both are the frame's own furniture, like the dock's plate and the
// status bar — the pane is where the agent lives, and the pane is where
// its talk is read. The switch is up whenever an agent whose transcript
// can be read is in the terminal, and pressing a side swaps the screen
// for the talk and back. What is under the plate keeps running: the same
// terminal, the same pty, with the chat's line writing into it as though
// the words had been typed at the screen.

extension TerminalView {
    /// Asks the island which agent is in this terminal, and puts the chip
    /// up, takes it down, or re-points the reader at a run that changed.
    /// Cheap enough to ask whenever anything is said — a session's talk is
    /// one comparison away — and the only thing that decides whether the
    /// chip exists at all.
    func watchTalk(_ now: [Island.Session]? = nil) {
        let all = now ?? Island.shared.sessions
        let said = all.first { $0.tty == terminal.pty }?.talk
        guard said != chatTalk else { return }
        chatTalk = said
        guard let said else {
            closeChat()
            chatPill?.removeFromSuperview()
            chatPill = nil
            return
        }
        if chatPill == nil {
            let pill = TerminalChatSwitch()
            pill.asked = { [weak self] talk in self?.showChat(talk) }
            addSubview(pill)
            chatPill = pill
            // A switch appearing for an agent the person has never opened
            // in a pane: a remembered preference to read agents as talk
            // would otherwise do nothing until the second agent in the
            // second pane.
            if TerminalLook.agentView == .talk { openChat() }
        }
        _ = chatPill?.say(said.agent.name, showing: chatShowing)
        // A run replaced under an open talk (the agent restarted, or a new
        // session in the same pane): the reader starts at the new file
        // rather than going on reading the old one.
        if chatShowing { openChat() } else { placeChat() }
    }

    /// The chip's answer, and ⌘⇧C's: the talk up if it is down, down if it
    /// is up. Nothing to switch to without an agent.
    /// A side of the switch taken: the talk up, or the screen back. Said
    /// as a target rather than a toggle so a press on the side already in
    /// use still brings the keyboard home — a person pressing "Terminal"
    /// while looking at the terminal means "put me back in it".
    func showChat(_ talk: Bool) {
        guard chatTalk != nil else { return }
        if talk != chatShowing {
            if talk { openChat() } else { closeChat() }
        } else if talk {
            if let field = chatPlate?.field, let window { window.makeFirstResponder(field) }
        } else if let window, window.firstResponder !== self {
            window.makeFirstResponder(self)
        }
        placeChat()
        present()
    }

    /// Writes the choice where the Settings window keeps it, without
    /// announcing it again when nothing changed: `terminalLookChanged`
    /// posts a notification that every pane answers, and an announcement
    /// that says the same thing twice would have each pane re-open a talk
    /// it already has.
    ///
    /// A test run writes the key itself rather than going through
    /// `Shared.prefs`. Not a shortcut: making the settings object here
    /// would build it at the moment the second terminal opens, and the
    /// store it reads pins its world at the first touch — so whichever
    /// suite happened to open a pane first would pick the defaults for the
    /// whole process, and a later suite asserting a setting would find one
    /// it never chose. (It did: the find bar test saw a find bar at the
    /// bottom because a chat test had chosen "Chat" first.)
    private func remember(_ view: TerminalAgentView) {
        guard TerminalLook.agentView != view else { return }
        if Store.testing {
            TerminalLook.agentView = view
            Store.settings.set(view.rawValue, forKey: "terminal.agentView")
        } else {
            Shared.prefs.terminalAgentView = view
        }
    }

    /// The switch's keyboard answer, and the old ⌘⇧C shape: the talk up if
    /// it is down, down if it is up. Nothing to switch to without an agent.
    func toggleChat() {
        guard chatTalk != nil else { return }
        if chatShowing {
            closeChat()
        } else {
            openChat()
        }
        _ = chatPill?.say(chatTalk?.agent.name ?? "", showing: chatShowing)
        placeChat()
        present()
    }

    /// Lays the conversation over the grid: the plate, its reader, and the
    /// keyboard in its line. The terminal under it is left alone — it is
    /// still the thing the words are written to.
    func openChat() {
        guard let talk = chatTalk else { return }
        remember(.talk)
        if chatPlate == nil {
            let plate = TerminalChatView()
            plate.spoke = { [weak self] words in self?.speak(words) }
            plate.escaped = { [weak self] in self?.toggleChat() }
            plate.switched = { [weak self] value in self?.switchModel(to: value) }
            addSubview(plate)
            chatPlate = plate
            // The chip has to stay above the talk, or the switch to go
            // back would be underneath what it switches away from.
            if let pill = chatPill { addSubview(pill) }
        }
        chatShowing = true
        var reader = ChatReader(talk: talk)
        reader.update()
        chatReader = reader
        chatPlate?.take(reader.log)
        refreshModels()
        chatPlate?.needsLayout = true
        placeChat()
        chatPlate?.needsDisplay = true
        startChatTick()
        if let field = chatPlate?.field, let window { window.makeFirstResponder(field) }
    }

    /// Takes the talk away and gives the keyboard back to the grid. The
    /// reader goes with it: a conversation nobody is looking at costs no
    /// ticks, and the file is read again from where it left off when the
    /// talk comes back.
    func closeChat() {
        remember(.screen)
        chatShowing = false
        chatTick?.invalidate()
        chatTick = nil
        chatReader = nil
        chatPlate?.removeFromSuperview()
        chatPlate = nil
        if let window, window.firstResponder !== self { window.makeFirstResponder(self) }
    }

    /// A line written in the chat, given to the terminal: the words and a
    /// return, the two things a keyboard would have sent. That is the
    /// whole of the chat's power over the agent — the CLI reads its stdin
    /// and knows nothing of the second view onto it.
    func speak(_ words: String) {
        terminal.send(words + "\r")
        // The person is done asking, and the talk follows what comes back:
        // that is the whole point of reading it here.
        chatPlate?.paper.follow()
    }

    /// The model list and the chip, from the agent's own catalog — asked
    /// again whenever the talk is opened or a tick comes back with
    /// something new, because a run that has just started (or one whose
    /// model was changed by hand in the terminal) writes the new current
    /// model where only its transcript says it.
    func refreshModels() {
        guard let talk = chatTalk else { return }
        let rows = AgentModels.rows(for: talk.agent, talk: talk)
        let now = AgentModels.current(for: talk.agent, talk: talk) ?? ""
        chatPlate?.takeModels(rows, current: now)
    }

    /// A row taken in the chat's list: the agent's own `/model` command,
    /// as though it had been typed. Same channel as everything else here —
    /// the pty — so the session's own history records the change and the
    /// screen agrees with the chip a moment later. Nothing is assumed
    /// about the answer: a model the account has lost says so in the
    /// terminal, which is where the person is looking anyway.
    func switchModel(to value: String) {
        speak(AgentModels.switchCommand(value))
    }

    /// The slow tick, up only while a talk is: the agent's file is read
    /// for what it added. A transcript is appended to, so a tick that
    /// changes nothing reads nothing — but the file is still opened, which
    /// is why this is half a second and not a frame.
    private func startChatTick() {
        guard chatTick == nil else { return }
        chatTick = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.readChat() }
        }
    }

    /// One look at the file: what it added, laid on the plate — and the
    /// plate is only asked to draw when something did come in.
    func readChat() {
        guard chatShowing, var reader = chatReader else { return }
        let grew = reader.update()
        chatReader = reader
        guard grew else { return }
        chatPlate?.take(reader.log)
        // A tick that did come back with something is the one moment the
        // agent may have written a new current model — after a `/model`
        // it ran itself, or one typed straight at the screen. Asked only
        // then, and only while the list is open: the chip alone is not
        // worth a file read half a second at a time.
        if chatPlate?.askingModels == true { refreshModels() }
    }

    /// Where the chip and the talk go. The chip sits in the pane's own
    /// corner, above the talk when one is up; a find panel standing in
    /// the same corner pushes it down rather than being covered by it.
    func placeChat() {
        guard bounds.width > 1, bounds.height > 1 else { return }
        if let pill = chatPill {
            let want = pill.wanted
            var top = bounds.height - want.height - TerminalChatSwitch.inset
            if findPanel != nil, TerminalLook.findPlace == .top {
                top -= FieldBox.height + 6
            }
            pill.frame = NSRect(
                x: bounds.width - want.width - TerminalChatSwitch.inset,
                y: top, width: want.width, height: want.height
            )
            // Not hidden on the alternate screen: that is exactly where
            // these agents live — their own interfaces take the screen
            // whole, and the chip is the one thing saying there is
            // another way to read them.
        }
        chatPlate?.frame = bounds
    }
}
