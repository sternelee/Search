import SwiftUI

/// A pane is a view of a conversation. Removing it never stops the runtime.
struct BotChatView: View {
    @ObservedObject var browser: Browser
    @ObservedObject var session: BotSession
    @ObservedObject private var bots = Bots.shared
    /// In the panel beside the page, where a conversation can be sent to
    /// fill the stage; in the workspace's own window it already has it.
    var embedded = true
    let focused: Bool
    @State private var choosingPages = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(bots.profile(session.profileID)?.name ?? "Deleted Bot")
                        .font(.system(size: 11, weight: .semibold))
                    Text(session.title).font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(1)
                    if session.ephemeral {
                        Text("Private · not saved").font(.system(size: 9)).foregroundStyle(Palette.muted)
                    }
                }
                Spacer(minLength: 0)
                // Where the run stands, said where the eye already is when
                // it looks at this conversation — and squeezed before the
                // buttons are, so a long status never pushes them out. A run
                // in the line is not working yet, and saying so is the whole
                // point of a queue: the person is told why nothing moves.
                if session.runtime.working {
                    Text(session.runtime.status ?? "working…")
                        .font(.system(size: 10)).foregroundStyle(Palette.faint)
                        .lineLimit(1).truncationMode(.tail).layoutPriority(-1)
                } else if session.runtime.runState == .queued {
                    Text("waiting its turn…")
                        .font(.system(size: 10)).foregroundStyle(Palette.faint)
                        .lineLimit(1).layoutPriority(-1)
                } else if let browser = session.context.browser, !browser.shut,
                          session.context.elsewhere(browser),
                          !session.context.selected.isEmpty {
                    // The window it was handed is in another Space: its pages
                    // are not this one's, and the person should hear it here
                    // rather than from an empty listing (see BotContext).
                    Text("Pages are in another Space")
                        .font(.system(size: 10)).foregroundStyle(Palette.unsafe)
                        .lineLimit(1).truncationMode(.tail).layoutPriority(-1)
                }
                // A count says nothing to someone who has not used it yet;
                // the empty case names the thing it does.
                Button(session.context.selected.isEmpty
                       ? "Attach pages"
                       : "Pages · \(session.context.selected.count)") { choosingPages = true }
                    .font(.system(size: 10)).disabled(session.runtime.occupied || session.archived)
                    .help("Pages this conversation may read")
                // The conversation filling the stage, page and all: the way
                // back is the same door, or Escape (see App's key handling).
                if embedded {
                    Door(icon: browser.botsFull ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                         help: browser.botsFull
                         ? "Put the page back beside the conversation"
                         : "Fill the window with this conversation") {
                        withAnimation(Motion.glide) { browser.botsFull.toggle() }
                    }
                }
                Door(icon: "xmark", help: "Close pane — conversation keeps running") { browser.closeBotPane(session.id) }
            }
            .padding(10)
            .background(focused ? Palette.wash : Palette.ground)
            if session.archived || bots.profile(session.profileID)?.deleted == true {
                Caution("Archived — history is read-only.").padding(8)
            }
            if session.runtime.runState == .interrupted {
                Caution("The previous run was interrupted. No action or approval was replayed. Attach pages again before continuing.").padding(8)
            }
            ChatStage(browser: browser, bot: session.runtime, showsHeader: false)
                .overlay(alignment: .top) {
                    // A conversation with nothing in it yet is not a broken
                    // pane: it says what to do, above the box to do it in.
                    if session.runtime.events.isEmpty, session.runtime.notice == nil,
                       !session.runtime.occupied {
                        Text(session.context.selected.isEmpty
                             ? "Say something to start. Attach a page first if the Bot should read one."
                             : "Say something to start — this Bot can read the pages attached above.")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.faint)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 18)
                            .padding(.top, 10)
                            .allowsHitTesting(false)
                    }
                }
                .disabled(session.archived || bots.profile(session.profileID)?.deleted == true)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { browser.botWorkspace.focus(session.id) })
        .sheet(isPresented: $choosingPages) { BotPagePicker(browser: browser, session: session) }
    }
}

private struct BotPagePicker: View {
    @ObservedObject var browser: Browser
    @ObservedObject var session: BotSession
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []
    @State private var address = ""
    @State private var warning: String?

    private var pages: [Tab] {
        browser.tabs.filter { !$0.chat && !$0.isBlank && (Store.testing || !$0.bench)
            && ["http", "https"].contains($0.pageAddress?.scheme?.lowercased() ?? "") }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pages this conversation may use").font(.headline)
            Text("Only these pages are shared with this conversation. Work pages use this Space's existing sign-ins; this is not an isolated browser profile.")
                .font(.caption).foregroundStyle(Palette.muted)
            ScrollView {
                if pages.isEmpty {
                    Text("No pages open to attach — name one below and it opens as a work page.")
                        .font(.caption).foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                }
                ForEach(pages) { tab in
                    Toggle(tab.title.isEmpty ? tab.pageAddress?.absoluteString ?? "Page" : tab.title,
                           isOn: Binding(get: { selected.contains(tab.id) }, set: { on in
                        if on { selected.insert(tab.id) } else { selected.remove(tab.id) }
                    }))
                }
            }
            HStack {
                TextField("https://… for a new work page", text: $address).textFieldStyle(.roundedBorder)
                Button("Open") {
                    guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                        warning = "Enter an http or https URL."; return
                    }
                    let tab = browser.open(url, foreground: false)
                    Bench.shared.house(tab)
                    selected.insert(tab.id)
                    address = ""
                }
            }
            if let warning { Caution(warning) }
            HStack {
                Button("Cancel") { dismiss() }; Spacer()
                Button("Attach selected") {
                    let tabs = pages.filter { selected.contains($0.id) }
                    guard !tabs.contains(where: { $0.shy || $0.built?.configuration.websiteDataStore.isPersistent == false })
                            || session.runtime.provider.isLocal else {
                        warning = "Private pages require a local model."; return
                    }
                    session.context.bind(browser: browser, tabs: tabs)
                    Bots.shared.save(session)
                    session.objectWillChange.send()
                    dismiss()
                }.disabled(session.runtime.occupied)
            }
        }
        .padding(20).frame(width: 480, height: 420)
        .onAppear { selected = session.context.selected }
    }
}
