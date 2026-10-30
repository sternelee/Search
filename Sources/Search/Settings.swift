import SwiftUI

/// Everything there is to set. Sections down the left, under a field that
/// finds any setting by its words (⌘F); one section at a time on the right,
/// in titled groups, each a card of rows. A row says what it is with a small
/// icon and a line of plain words, the rest behind its (i). Every row of a
/// card stands at the same level, hairlines from edge to edge; a row that
/// only counts while another is on is only there while it counts. Every
/// row comes from SettingsIndex, so what the find field finds is exactly
/// what the sections hold.
struct SettingsPanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    /// The section the tab's address names (search://settings/privacy),
    /// when Settings is a tab: asked for again, it moves there.
    var asked: String? = nil
    /// Words already in Find a setting when it opens (previews).
    var found: String? = nil
    @Environment(\.asTab) private var asTab

    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var shield = Shield.shared
    @State private var isDefault = Links.isDefault
    /// A site shortcut being written, kept out of Preferences until it's saved.
    @State private var draft: Keyword?
    @State private var page: Page = Page.named(Store.settings.string(forKey: "settings.page") ?? "") ?? .general
    /// What is typed in Find a setting.
    @State private var query = ""
    @FocusState private var finding: Bool
    /// A row gone to from a result, lit for a moment.
    @State private var lit: String?
    /// What Set Up Like Arc changed, for Undo.
    @State private var arcBefore: Preferences.ArcSetup? = SettingsPanel.arcBefore
    @MainActor static var arcBefore: Preferences.ArcSetup?

    enum Page: String, CaseIterable, Identifiable {
        case general, appearance, tabs, browsing, spaces, terminal, passwords, privacy, ai,
             extensions, browserUse, keyboard, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: return "General"
            case .appearance: return "Appearance"
            case .tabs: return "Tabs"
            case .browsing: return "Browsing"
            case .spaces: return "Spaces & Pins"
            case .terminal: return "Terminal"
            case .passwords: return "Passwords"
            case .privacy: return "Privacy"
            case .ai: return "AI"
            case .extensions: return "Extensions"
            case .browserUse: return "Browser Use"
            case .keyboard: return "Keyboard & Mouse"
            case .about: return "About"
            }
        }
        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .appearance: return "paintbrush"
            case .tabs: return "square.on.square"
            case .browsing: return "globe"
            case .spaces: return "square.stack"
            case .terminal: return "terminal"
            case .passwords: return "key"
            case .privacy: return "hand.raised"
            case .ai: return "sparkles"
            case .extensions: return "puzzlepiece.extension"
            case .browserUse: return "cursorarrow.rays"
            case .keyboard: return "keyboard"
            case .about: return "info.circle"
            }
        }
        /// A section by its name in an address or in the settings file,
        /// the old names included: Downloads is in General now, Shortcuts
        /// is Keyboard & Mouse.
        static func named(_ name: String) -> Page? {
            switch name.lowercased() {
            case "downloads": return .general
            case "shortcuts", "mouse": return .keyboard
            case "browseruse", "browser-use": return .browserUse
            default: return Page(rawValue: name.lowercased())
            }
        }
        /// The rail's three blocks: the browser, your data and tools, About.
        /// The AI page is the bot's as well as the add-on's, and the bot
        /// ships with the app, so it is always there to open.
        static var blocks: [[Page]] {
            [[.general, .appearance, .tabs, .browsing, .spaces, .terminal],
             [.passwords, .privacy, .ai, .extensions, .browserUse, .keyboard],
             [.about]]
        }
    }

    private static let rail: CGFloat = 196
    private static let column: CGFloat = 600
    private static let width: CGFloat = 720
    private static let height: CGFloat = 540
    /// Where a row's words start, past its icon. What goes under a row's
    /// words (pictures, lists, fields) starts there too.
    static let textInset: CGFloat = 52
    /// A list under a row's words starts this far in, its lines adding
    /// their own 14 to reach textInset.
    static let listInset: CGFloat = textInset - 14

    var body: some View {
        Group {
            if asTab { tabbed } else { card }
        }
        .onChange(of: browser.settingsFind) { _, _ in finding = true }
        .onAppear { if let found { query = found } }
    }

    /// In a tab of its own (see InternalPages.swift): the sections down the
    /// left, the window's whole height, and the section down the middle of
    /// the rest.
    private var tabbed: some View {
        HStack(spacing: 0) {
            pages
            Rectangle().fill(Palette.hairline).frame(width: 1)
            content
                .padding(.top, 26)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { follow(asked) }
        .onChange(of: asked) { _, asked in follow(asked) }
        .onChange(of: page) { _, page in
            Store.settings.set(page.rawValue, forKey: "settings.page")
            browser.settingsMoved(to: page)
        }
    }

    private func follow(_ asked: String?) {
        guard let asked, let wanted = Page.named(asked), wanted != page else { return }
        page = wanted
    }

    private var card: some View {
        HStack(spacing: 0) {
            pages
            Rectangle().fill(Palette.hairline).frame(width: 1)
            content
        }
        .frame(width: SettingsPanel.width, height: SettingsPanel.height)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 34, y: 12)
        .onChange(of: page) { _, page in Store.settings.set(page.rawValue, forKey: "settings.page") }
    }

    // MARK: - the rail

    private var hits: [SettingsItem] { SettingsIndex.find(query) }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var pages: some View {
        let counts = Dictionary(grouping: hits, by: \.page).mapValues(\.count)
        return VStack(alignment: .leading, spacing: 2) {
            Text("Settings")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 10)
                .padding(.top, 14)
                .padding(.bottom, 10)
            FindField(text: $query, focus: $finding)
                .padding(.bottom, 10)
            ForEach(Array(Page.blocks.enumerated()), id: \.offset) { index, block in
                if index > 0 {
                    Rectangle().fill(Palette.hairline).frame(height: 1)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                }
                ForEach(block) { item in
                    PageRow(page: item, on: !searching && page == item,
                            count: searching ? counts[item] ?? 0 : nil) {
                        query = ""
                        page = item
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: SettingsPanel.rail, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.wash.opacity(0.45), in: Rectangle())
    }

    /// Find a setting: the wash, the glass, ⌘F beside it until something
    /// is typed. Escape empties it.
    private struct FindField: View {
        @Binding var text: String
        var focus: FocusState<Bool>.Binding

        var body: some View {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.muted)
                ZStack(alignment: .leading) {
                    if text.isEmpty {
                        Text("Find a setting").foregroundStyle(Palette.muted.opacity(0.8))
                    }
                    TextField("", text: $text)
                        .textFieldStyle(.plain)
                        .foregroundStyle(Palette.ink)
                        .focused(focus)
                        .onExitCommand { text = "" }
                        .accessibilityLabel("Find a setting")
                }
                .font(.system(size: 12.5))
                if text.isEmpty {
                    Text("⌘F")
                        .font(.system(size: 10.5, design: .rounded))
                        .foregroundStyle(Palette.muted.opacity(0.8))
                } else {
                    Button { text = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.faint)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(Palette.ground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        }
    }

    private struct PageRow: View {
        let page: Page
        let on: Bool
        /// While searching: how many rows of this section match.
        let count: Int?
        let act: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: act) {
                HStack(spacing: 9) {
                    Image(systemName: page.icon)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 16)
                    Text(page.title)
                        .font(.system(size: 13, weight: on ? .medium : .regular))
                    Spacer(minLength: 0)
                    if let count, count > 0 {
                        Text("\(count)")
                            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(Palette.ink)
                            .padding(.horizontal, 6)
                            .frame(height: 17)
                            .background(Palette.ground, in: Capsule())
                    }
                }
                .foregroundStyle(on ? Palette.ink : (hovering ? Palette.ink.opacity(0.75) : Palette.muted))
                .opacity(count == 0 ? 0.4 : 1)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(on ? Palette.ground : (hovering ? Palette.hover : .clear))
                        .shadow(color: .black.opacity(on ? 0.06 : 0), radius: 3, y: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }

    // MARK: - the page

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if !searching {
                    Image(systemName: page.icon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Palette.ink)
                }
                Text(searching ? "Settings matching “\(query.trimmingCharacters(in: .whitespaces))”" : page.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Spacer()
                if !asTab {
                    Door(icon: "xmark", help: "Done   esc") { browser.tuning = false }
                }
            }
            .padding(.bottom, 18)
            .padding(.horizontal, 24)
            .frame(maxWidth: asTab ? SettingsPanel.column : .infinity)
            .frame(maxWidth: .infinity)

            ScrollViewReader { reader in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 22) {
                        if searching { results } else { section(page) }
                    }
                    .environment(\.ruleInset, 0)
                    .padding(.bottom, 24)
                    // Keep the rows narrow, not the scroll view: the empty
                    // space beside them must receive scrolling too.
                    .padding(.horizontal, 24)
                    .frame(maxWidth: asTab ? SettingsPanel.column : .infinity)
                    .frame(maxWidth: .infinity)
                }
                .onAppear { if let lit { reader.scrollTo(lit, anchor: .center) } }
            }
            // A page of its own opens at its top. One scroll view kept for
            // them all opened Tabs as far down as General had been read.
            .id(searching ? "found" : page.rawValue)
        }
        .padding(.top, 18)
        .padding(.bottom, 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func section(_ page: Page) -> some View {
        switch page {
        case .about:
            aboutHeader
            groups(of: page)
        case .keyboard:
            groups(of: page)
            GroupBlock(title: "Shortcuts", icon: "command") {
                ShortcutsPage(browser: browser, store: .shared, prefs: prefs)
            }
        case .terminal:
            terminal
        case .extensions:
            ExtensionsPage(browser: browser)
        case .ai:
            AISettings(browser: browser, prefs: prefs)
        case .browserUse:
            BrowserUseSettings(browser: browser, prefs: prefs)
        default:
            groups(of: page)
        }
    }

    private func groups(of page: Page) -> some View {
        ForEach(SettingsIndex.groups(of: page)) { group in
            GroupBlock(title: group.title, icon: group.icon) {
                Card { rows(SettingsIndex.items(in: group.id).filter(shown), searched: false) }
            }
        }
    }

    /// In its section, a dependent row is there only while it counts.
    private func shown(_ item: SettingsItem) -> Bool { SettingsIndex.applies(item, prefs) }

    private func rows(_ items: [SettingsItem], searched: Bool) -> some View {
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            if index > 0 { Rule() }
            row(item)
            after(item, searched: searched)
        }
    }

    private func row(_ item: SettingsItem) -> some View {
        let counts = SettingsIndex.applies(item, prefs)
        return SettingRow(
            icon: item.icon,
            title: title(of: item),
            detail: counts ? detail(of: item) : SettingsIndex.needs(item),
            more: counts ? item.more : nil,
            wide: item.kind == .wide,
            lit: lit == item.id
        ) {
            control(item)
        }
        .disabled(!counts)
        .opacity(counts ? 1 : 0.5)
        .id(item.id)
    }

    // MARK: - found

    @ViewBuilder
    private var results: some View {
        let found = hits
        if found.isEmpty {
            Card { Nothing("No setting called that. Try other words, like dark, tabs or video") }
        }
        let byGroup = Dictionary(grouping: found, by: \.group)
        ForEach(SettingsIndex.groups.filter { byGroup[$0.id] != nil }) { group in
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    let first = byGroup[group.id]?.first
                    query = ""
                    page = group.page
                    lit = first?.findOnly == false ? first?.id : nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { withAnimation(Motion.quick) { lit = nil } }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: group.icon).font(.system(size: 10.5, weight: .medium))
                        Text("\(group.page.title)  ›  \(group.title)".uppercased())
                            .font(.system(size: 10.5, weight: .semibold))
                            .tracking(0.4)
                        Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold)).opacity(0.6)
                    }
                    .foregroundStyle(Palette.muted)
                    .padding(.leading, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open \(group.page.title) at \(group.title)")
                Card { rows(byGroup[group.id] ?? [], searched: true) }
            }
        }
    }

    // MARK: - words that change

    private func title(of item: SettingsItem) -> String {
        switch item.id {
        case "updates.version": return versionTitle
        default: return item.title
        }
    }

    private func detail(of item: SettingsItem) -> String {
        switch item.id {
        case "general.default":
            return isDefault ? "Search is the default browser on this Mac" : item.detail
        case "downloads.folder":
            return prefs.downloads.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        case "search.engine": return searchDetail
        case "search.suggest": return suggestDetail
        case "search.keywords": return keywordDetail
        case "passwords.save": return savingDetail
        case "passkeys":
            return !prefs.passkeysPossible
                ? "Needs an Apple entitlement this build doesn't have"
                : Passkeys.access == .denied
                ? "macOS was told no: System Settings › Privacy & Security › Passkeys"
                : item.detail
        case "shield": return shield.trouble ?? item.detail
        case "updates.version": return versionDetail
        case "arc.import": return arcHere ? item.detail : "Arc isn't on this Mac. Bring Things Over can read an export"
        default: return item.detail
        }
    }

    private var arcHere: Bool { FileManager.default.fileExists(atPath: Arc.file.path) }

    // MARK: - controls

    @ViewBuilder
    private func control(_ item: SettingsItem) -> some View {
        switch item.page {
        case .general: generalControl(item.id)
        case .appearance: appearanceControl(item.id)
        case .tabs: tabsControl(item.id)
        case .browsing: browsingControl(item.id)
        case .spaces: spacesControl(item.id)
        case .passwords, .privacy: keptControl(item.id)
        case .keyboard, .about: otherControl(item.id)
        default: EmptyView()
        }
    }

    @ViewBuilder
    private func generalControl(_ id: String) -> some View {
        switch id {
        case "general.default":
            if isDefault {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 24)
            } else {
                Pill("Make default", filled: true) {
                    Links.becomeDefault { worked in
                        isDefault = Links.isDefault
                        browser.announce(worked && isDefault ? "Links now open here" : "macOS didn't change it")
                    }
                }
            }
        case "general.import":
            // Coming from another browser, now or any time later: the same
            // page as File › Bring Things Over… and the Welcome's.
            Pill("Bring Things Over…") { browser.lead(to: InternalPage(.importing)) }
        case "quit.confirm": Switch(on: $prefs.confirmsQuit)
        case "downloads.folder": Pill("Change…") { chooseFolder() }
        case "downloads.ask": Switch(on: $prefs.asksWhereToSave)
        case "downloads.button": Switch(on: $prefs.alwaysShowsDownloads)
        default: EmptyView()
        }
    }

    @ViewBuilder
    private func appearanceControl(_ id: String) -> some View {
        switch id {
        case "look":
            Pictures(options: Look.allCases.map { look in
                (look, look == .system ? "Auto" : look.title, AnyView(LookPicture(look: look)))
            }, selection: $prefs.look)
        case "pages.dusk": Switch(on: $prefs.darkensPages)
        case "tabs.layout":
            Pictures(options: TabsLayout.allCases.map { ($0, $0.title, AnyView(LayoutPicture(layout: $0))) },
                     selection: Binding(
                        get: { prefs.tabsLayout },
                        set: { layout in withAnimation(Motion.glide) { prefs.tabsLayout = layout } }
                     ))
        case "sidebar.hides": Switch(on: $prefs.sideHides)
        case "layout.cards":
            Pictures(options: [(true, "As a card", AnyView(CardPicture(card: true))),
                               (false, "Edge to edge", AnyView(CardPicture(card: false)))],
                     selection: Binding(
                        get: { prefs.cards },
                        set: { on in withAnimation(Motion.glide) { prefs.cards = on } }
                     ))
        case "toolbar.left": Switch(on: $prefs.navigationLeft)
        case "sidebar.roomy":
            Switch(on: Binding(
                get: { prefs.roomyTabs },
                set: { on in withAnimation(Motion.glide) { prefs.roomyTabs = on } }
            ))
        case "glyph": Segmented(options: Glyph.allCases.map { ($0, $0.title) }, selection: $prefs.glyph)
        case "tabs.reading": Switch(on: $prefs.showsReading)
        case "tabs.give": Switch(on: $prefs.tabsGive)
        case "bookmarks.bar": Switch(on: $prefs.bookmarksBar)
        case "motion.light": Switch(on: $prefs.lightMotion)
        case "note.split": Always()
        default: EmptyView()
        }
    }

    @ViewBuilder
    private func tabsControl(_ id: String) -> some View {
        switch id {
        case "tabs.newPlace":
            Picker("New tab position", selection: $prefs.newTabPlace) {
                Text("After current").tag(NewTabPlace.next)
                Text(prefs.sidebar ? "Top" : "Leftmost").tag(NewTabPlace.top)
                Text(prefs.sidebar ? "Bottom" : "Rightmost").tag(NewTabPlace.end)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        case "tabs.newAfterLast": Switch(on: $prefs.newTabAfterLast)
        case "tabs.closeGoesBack": Switch(on: $prefs.closeGoesBack)
        case "tabs.lazy": Switch(on: $prefs.lazyTabs)
        case "tabs.popupWindows": Switch(on: $prefs.popupWindows)
        case "tabs.sleep":
            VStack(alignment: .leading, spacing: 7) {
                Segmented(options: SleepChoice.allCases.map { ($0, $0.title) }, selection: $prefs.sleepChoice, wide: true)
                    .frame(maxWidth: 340)
                Text(prefs.sleepChoice.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
            }
        case "tabs.close.after":
            Picker("", selection: $prefs.tabLife) {
                ForEach(TabLife.allCases) { life in
                    Text(life.title).tag(life)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        case "tabs.shortcuts": Switch(on: $prefs.showsTabShortcuts)
        case "tabs.address":
            Switch(on: Binding(
                get: { prefs.showsAddress },
                set: { on in withAnimation(Motion.glide) { prefs.showsAddress = on } }
            ))
        case "note.groups", "note.awake": Always()
        default: EmptyView()
        }
    }

    @ViewBuilder
    private func browsingControl(_ id: String) -> some View {
        switch id {
        case "search.engine":
            Picker("", selection: $prefs.engine) {
                ForEach(Engine.allCases) { engine in
                    Text(engine.title).tag(engine)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        case "search.suggest": Switch(on: $prefs.engineSuggests)
        case "search.keywords":
            if draft == nil {
                Pill("Add") { draft = Keyword() }
            } else {
                HStack(spacing: 6) {
                    Pill("Cancel") { draft = nil }
                    Pill("Save", filled: true) { saveDraft() }
                        .disabled(draftProblem != nil)
                        .opacity(draftProblem == nil ? 1 : 0.4)
                }
            }
        case "links.little": Switch(on: $prefs.littleLinks)
        case "reader.twins": Switch(on: $prefs.readsTwins)
        case "reader.follows": Switch(on: $prefs.readerFollowsLook)
        case "float.style": Segmented(options: FloatStyle.allCases.map { ($0, $0.title) }, selection: $prefs.floatStyle)
        case "float.own":
            Segmented(options: FloatOwn.allCases.map { ($0, $0.title) }, selection: $prefs.floatOwn, wide: true)
                .frame(maxWidth: 340)
        case "media.click": Switch(on: $prefs.waitsForPlay)
        case "fullscreen.escapeTwice": Switch(on: $prefs.escapeTwice)
        case "pageZoom":
            // The number itself takes it back to 100%.
            Steps(stops: Preferences.zooms, value: $prefs.pageZoom, home: 1) { "\(Int(($0 * 100).rounded()))%" }
        case "pages.120": Segmented(options: FastPages.allCases.map { ($0, $0.title) }, selection: $prefs.fastPages)
        case "autocorrect": Switch(on: $prefs.autocorrect)
        case "note.panel", "note.translate", "note.sitesearch", "note.links", "note.flick": Always()
        default: EmptyView()
        }
    }

    @ViewBuilder
    private func spacesControl(_ id: String) -> some View {
        switch id {
        case "arc.setup":
            if let before = arcBefore, prefs.looksLikeArc {
                Pill("Undo") {
                    withAnimation(Motion.glide) { prefs.restore(before) }
                    arcBefore = nil
                    SettingsPanel.arcBefore = nil
                    browser.announce("Put back as it was")
                }
            } else if prefs.looksLikeArc {
                Always(text: "Set up")
            } else {
                Pill("Set Up", filled: true) { setUpLikeArc() }
            }
        case "arc.import":
            Pill("Bring Over…") { browser.lead(to: InternalPage(.importing, "Arc")) }
                .disabled(!arcHere)
                .opacity(arcHere ? 1 : 0.4)
        case "spaces": Switch(on: $prefs.usesSpaces)
        case "profiles": Pill("New Profile…") { ProfileMenu.askNew() }
        case "pins.keep": Switch(on: $prefs.pinsKeepSite)
        case "pins.list": Switch(on: $prefs.listsPins)
        case "newtab.floating": Switch(on: $prefs.floatingNewTab)
        case "commandbar": Switch(on: $prefs.commandBar)
        case "start.fresh": Switch(on: $prefs.startsFresh)
        case "note.sharedpins", "note.pinback": Always()
        default: EmptyView()
        }
    }

    @ViewBuilder
    private func keptControl(_ id: String) -> some View {
        switch id {
        case "passwords.open": Pill("Open…") { browser.lead(to: InternalPage(.passwords)) }
        case "passwords.save": Switch(on: $prefs.savesPasswords)
        case "passwords.fill": Switch(on: $prefs.fillsPasswords)
        case "passkeys": Switch(on: $prefs.passkeys)
        case "passwords.apple": Switch(on: $prefs.applePasswords)
        case "shield": Switch(on: $prefs.shielded)
        case "sites.keep": Switch(on: Binding(get: { !prefs.keepsSignIns }, set: { prefs.keepsSignIns = !$0 }))
        case "privacy.clickIDs": Switch(on: $prefs.removesClickIDs)
        case "privacy.gpc": Switch(on: $prefs.sendsPrivacySignal)
        case "notifications.ask": Switch(on: $prefs.siteNotifications)
        case "privacy.forget": Pill("Forget choices") { browser.forgetCaptureChoices() }
        case "clear.history": Pill("Clear") { browser.clearHistory() }
        case "clear.cookies": Pill("Sign out of everything") { browser.clearSites() }
        case "clear.cache": Pill("Clear") { browser.clearCache() }
        default: EmptyView()
        }
    }

    @ViewBuilder
    private func otherControl(_ id: String) -> some View {
        switch id {
        case "links.peek":
            Picker("Peek at a link", selection: $prefs.peekChoice) {
                ForEach(PeekChoice.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        case "autoscroll": Switch(on: $prefs.autoScroll)
        case "swipe.history": Switch(on: $prefs.holdsHistory)
        case "note.switcher": Always()
        case "updates.version": versionControl
        case "updates.auto": Switch(on: $prefs.installsUpdates)
        case "about.feedback": Pill("Send Feedback") { Links.writeFeedback() }
        case "about.notes": Pill("What's New…") { browser.lead(to: InternalPage(.notes)) }
        case "bench": Switch(on: $prefs.bench)
        default: EmptyView()
        }
    }

    // MARK: - what goes under a row

    // Rows here are siblings of the one above, at its level; lists sit
    // under its words, as pictures do, their hairlines still edge to edge.

    @ViewBuilder
    private func after(_ item: SettingsItem, searched: Bool) -> some View {
        switch item.id {
        case "search.engine":
            if prefs.engine == .custom { customEngine }
        case "search.keywords":
            keywordEditor
            // What ⌘T opens to, and the way back after an extension took
            // it. Only there while an extension offers a page.
            if !searched { HomePageLine() }
        case "shield":
            if let trouble = shield.trouble {
                Rule()
                Line(trouble, "Nothing is being blocked until this clears. Try again, or restart Search") {
                    Pill("Try again") { shield.compile() }
                }
                .under()
            }
            if !searched, let host = browser.hereHost, prefs.shielded, shield.trouble == nil {
                Rule()
                SettingRow(icon: "checkmark.shield", title: "Block on \(host)",
                           detail: "Turn off here if the site breaks; the page reloads") {
                    Switch(on: Binding(
                        get: { !Shield.shared.isPaused(on: host) },
                        set: { on in
                            Shield.shared.pause(host, !on)
                            browser.reload()
                        }
                    ))
                }
            }
        case "privacy.forget":
            if !searched {
                Group {
                    NotificationSites()
                    PopupSiteList(prefs: prefs)
                }
                .under()
            }
        case "passkeys":
            if !searched, !Vault.never.isEmpty {
                Rule()
                SettingRow(icon: "hand.raised.slash", title: "Sites never asked",
                           detail: "\(Vault.never.count) sites told to stop offering") {
                    Pill("Forget") {
                        Vault.never = []
                        browser.announce("Every site can ask again")
                    }
                }
            }
        case "passwords.apple":
            ApplePasswordsCard(prefs: prefs, bare: true)
                .under()
        case "profiles":
            if !searched {
                ProfileList(browser: browser)
                    .under()
            }
        case "pages.120":
            if !searched, PageTranslator.available, !prefs.translateAlways.isEmpty {
                TranslateLanguageList(prefs: prefs)
                    .under()
            }
        default:
            EmptyView()
        }
    }

    private var customEngine: some View {
        ZStack(alignment: .leading) {
            if prefs.customEngine.isEmpty {
                Text("https://example.com/search?q=%s")
                    .foregroundStyle(Palette.muted.opacity(0.8))
            }
            TextField("", text: $prefs.customEngine)
                .textFieldStyle(.plain)
                .foregroundStyle(Palette.ink)
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(.leading, SettingsPanel.textInset)
        .padding(.trailing, 14)
        .padding(.bottom, 11)
    }

    @ViewBuilder
    private var keywordEditor: some View {
        if let current = draft {
            HStack(spacing: 8) {
                TextField("yt", text: Binding(
                    get: { current.keyword },
                    set: { draft?.keyword = $0 }
                ))
                .textFieldStyle(.plain)
                .frame(width: 50)
                Text("→").foregroundStyle(Palette.muted)
                TextField("https://www.youtube.com/results?search_query=%s", text: Binding(
                    get: { current.template },
                    set: { draft?.template = $0 }
                ))
                .textFieldStyle(.plain)
                .onSubmit(saveDraft)
            }
            .font(.system(size: 12.5))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .padding(.leading, SettingsPanel.textInset)
            .padding(.trailing, 14)
            .padding(.bottom, 6)
        }
        ForEach(prefs.keywords) { entry in
            HStack(spacing: 8) {
                Text(entry.keyword)
                    .frame(width: 50, alignment: .leading)
                Text("→").foregroundStyle(Palette.muted)
                Text(entry.template)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    prefs.keywords.removeAll { $0.id == entry.id }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Palette.faint)
                }
                .buttonStyle(.plain)
            }
            .font(.system(size: 12.5))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .padding(.leading, SettingsPanel.textInset)
            .padding(.trailing, 14)
            .padding(.bottom, 6)
        }
    }

    /// Checked when it's saved, not as it's typed into the list: a shortcut
    /// only exists once its address is one it's safe to send words to.
    private var draftProblem: String? {
        guard let draft else { return nil }
        return Keyword.problem(word: draft.keyword, template: draft.template, among: prefs.keywords)
    }

    private var keywordDetail: String {
        guard let draft else { return SettingsIndex.item("search.keywords")?.detail ?? "" }
        if draft.keyword.isEmpty, draft.template.isEmpty {
            return "A word, then the site's search address with %s where the words go"
        }
        return draftProblem ?? "\(draft.keyword.trimmingCharacters(in: .whitespacesAndNewlines)) will search \(draft.name)"
    }

    private func saveDraft() {
        guard let current = draft, draftProblem == nil else { return }
        prefs.keywords.append(Keyword(
            keyword: current.keyword.trimmingCharacters(in: .whitespacesAndNewlines),
            template: current.template.trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        draft = nil
    }

    /// Said plainly: turned on, what you type leaves the Mac as you type it.
    private var suggestDetail: String {
        let name = prefs.engine.name(custom: prefs.customEngine)
        guard EngineSuggest.endpoint(for: prefs.engine) != nil else {
            return "A custom engine has no suggestions to give, so nothing is sent"
        }
        return "What you type is sent to \(name) as you type"
    }

    private var searchDetail: String {
        guard prefs.engine == .custom else { return "Where words that aren't an address go" }
        guard Engine.accepts(prefs.customEngine) else {
            return "An http or https address with %s where the words go. Until then, Google"
        }
        return "Words go to \(prefs.engine.name(custom: prefs.customEngine))"
    }

    /// Says so when a password manager extension has taken the saving over.
    private var savingDetail: String {
        if #available(macOS 15.4, *), let name = Extensions.shared.passwordSavingTakenBy {
            return "\(name) does the saving; it asked Search not to offer"
        }
        return "Asked once per site, never again for a site you refuse"
    }

    private func setUpLikeArc() {
        let before = prefs.arcSnapshot
        let changed = withAnimation(Motion.glide) { prefs.setUpLikeArc() }
        arcBefore = before
        SettingsPanel.arcBefore = before
        browser.announce(changed.isEmpty ? "Already set up like Arc" : "Turned on: " + changed.joined(separator: ", "))
    }

    // MARK: - terminal

    /// The terminal's own settings. Everything here reaches the terminals
    /// already open — the renderer reads the settings for every frame — so
    /// a change is seen as it is made, except the shell and the folder,
    /// which a program already running cannot be moved to.
    private var terminal: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                Line("Font", "Every terminal draws with this face", below: true) {
                    Picker("", selection: $prefs.terminalFont) {
                        Text("System Mono").tag("")
                        ForEach(TerminalLook.faces) { face in
                            Text(face.title).tag(face.name)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                Rule()
                Line("Size") {
                    Steps(stops: TerminalLook.sizes, value: $prefs.terminalSize, home: TerminalLook.home) {
                        String(format: "%.1f", $0)
                    }
                }
                Rule()
                Line("Theme", "Solarized is the scheme as it was published; the rest are the Mac's own") {
                    Picker("", selection: $prefs.terminalTheme) {
                        ForEach(TerminalTheme.allCases) { theme in
                            Text(theme.title).tag(theme)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }
            Card {
                Line("Cursor") {
                    Segmented(
                        options: TerminalCursor.allCases.map { ($0, $0.title) },
                        selection: $prefs.terminalCursor
                    )
                }
                Rule()
                Line("Blink", "Twice a second, while the keyboard is in the terminal") {
                    Switch(on: $prefs.terminalBlinks)
                }
                Rule()
                Line("Find Bar", "Where ⌘F's panel hangs, over the frame's top corner or its bottom") {
                    Segmented(
                        options: TerminalFindPlace.allCases.map { ($0, $0.title) },
                        selection: $prefs.terminalFindPlace
                    )
                }
                Rule()
                Line("Input Bar", "Where you type — a dock over the frame's bottom, or the grid itself") {
                    Segmented(
                        options: TerminalInputBar.allCases.map { ($0, $0.title) },
                        selection: $prefs.terminalInputBar
                    )
                }
                Rule()
                Line("Padding", "The room left around the cells, in points") {
                    Steps(stops: TerminalLook.paddings, value: $prefs.terminalPadding, home: 4) {
                        String(format: "%.0f", $0)
                    }
                }
            }
            Card {
                Line("Take the mouse", "Clicks and drags go to htop, vim and the rest — hold ⌥ to select text instead") {
                    Switch(on: $prefs.terminalMouse)
                }
                Rule()
                Line("Set the clipboard", "How a program copies, by printing an escape sequence; reading one back is never allowed") {
                    Switch(on: $prefs.terminalClipboard)
                }
                Rule()
                Line("⌘-click opens links", "Where a program has said a run of words is a link (OSC 8)") {
                    Switch(on: $prefs.terminalLinks)
                }
                Rule()
                Line("Synchronized output", "A program drawing a frame says when it is whole, and the terminal waits rather than showing half of it") {
                    Switch(on: $prefs.terminalSync)
                }
            }
            Card {
                Line(
                    "Shell",
                    shown(prefs.terminalShell.isEmpty ? TerminalLook.shellPath() : prefs.terminalShell)
                ) {
                    HStack(spacing: 8) {
                        if !prefs.terminalShell.isEmpty {
                            Pill("System default") { prefs.terminalShell = "" }
                        }
                        Pill("Change…") { chooseShell() }
                    }
                }
                Rule()
                Line(
                    "Start in",
                    prefs.terminalDirectory.isEmpty
                        ? "Wherever Search was started"
                        : shown(prefs.terminalDirectory)
                ) {
                    HStack(spacing: 8) {
                        if !prefs.terminalDirectory.isEmpty {
                            Pill("Default") { prefs.terminalDirectory = "" }
                        }
                        Pill("Change…") { chooseTerminalFolder() }
                    }
                }
                Rule()
                Line("Scrollback", "The lines a terminal keeps above its screen") {
                    Steps(
                        stops: TerminalLook.scrollbacks.map(Double.init),
                        value: Binding(
                            get: { Double(prefs.terminalScrollback) },
                            set: { prefs.terminalScrollback = Int($0) }
                        ),
                        home: 100_000
                    ) {
                        Int($0).formatted()
                    }
                }
            }
            Caption("The shell and the folder are for the next terminal: a program already running is not moved.")
            Card {
                islandRow(islandAgents[0])
                Rule()
                islandRow(islandAgents[1])
                Rule()
                islandRow(islandAgents[2])
                if let trouble = islandTrouble {
                    Rule()
                    Line(trouble, "Nothing changed — the file is where it said it wouldn't be") { EmptyView() }
                }
                if islandMore {
                    ForEach(islandAgents.dropFirst(3)) { agent in
                        Rule()
                        islandRow(agent)
                    }
                }
                Rule()
                Line(
                    "More agents",
                    islandMore
                        ? "Gemini, Cursor, Qwen, Grok, Droid, Copilot, Oh My Pi"
                        : "Seven more that Search can watch, each the same way"
                ) {
                    Pill(islandMore ? "Show less" : "Show more", filled: !islandMore) {
                        withAnimation(Motion.quick) { islandMore.toggle() }
                    }
                }
            }
            Caption("The coding agents say what they're doing to the notch over the tabs (Island), and ask there before a run — but only in a terminal nobody is watching; answered here, they go on there. Clicking a row goes to its terminal. The hooks write nothing anywhere else, and Remove takes them back out cleanly.")
        }
    }

    // MARK: - the island

    /// The wind the island's switches tick when they act, so the lines
    /// say what just happened rather than what was there when the
    /// settings were opened — none of the hooks' work is anyone's to
    /// watch but the files' themselves.
    @State private var islandTick = false
    @State private var islandTrouble: String?

    /// Whether the island's list shows the agents fewer people run —
    /// three are enough for most, and the rest wait one click away.
    @State private var islandMore = false

    /// Where each CLI keeps the settings that run hooks: their own
    /// homes, in the places they say, overridable by the environment
    /// each one says it reads.
    private var claudeHome: URL {
        ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/.claude")
    }
    private var codexHome: URL {
        ProcessInfo.processInfo.environment["CODEX_HOME"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/.codex")
    }
    private var piHome: URL { URL(fileURLWithPath: NSHomeDirectory() + "/.pi/agent") }

    /// Oh My Pi reads the same folder shape as Pi, one home over: the
    /// same extension serves it, said for its own source.
    private var ompHome: URL { URL(fileURLWithPath: NSHomeDirectory() + "/.omp/agent") }
    private var geminiHome: URL { URL(fileURLWithPath: NSHomeDirectory() + "/.gemini") }
    private var cursorHome: URL { URL(fileURLWithPath: NSHomeDirectory() + "/.cursor") }
    private var qwenHome: URL {
        ProcessInfo.processInfo.environment["QWEN_HOME"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/.qwen")
    }
    private var grokHome: URL {
        ProcessInfo.processInfo.environment["GROK_HOME"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/.grok")
    }
    private var droidHome: URL { URL(fileURLWithPath: NSHomeDirectory() + "/.factory") }
    private var copilotHome: URL { URL(fileURLWithPath: NSHomeDirectory() + "/.copilot") }

    /// Where the bridge is: the terminals' own folder in Application
    /// Support, written on the first install (the pill's work, below).
    private var islandBridge: String {
        Store.file("Terminal").appendingPathComponent(IslandHooks.bridgeName).path
    }

    /// The island's list, first three the ones most people run. Each
    /// row is one agent: where its settings are, whether ours are in
    /// them, and how to put them in and take them back out — one
    /// switch for every row, whatever the differences under each.
    private var islandAgents: [IslandAgent] {
        [
            IslandAgent(
                name: "Claude Code", home: claudeHome, file: "settings.json",
                hooked: { IslandHooks.claudeHooked(claudeHome, bridge: $0) },
                install: { try IslandHooks.installClaude(claudeHome, bridge: $0) },
                remove: { try IslandHooks.removeClaude(claudeHome, bridge: $0) }
            ),
            IslandAgent(
                name: "Codex", home: codexHome, file: "hooks.json",
                hooked: { IslandHooks.codexHooked(codexHome, bridge: $0) },
                install: { try IslandHooks.installCodex(codexHome, bridge: $0) },
                remove: { try IslandHooks.removeCodex(codexHome, bridge: $0) }
            ),
            IslandAgent(
                name: "Pi", home: piHome, file: "extensions/" + IslandHooks.piName,
                hooked: { _ in IslandHooks.piHooked(piHome) },
                install: { try IslandHooks.installPi(piHome, bridge: $0) },
                remove: { _ in try IslandHooks.removePi(piHome) }
            ),
            IslandAgent(
                name: "Gemini", home: geminiHome, file: "settings.json",
                hooked: { IslandHooks.geminiHooked(geminiHome, bridge: $0) },
                install: { try IslandHooks.installGemini(geminiHome, bridge: $0) },
                remove: { try IslandHooks.removeGemini(geminiHome, bridge: $0) }
            ),
            IslandAgent(
                name: "Cursor", home: cursorHome, file: "hooks.json",
                hooked: { IslandHooks.cursorHooked(cursorHome, bridge: $0) },
                install: { try IslandHooks.installCursor(cursorHome, bridge: $0) },
                remove: { try IslandHooks.removeCursor(cursorHome, bridge: $0) }
            ),
            IslandAgent(
                name: "Qwen Code", home: qwenHome, file: "settings.json",
                hooked: { IslandHooks.qwenHooked(qwenHome, bridge: $0) },
                install: { try IslandHooks.installQwen(qwenHome, bridge: $0) },
                remove: { try IslandHooks.removeQwen(qwenHome, bridge: $0) }
            ),
            IslandAgent(
                name: "Grok CLI", home: grokHome, file: "hooks/" + IslandHooks.oursName,
                hooked: { IslandHooks.grokHooked(grokHome, bridge: $0) },
                install: { try IslandHooks.installGrok(grokHome, bridge: $0) },
                remove: { try IslandHooks.removeGrok(grokHome, bridge: $0) }
            ),
            IslandAgent(
                name: "Droid", home: droidHome, file: "settings.json",
                hooked: { IslandHooks.droidHooked(droidHome, bridge: $0) },
                install: { try IslandHooks.installDroid(droidHome, bridge: $0) },
                remove: { try IslandHooks.removeDroid(droidHome, bridge: $0) }
            ),
            IslandAgent(
                name: "Copilot CLI", home: copilotHome, file: "hooks/" + IslandHooks.oursName,
                hooked: { IslandHooks.copilotHooked(copilotHome, bridge: $0) },
                install: { try IslandHooks.installCopilot(copilotHome, bridge: $0) },
                remove: { try IslandHooks.removeCopilot(copilotHome, bridge: $0) }
            ),
            IslandAgent(
                name: "Oh My Pi", home: ompHome, file: "extensions/" + IslandHooks.piName,
                hooked: { _ in IslandHooks.ompHooked(ompHome) },
                install: { try IslandHooks.installOmp(ompHome, bridge: $0) },
                remove: { _ in try IslandHooks.removeOmp(ompHome) }
            ),
        ]
    }

    /// One row of the island's list: the agent's name, where its
    /// settings are and whether ours are in them, and the switch that
    /// puts them in or takes them back out.
    @ViewBuilder
    private func islandRow(_ agent: IslandAgent) -> some View {
        Line(agent.name, islandDetail(agent.home, agent.file, agent.hooked(islandBridge))) {
            Pill(agent.hooked(islandBridge) ? "Remove" : "Install", filled: !agent.hooked(islandBridge)) {
                islandSwitch(agent)
            }
        }
    }

    /// What each line says of its agent: where its settings are, and
    /// whether ours are in them. A home that isn't there is a CLI that
    /// isn't either — installing into it would only be litter.
    private func islandDetail(_ home: URL, _ file: String, _ hooked: Bool) -> String {
        let place = home.path.hasPrefix(NSHomeDirectory())
            ? "~" + home.path.dropFirst(NSHomeDirectory().count)
            : home.path
        guard FileManager.default.fileExists(atPath: home.path) else {
            return "\(place) — the folder isn't there yet"
        }
        return "\(place)/\(file)\(hooked ? " — watched" : " — not watched")"
    }

    /// The one switch every row shares: put the hooks in, or take them
    /// back out. The bridge is written first, for an install wants it to
    /// exist; a remove leaves it — it's ours, in our own folder, and it
    /// might be an uninstall away from being wanted again.
    private func islandSwitch(_ agent: IslandAgent) {
        islandTrouble = nil
        do {
            if agent.hooked(islandBridge) {
                try agent.remove(islandBridge)
            } else {
                try agent.install(IslandHooks.writeBridge(Store.file("Terminal")))
            }
        } catch { islandTrouble = error.localizedDescription }
        islandTick.toggle()
    }

    // MARK: - privacy

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                Line("Block ads and trackers", shield.trouble ?? "Third parties whose only job is to watch") {
                    Switch(on: $prefs.shielded)
                }
                if let trouble = shield.trouble {
                    Rule()
                    Line(trouble, "Nothing is being blocked until this clears — try again, or restart Search") {
                        Pill("Try again") { shield.compile() }
                    }
                }
                if let host = browser.hereHost, prefs.shielded, shield.trouble == nil {
                    Rule()
                    Line("Block on \(host)", "Turn off here if the site breaks — the page reloads") {
                        Switch(on: Binding(
                            get: { !Shield.shared.isPaused(on: host) },
                            set: { on in
                                Shield.shared.pause(host, !on)
                                browser.reload()
                            }
                        ))
                    }
                }
                Rule()
                Line("Prevent cross-site tracking", "As in Safari. Off, sites you rarely open keep their sign-ins, and trackers inside other sites can follow you across them again, as in Chrome. Private tabs keep it on") {
                    Switch(on: Binding(get: { !prefs.keepsSignIns }, set: { prefs.keepsSignIns = !$0 }))
                }
                Rule()
                Line("Camera, microphone, location and notifications", "What each site was allowed or refused, and the sites whose videos don't float") {
                    Pill("Forget choices") { browser.forgetCaptureChoices() }
                }
                Rule()
                Line("Let sites ask to send notifications", "A site asks on a card over its page, and only one you allow reaches your Mac's notifications. Private tabs are never asked") {
                    Switch(on: $prefs.siteNotifications)
                }
                NotificationSites()
            }
            Card {
                Line("History", "Every address you have been to") {
                    Pill("Clear") { browser.clearHistory() }
                }
                Rule()
                Line("Cookies and sign-ins", "Signs you out of every site") {
                    Pill("Sign out of everything") { browser.clearSites() }
                }
                Rule()
                Line("Cache", "Only what was fetched to draw pages") {
                    Pill("Clear") { browser.clearCache() }
                }
            }
        }    }

    // MARK: - about

    private var aboutHeader: some View {
        HStack(spacing: 14) {
            Logomark()
                .fill(Palette.ink, style: FillStyle(eoFill: true))
                .aspectRatio(Logomark.canvas.width / Logomark.canvas.height, contentMode: .fit)
                .frame(height: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text("Search")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text("by Office Commun · version \(Updater.version)")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            }
        }
    }

    /// The version line follows the newer build from found to fetched to
    /// in place; with none, it is simply this one.
    private var versionTitle: String {
        switch updater.stage {
        case .none: return "Updates"
        case .fetching(let next): return "Search \(next.version) is downloading…"
        case .ready(let next): return "Search \(next.version) is ready"
        case .offered(let next), .waiting(let next): return "Search \(next.version) is out"
        }
    }

    private var versionDetail: String {
        switch updater.stage {
        case .none:
            return updater.lastChecked.map { "Checked \($0.formatted(.relative(presentation: .named))), every hour on its own" }
                ?? "Checked every hour on its own"
        case .fetching(let next):
            return next.notes ?? "Quietly, in the background. Nothing you have set is touched"
        case .ready(let next):
            return next.notes ?? "It's there the next time you open Search"
        case .offered(let next):
            return next.notes ?? "Open the disk image, the same as the first time"
        case .waiting(let next):
            return next.notes ?? "Checked and put in place when you press Install"
        }
    }

    @ViewBuilder
    private var versionControl: some View {
        switch updater.stage {
        case .none:
            Pill(updater.checking ? "Checking…" : "Check now") {
                updater.check { found in
                    if found == nil { browser.announce("This is the latest one") }
                }
            }
            .disabled(updater.checking)
        case .fetching:
            Ring(size: 12)
        case .ready:
            Pill("Relaunch now", filled: true) { updater.relaunch() }
        case .offered:
            Pill(updater.fetchingDisk ? "Downloading…" : "Download", filled: true) { updater.openDisk() }
                .disabled(updater.fetchingDisk)
        case .waiting:
            Pill("Install", filled: true) { updater.install() }
        }
    }

    // MARK: - doing

    /// The panel all three of these settings put up — the folder downloads
    /// go to, the program a terminal runs, the folder a terminal starts in
    /// — with what differs passed in: whether a folder or a file is being
    /// chosen, where the panel opens, whether hidden files are shown, and
    /// where the answer goes. One panel's behaviour, in one place.
    private func choose(
        _ prompt: String, folders: Bool, from start: URL?, hidden: Bool = false, into store: (URL) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = folders
        panel.canChooseFiles = !folders
        panel.canCreateDirectories = true
        panel.showsHiddenFiles = hidden
        panel.directoryURL = start
        panel.prompt = prompt
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store(url)
    }

    private func chooseFolder() {
        choose("Use this folder", folders: true, from: prefs.downloads) { prefs.downloads = $0 }
    }

    /// The program a new terminal runs. Any file can be chosen and not only
    /// an executable: what is wanted is a path to try, and the terminal
    /// falls back to the Mac's own shell for one that will not run.
    private func chooseShell() {
        choose("Use this shell", folders: false, from: URL(fileURLWithPath: "/bin"), hidden: true) {
            prefs.terminalShell = $0.path
        }
    }

    private func chooseTerminalFolder() {
        let start = prefs.terminalDirectory.isEmpty
            ? nil
            : URL(fileURLWithPath: (prefs.terminalDirectory as NSString).expandingTildeInPath)
        choose("Start here", folders: true, from: start) { prefs.terminalDirectory = $0.path }
    }

    /// A path as the panel writes it: the home folder as a tilde.
    private func shown(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

// MARK: - pieces

private extension View {
    /// A list under a row's words (sites, profiles, languages): its lines
    /// start where the row's title does, and its hairlines are pulled back
    /// out to the card's left edge, as every other one in Settings.
    func under() -> some View {
        padding(.leading, SettingsPanel.listInset)
            .environment(\.ruleInset, -SettingsPanel.listInset)
    }
}

/// A group of a section: its small heading with an icon, then its card.
/// No line under the heading: the rows say what they do.
struct GroupBlock<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10.5, weight: .semibold))
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.5)
            }
            .foregroundStyle(Palette.ink.opacity(0.62))
            .padding(.leading, 2)
            content()
        }
    }
}

/// One setting: its icon in a soft tile, what it is, one line on what it
/// does (the rest behind the (i)), and its control. A wide control goes
/// under the words.
struct SettingRow<Control: View>: View {
    let icon: String
    let title: String
    let detail: String
    var more: String? = nil
    var wide = false
    var lit = false
    @ViewBuilder let control: () -> Control

    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.ink.opacity(0.78))
                    .frame(width: 26, height: 26)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(title)
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        if more != nil {
                            Button { withAnimation(Motion.quick) { open.toggle() } } label: {
                                Image(systemName: open ? "info.circle.fill" : "info.circle")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(Palette.muted.opacity(0.8))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(more ?? "")
                            .accessibilityLabel("More about \(title)")
                        }
                    }
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if open, let more {
                        Text(more)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 3)
                            .transition(.opacity)
                    }
                }
                Spacer(minLength: 8)
                if !wide { control() }
            }
            if wide {
                control()
                    .padding(.leading, 38)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
        .background(lit ? Palette.hover : .clear)
    }
}

/// For a feature that is simply there: no switch, a quiet word.
struct Always: View {
    var text = "Always on"
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Palette.wash, in: Capsule())
    }
}

/// Choices shown as small pictures, as macOS's own Appearance pane has
/// them: a ring around the one picked, its name under each.
struct Pictures<Option: Hashable>: View {
    let options: [(Option, String, AnyView)]
    @Binding var selection: Option

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(options, id: \.0) { option, title, picture in
                let on = option == selection
                Button { withAnimation(Motion.settle) { selection = option } } label: {
                    VStack(spacing: 6) {
                        picture
                            .frame(width: 76, height: 50)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(Palette.hairline, lineWidth: 1)
                            )
                            .padding(3)
                            .overlay(
                                RoundedRectangle(cornerRadius: 9.5, style: .continuous)
                                    .strokeBorder(on ? Palette.ink : .clear, lineWidth: 2)
                            )
                        Text(title)
                            .font(.system(size: 11.5, weight: on ? .medium : .regular))
                            .foregroundStyle(on ? Palette.ink : Palette.muted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// A window in miniature with the tabs where a layout puts them.
private struct LayoutPicture: View {
    let layout: TabsLayout

    var body: some View {
        let tab = Palette.ink.opacity(0.22)
        let lit = Palette.ink.opacity(0.55)
        ZStack {
            Palette.wash
            switch layout {
            case .top:
                VStack(spacing: 4) {
                    HStack(spacing: 3) {
                        lights
                        Capsule().fill(lit).frame(width: 14, height: 4)
                        Capsule().fill(tab).frame(width: 14, height: 4)
                        Capsule().fill(tab).frame(width: 10, height: 4)
                        Spacer(minLength: 0)
                    }
                    page
                }
                .padding(5)
            case .left, .right:
                HStack(spacing: 4) {
                    if layout == .right { page }
                    VStack(alignment: .leading, spacing: 3) {
                        if layout == .left { lights } else { Color.clear.frame(height: 3) }
                        Capsule().fill(lit).frame(width: 16, height: 3.5)
                        Capsule().fill(tab).frame(width: 16, height: 3.5)
                        Capsule().fill(tab).frame(width: 12, height: 3.5)
                        Spacer(minLength: 0)
                    }
                    .frame(width: 18)
                    if layout == .left { page }
                }
                .padding(5)
            case .icons:
                // A narrow column of squares, one under the other: the
                // tabs' icons, no titles.
                HStack(spacing: 4) {
                    VStack(spacing: 3) {
                        VStack(spacing: 1.5) {
                            ForEach(0..<3) { _ in Circle().fill(Palette.ink.opacity(0.25)).frame(width: 3, height: 3) }
                        }
                        .padding(.bottom, 1)
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous).fill(lit).frame(width: 6, height: 6)
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous).fill(tab).frame(width: 6, height: 6)
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous).fill(tab).frame(width: 6, height: 6)
                        Spacer(minLength: 0)
                    }
                    .frame(width: 8)
                    page
                }
                .padding(5)
            }
        }
    }

    private var lights: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<3) { _ in Circle().fill(Palette.ink.opacity(0.25)).frame(width: 3, height: 3) }
        }
    }

    private var page: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Palette.ground)
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 2.5) {
                    Capsule().fill(Palette.ink.opacity(0.18)).frame(width: 22, height: 3)
                    Capsule().fill(Palette.ink.opacity(0.1)).frame(width: 30, height: 2.5)
                    Capsule().fill(Palette.ink.opacity(0.1)).frame(width: 26, height: 2.5)
                }
                .padding(5)
            }
    }
}

/// The page as a card, or reaching the window's edges.
private struct CardPicture: View {
    let card: Bool

    var body: some View {
        HStack(spacing: card ? 4 : 0) {
            VStack(alignment: .leading, spacing: 3) {
                Capsule().fill(Palette.ink.opacity(0.55)).frame(width: 15, height: 3.5)
                Capsule().fill(Palette.ink.opacity(0.22)).frame(width: 15, height: 3.5)
                Capsule().fill(Palette.ink.opacity(0.22)).frame(width: 11, height: 3.5)
                Spacer(minLength: 0)
            }
            .padding(.top, 8)
            .padding(.leading, card ? 0 : 5)
            .frame(width: card ? 17 : 22, alignment: .leading)
            if !card { Rectangle().fill(Palette.hairline).frame(width: 1) }
            RoundedRectangle(cornerRadius: card ? 4 : 0, style: .continuous)
                .fill(Palette.ground)
                .shadow(color: .black.opacity(card ? 0.12 : 0), radius: 1.5, y: 0.5)
        }
        .padding(card ? 5 : 0)
        .background(card ? Palette.wash : Palette.ground)
    }
}

/// Light, dark, or both halves for Auto: drawn in the look itself, not in
/// the one Search is in now.
private struct LookPicture: View {
    let look: Look

    var body: some View {
        switch look {
        case .light: Window(dark: false)
        case .dark: Window(dark: true)
        default:
            ZStack {
                Window(dark: false)
                Window(dark: true).mask(HStack(spacing: 0) { Color.clear; Color.black })
            }
        }
    }

    private struct Window: View {
        let dark: Bool
        var body: some View {
            let ground = Color(white: dark ? 0.11 : 1)
            let wash = Color(white: dark ? 0.17 : 0.93)
            let ink = Color(white: dark ? 0.93 : 0.09)
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 3) {
                    Capsule().fill(ink.opacity(0.55)).frame(width: 14, height: 3.5)
                    Capsule().fill(ink.opacity(0.2)).frame(width: 14, height: 3.5)
                    Spacer(minLength: 0)
                }
                .padding(.top, 8)
                .frame(width: 16)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(ground)
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 2.5) {
                            Capsule().fill(ink.opacity(0.4)).frame(width: 20, height: 3)
                            Capsule().fill(ink.opacity(0.18)).frame(width: 28, height: 2.5)
                        }
                        .padding(5)
                    }
            }
            .padding(5)
            .background(wash)
        }
    }
}

/// A row of choices in a grey track, one of them lifted out in white. The
/// white slides to the one you pick rather than appearing there.
/// One coding agent in the island's list — the name it goes by, where
/// its settings are, and what it is to Search to put the hooks in and
/// take them back out. The bridge's path goes in and out of each: it
/// is what tells ours from anyone else's in the settings, and an
/// install writes it fresh.
private struct IslandAgent: Identifiable {
    let name: String
    let home: URL
    let file: String
    let hooked: (String) -> Bool
    let install: (String) throws -> Void
    let remove: (String) throws -> Void
    var id: String { name }
}

struct Segmented<Option: Hashable>: View {
    let options: [(Option, String)]
    @Binding var selection: Option
    /// True when the control has the whole width to itself, so the choices
    /// share it evenly instead of each taking only what its word needs.
    var wide = false

    @Namespace private var slide

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { option, title in
                Text(title)
                    .font(.system(size: 11.5, weight: option == selection ? .medium : .regular))
                    .foregroundStyle(option == selection ? Palette.ink : Palette.muted)
                    .lineLimit(1)
                    .fixedSize(horizontal: !wide, vertical: false)
                    .frame(maxWidth: wide ? .infinity : nil)
                    .padding(.horizontal, wide ? 4 : 10)
                    .padding(.vertical, 5)
                    .background {
                        if option == selection {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Palette.ground)
                                .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                                .matchedGeometryEffect(id: "chosen", in: slide)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .onTapGesture {
                        withAnimation(Motion.settle) { selection = option }
                    }
            }
        }
        .padding(2)
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .animation(Motion.settle, value: selection)
    }
}

/// On or off, in ink rather than in blue.
struct Switch: View {
    @Binding var on: Bool

    var body: some View {
        Capsule()
            .fill(on ? Palette.ink : Palette.faint)
            .frame(width: 30, height: 18)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle()
                    .fill(Palette.ground)
                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                    .padding(2)
            }
            .contentShape(Capsule())
            .onTapGesture { withAnimation(Motion.settle) { on.toggle() } }
            .animation(Motion.settle, value: on)
    }
}

/// A value moved one stop at a time: − and + either side of it, in the same
/// outlined capsule as a pill. Pressing the value itself takes it home.
struct Steps: View {
    let stops: [Double]
    @Binding var value: Double
    let home: Double
    let label: (Double) -> String

    /// The nearest stop either way — a value between stops, from before
    /// there were stops, still moves to a round one.
    private var below: Double? { stops.last { $0 < value - 0.001 } }
    private var above: Double? { stops.first { $0 > value + 0.001 } }

    var body: some View {
        HStack(spacing: 0) {
            Step(icon: "minus", to: below) { value = $0 }
            Button { value = home } label: {
                Text(label(value))
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(Palette.ink)
                    .frame(minWidth: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back to \(label(home))")
            Step(icon: "plus", to: above) { value = $0 }
        }
        .padding(.horizontal, 2)
        .frame(height: 24)
        .background(Palette.ground, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
    }

    private struct Step: View {
        let icon: String
        let to: Double?
        let act: (Double) -> Void
        @State private var hovering = false

        var body: some View {
            Button { if let to { act(to) } } label: {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(to == nil ? Palette.faint : Palette.ink)
                    .frame(width: 20, height: 20)
                    .background(hovering && to != nil ? Palette.hover : .clear, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(to == nil)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }
}

/// A small capsule that does one thing. Outlined by default; filled in ink
/// when it is the thing you came here to press.
struct Pill: View {
    let title: String
    var filled = false
    var tint: Color = Palette.ink
    let action: () -> Void

    @State private var hovering = false

    init(_ title: String, filled: Bool = false, tint: Color = Palette.ink, action: @escaping () -> Void) {
        self.title = title
        self.filled = filled
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(filled ? Palette.ground : tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(filled ? Palette.ink : (hovering ? Palette.hover : Palette.ground), in: Capsule())
                .overlay(Capsule().strokeBorder(filled ? .clear : Palette.hairline, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }
}

/// Settings › Privacy: the sites allowed to send notifications, each with a
/// way to take it back.
private struct NotificationSites: View {
    @ObservedObject private var notifications = SiteNotifications.shared

    var body: some View {
        let sites = SiteNotifications.allowed
        if !sites.isEmpty {
            ForEach(sites, id: \.self) { site in
                Rule()
                Line(URL(string: site).map(SiteCard.site) ?? site, "Can send notifications") {
                    Pill("Remove") { SiteNotifications.forget(site) }
                }
            }
        }
    }
}
