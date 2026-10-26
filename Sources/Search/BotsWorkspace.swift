import SwiftUI

struct BotsWorkspace: View {
    @ObservedObject var browser: Browser
    /// In the window beside the page, rather than over it: the header loses
    /// the way back — the panel's own × puts it away, and the conversation's
    /// own door fills the stage with it.
    var embedded = false
    @ObservedObject private var bots = Bots.shared
    @State private var selected: UUID?
    @State private var query = ""
    @State private var navigation = true
    @State private var archived = false
    @State private var editing: BotProfile?
    @State private var renaming: BotSession?
    @State private var confirming = false
    @State private var asking = ""
    /// The width the workspace was last laid out at — its own, not the
    /// window's, so a picture of it at 300 points lays out as 300 points do.
    @State private var laid: CGFloat = 0
    @State private var destructive: (() -> Void)?

    /// The least a pane keeps, in the workspace's own window, where it is
    /// given the whole of it. Beside the page the pane takes whatever room
    /// the panel has: one conversation, and no scroller over its foot.
    private var paneMin: CGFloat { 320 }

    /// The navigator's column. Its 168 points are what a Bot's name and the
    /// line beneath it want, but the panel can be pulled to 300, and 168 of
    /// those leave the conversation 131 — a strip it cannot be read in. So
    /// the column gives way with it, down to the last 120 where a name and a
    /// dot still fit, and the conversation keeps the rest.
    private func column(_ room: CGFloat) -> CGFloat {
        guard embedded else { return 204 }
        guard room > 60 else { return 168 }
        return max(120, min(168, room * 0.45))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Door(icon: "sidebar.left",
                     help: navigation ? "Hide Bots and conversations" : "Show Bots and conversations") {
                    navigation.toggle()
                }
                Text("Bots").font(.system(size: 16, weight: .semibold))
                // How much is moving and how much is waiting, and nothing at
                // all when neither is: a quiet workspace reads as quiet
                // rather than as a row of zeroes.
                if !tally.isEmpty {
                    Text(tally)
                        .font(.system(size: 11))
                        // Waiting on you is the one thing in this row worth
                        // the colour the door's dot and the row's dot use;
                        // a run going on is said in the muted grey of rest.
                        .foregroundStyle(bots.needsYou > 0 ? Palette.unsafe : Palette.muted)
                        .lineLimit(1)
                        .transition(.opacity)
                }
                Spacer(minLength: 0)
                if embedded {
                    Door(icon: "xmark", help: "Hide Bots — conversations keep running") {
                        browser.hideBots()
                    }
                } else {
                    // Only when the column is away and its own + is not there
                    // to be found.
                    if !navigation {
                        Button("New Bot") { editing = BotProfile(provider: browser.prefs.aiProvider) }
                    }
                    Button("Back to browser") { browser.hideBots() }
                }
            }
            .padding(embedded ? 10 : 14)
            Divider()
            if let error = bots.error { Caution(error).padding(10) }
            HStack(spacing: 0) {
                if navigation {
                    navigator.frame(width: column(laid))
                    Divider()
                }
                GeometryReader { geometry in
                    let ids = browser.botWorkspace.panes.filter { bots.session($0) != nil }
                    if ids.isEmpty {
                        VStack(spacing: 14) {
                            Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 32))
                            Text("A Bot, many conversations").font(.headline)
                            Text("Choose a Bot and start a conversation. Conversations are listed in the column; one is shown at a time.")
                                .foregroundStyle(Palette.muted).multilineTextAlignment(.center)
                            if let id = selected ?? bots.defaultID, let profile = bots.profile(id) {
                                if profile.provider == nil {
                                    Text("This Bot has no AI chosen yet — a conversation needs one before it can run.")
                                        .foregroundStyle(Palette.muted).multilineTextAlignment(.center)
                                    Button("Set up the AI…") {
                                        browser.hideBots()
                                        browser.settingsPage = .ai
                                        browser.tuning = true
                                    }
                                } else if profile.deleted || profile.archived {
                                    Text("This Bot is \(profile.deleted ? "removed" : "archived") — unarchive it to start a conversation.")
                                        .foregroundStyle(Palette.muted).multilineTextAlignment(.center)
                                } else {
                                    Button("New conversation") { newSession(id) }
                                }
                            } else {
                                // No Bot at all to choose — the column's + is
                                // the only other way to make one, and it is a
                                // menu behind an icon.
                                Button("New Bot") { editing = BotProfile(provider: browser.prefs.aiProvider) }
                            }
                        }
                        .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        // One conversation, in all the room there is: there is
                        // nothing to scroll sideways through any more, and a
                        // scroller drawn here would lie over the conversation's
                        // own foot — the line that says the AI may be wrong.
                        // Narrower than a pane's least it wraps its words
                        // instead of clipping them, which is what a panel
                        // pulled narrow asks for.
                        paneGrid(ids)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                }
            }
            // Where the two rooms divide: taken from the layout that was
            // drawn, on the pass after it, rather than guessed from the
            // window's own width.
            .background(GeometryReader { whole in
                Color.clear
                    .onAppear { laid = whole.size.width }
                    .onChange(of: whole.size.width) { _, width in laid = width }
            })
        }
        .background(Palette.ground)
        .foregroundStyle(Palette.ink)
        // Its own room as laid out, for the tests that check the page keeps
        // the rest of the window (see BotsBench's "room").
        .background(GeometryReader { room in
            Color.clear.preference(key: BotsRoom.self, value: room.frame(in: .global))
        })
        .sheet(item: $editing) { profile in BotProfileEditor(profile: profile) }
        .sheet(item: $renaming) { session in
            BotSessionRename(session: session)
        }
        .confirmationDialog(asking, isPresented: $confirming, titleVisibility: .visible) {
            Button("Continue", role: .destructive) { destructive?(); destructive = nil }
            Button("Cancel", role: .cancel) { destructive = nil }
        }
        .onAppear {
            bots.configure(browser.prefs, browser: browser)
            if selected == nil {
                selected = browser.botWorkspace.focused.flatMap(bots.session)?.profileID ?? bots.defaultID
            }
            MCPHub.shared.wake()
        }
        .onChange(of: browser.botWorkspace.focused) { _, id in
            if let id, let session = bots.session(id) { selected = session.profileID }
        }
        .onPreferenceChange(BotsRoom.self) { room in
            browser.botRoom = room
        }
        // While the panel is there, a blank page beside it keeps its empty
        // box to itself: the panel is what is being typed in.
        .onAppear { browser.botTyping = true }
        .onDisappear { browser.botTyping = false }

    }

    /// What stands beside the name in the header: how much is moving, how
    /// much is waiting, and nothing when neither, so a quiet workspace reads
    /// as quiet rather than as a row of zeroes.
    private var tally: String {
        let running = bots.running, needs = bots.needsYou
        if needs > 0 { return running > 0 ? "\(needs) need you · \(running) running" : "\(needs) need you" }
        return running > 0 ? "\(running) running" : ""
    }

    private var roster: [BotProfile] {
        bots.profiles.filter { (archived || (!$0.archived && !$0.deleted))
            && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.role.localizedCaseInsensitiveContains(query)) }
            .sorted { left, right in
                let leftNeeds = bots.sessions.contains { $0.profileID == left.id && ($0.runtime.pending != nil || $0.runtime.runState == .waitingHuman) }
                let rightNeeds = bots.sessions.contains { $0.profileID == right.id && ($0.runtime.pending != nil || $0.runtime.runState == .waitingHuman) }
                if leftNeeds != rightNeeds { return leftNeeds }
                if left.pinned != right.pinned { return left.pinned }
                return left.updated > right.updated
            }
    }

    private func summary(_ profile: BotProfile) -> String {
        if profile.deleted { return "Deleted · history only" }
        if profile.archived { return "Archived" }
        let sessions = bots.sessions.filter { $0.profileID == profile.id && !$0.archived }
        let attention = sessions.filter { $0.runtime.pending != nil || $0.runtime.runState == .waitingHuman }.count
        if attention > 0 { return "\(attention) need you" }
        let active = sessions.filter { $0.runtime.busy }.count
        if active > 0 { return "\(active) active" }
        return profile.role.isEmpty ? "\(sessions.count) conversations" : String(profile.role.prefix(40))
    }

    /// Whether a Bot or a conversation has a run going, so the question about
    /// a destructive choice only mentions stopping one when one exists.
    private func moving(_ profile: BotProfile) -> Bool {
        bots.sessions.contains { $0.profileID == profile.id && $0.runtime.busy }
    }

    /// The conversations of the Bot on show, as the column lists them.
    private func conversations(_ profile: BotProfile) -> [BotSession] {
        bots.sessions
            .filter { session in
                session.profileID == profile.id
                    && (archived || !session.archived)
                    && (query.isEmpty
                        || session.title.localizedCaseInsensitiveContains(query)
                        || profile.name.localizedCaseInsensitiveContains(query))
            }
            .sorted { $0.updated > $1.updated }
    }

    private var navigator: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The column is 168 points in the window beside the page, so the
            // field's own words have to be short enough to survive in it.
            TextField("Search", text: $query, prompt: Text("Search").foregroundStyle(Palette.faint))
                .textFieldStyle(.roundedBorder).font(.system(size: 11))
                .help("Search Bots and conversations")
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    heading("BOTS") {
                        Menu {
                            Button("New Bot") {
                                editing = BotProfile(provider: browser.prefs.aiProvider)
                            }
                            if let profile = (selected ?? bots.defaultID).flatMap(bots.profile),
                               !profile.deleted {
                                Button("Edit \(profile.name)…") { editing = profile }
                                Button("Duplicate \(profile.name)") { bots.duplicate(profile) }
                            }
                        } label: { Image(systemName: "plus") }
                        .menuStyle(.borderlessButton).fixedSize()
                        .help("New Bot")
                    }
                    if roster.isEmpty {
                        hint(query.isEmpty ? "No Bots yet — make one with +."
                                           : "No Bots match “\(query)”")
                    }
                    ForEach(roster) { profile in
                        BotProfileRow(profile: profile, selected: selected == profile.id,
                                      subtitle: summary(profile)) {
                            selected = profile.id
                        }
                        .contextMenu {
                            Button("Edit Bot…") { editing = profile }
                            Button("Duplicate") { bots.duplicate(profile) }
                            Button(profile.pinned ? "Unpin" : "Pin") {
                                var copy = profile; copy.pinned.toggle(); bots.put(copy)
                            }
                            Button(profile.archived ? "Unarchive" : "Archive") {
                                let active = moving(profile)
                                confirm(profile.archived ? "Unarchive this Bot?"
                                        : active ? "Stop this Bot’s runs and archive it?"
                                                 : "Archive this Bot?") {
                                    var copy = profile; copy.archived.toggle(); bots.put(copy)
                                    // A Bot out of the list is not what the
                                    // column should still be reading.
                                    if copy.archived, selected == copy.id { selected = bots.defaultID }
                                }
                            }
                            Button("Delete Bot", role: .destructive) {
                                let active = moving(profile)
                                confirm(active ? "Stop this Bot’s runs and remove it? Its conversations are kept."
                                               : "Remove this Bot? Its conversations are kept.") {
                                    var copy = profile; copy.deleted = true; bots.put(copy)
                                    if selected == copy.id { selected = bots.defaultID }
                                }
                            }
                        }
                    }
                }
                Divider().padding(.vertical, 10)
                if let profile = (selected ?? bots.defaultID).flatMap(bots.profile) {
                    heading("CONVERSATIONS") {
                        Menu {
                            Button("New conversation") { newSession(profile.id) }
                            Button("New with current page") {
                                newSession(profile.id, tabs: browser.active.map { [$0] } ?? [])
                            }
                        } label: { Image(systemName: "plus") }
                        .menuStyle(.borderlessButton).fixedSize()
                        .disabled(profile.deleted || profile.archived)
                        .help("New conversation")
                    }
                    if profile.deleted || profile.archived {
                        hint("This Bot is \(profile.deleted ? "removed" : "archived") — unarchive it to start a conversation.")
                    }
                    let listed = conversations(profile)
                    if listed.isEmpty {
                        hint(query.isEmpty ? "No conversations yet — start one with +."
                                           : "No conversations match “\(query)”")
                    }
                    ForEach(listed) { session in
                        BotSessionRow(session: session, selected: browser.botWorkspace.panes.contains(session.id)) {
                            browser.show(session)
                        } close: {
                            browser.closeBotPane(session.id)
                        }
                        .contextMenu {
                            Button("Rename…") { renaming = session }
                            Button(session.archived ? "Unarchive" : "Archive") {
                                let active = session.runtime.busy
                                confirm(session.archived ? "Unarchive this conversation?"
                                        : active ? "Stop this run and archive the conversation?"
                                                 : "Archive this conversation?") {
                                    bots.archive(session, !session.archived)
                                }
                            }
                            Button("Delete conversation", role: .destructive) {
                                let active = session.runtime.busy
                                confirm(active ? "Stop this run and delete the conversation?"
                                               : "Delete this conversation?") {
                                    browser.botWorkspace.close(session.id)
                                    bots.delete(session)
                                }
                            }
                        }
                    }
                }
            }
            // The two lists are the column; this is a switch over them, and
            // a line keeps it from reading as the last row of the second.
            Divider().padding(.top, 2)
            Toggle("Show archived", isOn: $archived).font(.system(size: 10))
        }
        .padding(10)
    }

    /// A heading over a run of rows, with the way to add one at its end —
    /// the same shape for both lists, so the column reads as two of a kind.
    private func heading<Add: View>(_ words: String,
                                    @ViewBuilder add: () -> Add) -> some View {
        HStack(spacing: 6) {
            Text(words).font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.faint)
            Spacer(minLength: 0)
            add()
        }
    }

    /// What a list says when it has nothing to show, so a search that finds
    /// nothing and a Bot that has not started yet never look broken.
    private func hint(_ words: String) -> some View {
        Text(words)
            .font(.system(size: 10)).foregroundStyle(Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 2)
    }

    /// The conversation on show: one at a time, so there is no grid to lay
    /// out and no split to pull — the navigator is how you go between them.
    @ViewBuilder private func paneGrid(_ ids: [UUID]) -> some View {
        if let id = ids.first { pane(id) }
    }

    @ViewBuilder private func pane(_ id: UUID) -> some View {
        if let session = bots.session(id) {
            BotChatView(browser: browser, session: session, embedded: embedded,
                        focused: browser.botWorkspace.focused == id)
                .frame(minWidth: embedded ? 0 : paneMin, minHeight: 180)
                .id(id)
        }
    }

    private func newSession(_ profile: UUID, tabs: [Tab] = []) {
        if let session = bots.create(profileID: profile, browser: browser, tabs: tabs) {
            browser.show(session)
        }
    }
    /// Asking before something is thrown away, in the words of what is
    /// actually being thrown away: only the choices that stop a run say so.
    private func confirm(_ question: String, _ action: @escaping () -> Void) {
        asking = question
        destructive = action
        confirming = true
    }
}

/// One Bot in the column: the sidebar's row manners — the wash of the one
/// chosen, the grey of the one under the pointer, the quickness of both.
private struct BotProfileRow: View {
    let profile: BotProfile
    let selected: Bool
    let subtitle: String
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: profile.avatar)
                    .frame(width: 18)
                    .foregroundStyle(selected ? Palette.ink : (hovering ? Palette.ink.opacity(0.7) : Palette.muted))
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name).font(.system(size: 12, weight: .medium))
                    Text(subtitle)
                        .font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
                if profile.pinned {
                    Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Palette.muted)
                }
            }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Palette.wash : (hovering ? Palette.hover : .clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        // The icon is a symbol name, and the subtitle may be a count of
        // conversations rather than the Bot's own words: the row reads as
        // what it says, and says whether it is the one on show.
        .accessibilityLabel(subtitle.isEmpty ? profile.name : "\(profile.name), \(subtitle)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// One conversation in the column, as the sidebar's tabs are a row: a dot
/// for where its run stands (amber while it waits for you, as the door's
/// dot does; orange while it works; red when a run ended badly; the grey
/// of rest otherwise), the wash of the one shown, the grey of the one under
/// the pointer — and the pointer's cross, which closes the pane and leaves
/// the conversation running, as the pane's own cross does.
private struct BotSessionRow: View {
    @ObservedObject var session: BotSession
    let selected: Bool
    let open: () -> Void
    let close: () -> Void
    @State private var hovering = false

    private var dot: (colour: Color, words: String) {
        let bot = session.runtime
        if bot.pending != nil || bot.runState == .waitingHuman {
            return (Palette.unsafe, "waiting for you")
        }
        // Queued is not working: the run has a place in the line and hasn't
        // been given the page yet, and a dot that says "working" over a run
        // that hasn't started is the one thing this dot must not say.
        if bot.runState == .queued { return (Palette.muted, "waiting its turn") }
        if bot.runState.active { return (.orange, "working") }
        switch bot.runState {
        case .failed: return (.red.opacity(0.8), "failed")
        case .interrupted: return (.red.opacity(0.8), "interrupted — nothing was replayed")
        default: return (Palette.faint.opacity(0.4), "")
        }
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Circle().fill(dot.colour).frame(width: 6, height: 6)
                Text(session.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.leading, 10)
            .frame(height: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(selected ? Palette.ink : (hovering ? Palette.ink.opacity(0.7) : Palette.muted))
            // The title keeps its length under the pointer and fades out
            // beneath the cross, as a tab's does, so its end doesn't jump.
            .mask {
                ZStack {
                    Rectangle().opacity(hovering ? 0 : 1)
                    HStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 16)
                        Color.clear.frame(width: 26)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Palette.wash : (hovering ? Palette.hover : .clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            if hovering, selected {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 15, height: 15)
                    .background(Palette.ink.opacity(0.07), in: Circle())
                    .transition(.opacity)
                    .overlay {
                        Color.clear
                            .frame(width: 30, height: 28)
                            .contentShape(Rectangle())
                            .onTapGesture { if hovering { close() } }
                    }
                    .padding(.trailing, 7)
                    .help("Close pane — conversation keeps running")
            }
        }
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .help(dot.words.isEmpty ? session.title : "\(session.title) — \(dot.words)")
        // The dot is the only sign of a run's state, and colour alone says
        // nothing aloud: the words it stands for ride the row.
        .accessibilityLabel(dot.words.isEmpty ? session.title : "\(session.title), \(dot.words)")
    }
}

private struct BotSessionRename: View {
    @ObservedObject var session: BotSession
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename conversation").font(.headline)
            TextField("Title", text: $name).textFieldStyle(.roundedBorder)
            HStack { Button("Cancel") { dismiss() }; Spacer()
                Button("Save") { Bots.shared.rename(session, to: name); dismiss() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 340).onAppear { name = session.title }
    }
}

private struct BotToolGrants: View {
    @ObservedObject var server: MCPServer
    @Binding var allowed: Set<String>
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(server.config.name) · \(server.state.words)").font(.caption).foregroundStyle(Palette.muted)
            ForEach(server.tools, id: \.name) { tool in
                let qualified = "\(server.config.name) · \(tool.name)"
                Toggle(qualified, isOn: Binding(get: { allowed.contains(qualified) }, set: { on in
                    if on { allowed.insert(qualified) } else { allowed.remove(qualified) }
                }))
            }
        }
    }
}

struct BotProfileEditor: View {
    @State var profile: BotProfile
    @ObservedObject private var hub = MCPHub.shared
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Bot setup").font(.headline); Spacer(); Button("Cancel") { dismiss() }
                Button("Save") { if Bots.shared.put(profile) { dismiss() } }.disabled(profile.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }.padding(16)
            Divider()
            Form {
                TextField("Name", text: $profile.name)
                LabeledContent("Icon") { faces }
                TextField("Standing role", text: $profile.role, axis: .vertical).lineLimit(3...8)
                Picker("Provider", selection: $profile.provider) {
                    Text("Choose…").tag(AIProvider?.none)
                    ForEach(AIProvider.allCases) { Text($0.name).tag(Optional($0)) }
                }
                TextField("Model", text: $profile.model, prompt: Text("Provider default"))
                Text("Provider addresses and keys stay in Settings › AI. No key is stored with this Bot.")
                    .font(.caption).foregroundStyle(Palette.muted)
                Picker("Thinking", selection: $profile.thinking) {
                    ForEach(BotThinking.allCases) { Text($0.name).tag($0) }
                }
                Stepper("Steps: \(profile.steps)", value: $profile.steps, in: 1...50)
                Section("Capabilities — still subject to approval") {
                    Toggle("Browser pages", isOn: $profile.permissions.browser)
                    Toggle("Shell commands", isOn: $profile.permissions.commands)
                    Toggle("Clipboard", isOn: $profile.permissions.clipboard)
                    Toggle("Browsing history", isOn: $profile.permissions.history)
                    Toggle("Bot memory", isOn: $profile.permissions.memory)
                    Toggle("Schedule tasks", isOn: $profile.permissions.scheduling)
                }
                Section("MCP tools") {
                    ForEach(hub.servers) { server in
                        BotToolGrants(server: server, allowed: $profile.permissions.tools)
                    }
                }
                Section("Skills") {
                    ForEach(Skills.listed()) { skill in
                        Toggle(skill.name, isOn: membership(skill.name, in: $profile.permissions.skills))
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 500, height: 650)
        .onAppear { hub.wake() }
    }

    private func membership(_ value: String, in set: Binding<Set<String>>) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(value) }, set: { on in
            if on { set.wrappedValue.insert(value) } else { set.wrappedValue.remove(value) }
        })
    }

    /// The Bot's face, chosen from the ones there are rather than typed in:
    /// a symbol name nobody knows draws nothing at all, and a row with a
    /// hole in it reads as a Bot that failed to load.
    private var faces: some View {
        HStack(spacing: 3) {
            let offered = BotProfile.avatars + (BotProfile.avatars.contains(profile.avatar)
                                                ? [] : [profile.avatar])
            ForEach(offered, id: \.self) { symbol in
                Button { profile.avatar = symbol } label: {
                    Image(systemName: symbol)
                        .font(.system(size: 12))
                        .frame(width: 26, height: 22)
                        .foregroundStyle(profile.avatar == symbol ? Palette.ink : Palette.muted)
                        .background(profile.avatar == symbol ? Palette.wash : .clear,
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(symbol)
            }
            Spacer(minLength: 0)
        }
    }
}

/// The workspace's own room in the window, as SwiftUI lays it out: the split
/// is two SwiftUI views, not two AppKit ones, so a page's view beside the
/// panel says nothing about where the panel's own edge is.
struct BotsRoom: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}
