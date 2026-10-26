import SwiftUI

/// The Bots door, in the foot's row beside the other doors: the workspace
/// for independent conversations. An amber dot rides it while a
/// conversation waits to be allowed something, and the count of the ones
/// still working rides its corner the rest of the time — the design asks
/// the door to say what is running, so the workspace can be put away
/// without losing sight of it. The door stands while the workspace is
/// shown, and pressing it again puts the workspace away, as the sidebar's
/// own door does.
struct BotsDoor: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var bots = Bots.shared
    @State private var hovering = false

    private var lit: Bool { browser.botsShowing || hovering }

    var body: some View {
        Button { browser.toggleBots() } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(lit ? Palette.ink.opacity(0.7) : Palette.muted)
                if bots.needsYou > 0 {
                    // Something is waiting to be allowed: that outranks a
                    // count, and the tooltip still carries both.
                    Circle()
                        .fill(Palette.unsafe)
                        .frame(width: 6, height: 6)
                        .alignmentGuide(.top) { $0[.top] + 1 }
                        .alignmentGuide(.trailing) { $0[.trailing] + 2 }
                } else if bots.running > 0 {
                    Text("\(bots.running)")
                        .font(.system(size: 8, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(lit ? Palette.ink.opacity(0.7) : Palette.muted)
                        .alignmentGuide(.top) { $0[.top] + 1 }
                        .alignmentGuide(.trailing) { $0[.trailing] + 1 }
                }
            }
            .frame(width: 26, height: 26)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(browser.botsShowing ? Palette.wash : (hovering ? Palette.hover : .clear))
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        // The corner says what is running in a glyph and a count: the words
        // the tooltip has are the words a reader should hear.
        .accessibilityLabel(help)
        .accessibilityAddTraits(browser.botsShowing ? .isSelected : [])
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: browser.botsShowing)
    }

    private var help: String {
        var said: [String] = []
        if bots.running > 0 {
            said.append("\(bots.running) running")
        }
        if bots.needsYou > 0 {
            said.append(bots.needsYou == 1 ? "1 needs you" : "\(bots.needsYou) need you")
        }
        if !said.isEmpty {
            return "Bots — " + said.joined(separator: ", ") + " · conversations keep running"
        }
        return browser.botsShowing
            ? "Hide Bots — conversations keep running"
            : "Bots — independent conversations"
    }
}
