import SwiftUI

/// Looking for a word on the page. A pill in the corner — which end of the
/// page is the one setting the terminal's own ⌘F panel reads, so ⌘F is in
/// one place wherever it is pressed — the same white and hairline as
/// everything else that floats, and gone the moment it isn't wanted.
///
/// The way it comes and goes is Metalterm's, walked by the terminal's own
/// panel (see TerminalField): the pill is drawn out of its corner rather
/// than slid across the page, a bar of light runs ahead of it, and the gap
/// between the two is left as a smear the page shows through. Every
/// keystroke is answered with the dip of that bar, which is the per-glyph
/// half of Metalterm's typing. The curves are read off a leg walked
/// linearly, which is how a SwiftUI view makes the same motion the
/// terminal's panel does without a spring standing in for any of it.
struct FindBar: View {
    @ObservedObject var browser: Browser
    var availableWidth: CGFloat? = nil

    @FocusState private var focused: Bool

    /// The leg of the pill's travel: 0 is gone into the corner, 1 arrived.
    /// Walked linearly by `withAnimation`, and read through Metalterm's own
    /// curves in `OutOfTheCorner` — the leg itself never curves, only what
    /// is read off it does.
    @State private var leg: Double = 0

    /// Where a keystroke's dip has got to: 1 is no dip owed. Metalterm's
    /// `bleed`, the alpha of a caret that has just been thrown.
    @State private var press: Double = 1

    private var narrow: Bool { availableWidth.map { $0 < 290 } ?? false }
    private var fieldWidth: CGFloat {
        guard let availableWidth else { return 150 }
        return max(40, min(160, availableWidth - (narrow ? 80 : 130)))
    }

    /// Which end of the page it hangs off — the same setting the terminal's
    /// own ⌘F panel reads. It arrives away from the edge it hangs off: a
    /// thing that lives at an edge is drawn out of that edge, not across it.
    private var place: TerminalFindPlace { TerminalLook.findPlace }

    var body: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                if browser.needle.isEmpty {
                    Text("Find on page")
                        .foregroundStyle(Palette.ink.opacity(0.3))
                }
                TextField("", text: $browser.needle)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Palette.ink)
                    .accessibilityLabel("Find on page")
                    .accessibilityHint("Type text to search this page. Press Return to find the next match.")
                    .focused($focused)
                    .onSubmit { browser.look(forward: true) }
            }
            .font(.system(size: 12.5))
            .frame(width: fieldWidth)

            // "3 of 17", as the page counted it.
            if let status = browser.findStatus {
                Text(status)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(browser.missed ? Color.red.opacity(0.8) : Palette.muted)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityLabel(status)
                    .accessibilityIdentifier("Find result status")
            }

            // A pane too narrow for them keeps Return and ⇧Return instead.
            if !narrow {
                step("chevron.up", label: "Previous match", help: "Find the previous match.") {
                    browser.look(forward: false)
                }
                step("chevron.down", label: "Next match", help: "Find the next match.") {
                    browser.look(forward: true)
                }
            }

            Menu {
                Toggle("Match case", isOn: $browser.matchCase)
                    .help("Match uppercase and lowercase letters exactly.")
                Toggle("Whole words", isOn: $browser.wholeWords)
                    .disabled(browser.findResult?.nativeFallback == true && !browser.wholeWords)
                    .help("Match complete words. This option is unavailable for PDF pages.")
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(browser.matchCase || browser.wholeWords ? Palette.ink : Palette.muted)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Search options")
            .accessibilityHint("Choose whether to match case or whole words.")
            .help("Search options")

            step("xmark", label: "Close Find on Page", help: "Close the find field and clear its selection.") {
                browser.closeFind()
            }
        }
        .padding(.leading, narrow ? 10 : 16)
        .padding(.trailing, narrow ? 6 : 8)
        .padding(.vertical, 8)
        .background(Palette.ground, in: Capsule())
        .overlay(
            Capsule().strokeBorder(
                browser.missed ? Color.red.opacity(0.35) : Palette.hairline,
                lineWidth: 1
            )
        )
        .shadow(color: .black.opacity(0.10), radius: 18, y: 5)
        .modifier(OutOfTheCorner(leg: leg, press: press))
        .padding(place == .top ? .top : .bottom, 12)
        .padding(.trailing, 14)
        .frame(maxWidth: availableWidth == nil ? nil : .infinity,
               maxHeight: availableWidth == nil ? nil : .infinity,
               alignment: place == .top ? .topTrailing : .bottomTrailing)
        // Gone into the corner it is not there to be clicked: the leg is
        // walked, and the keyboard has no business in a field that has not
        // arrived.
        .allowsHitTesting(browser.finding)
        .accessibilityHidden(!browser.finding)
        .animation(Motion.quick, value: browser.missed)
        .animation(Motion.quick, value: TerminalLook.findPlace)
        .onAppear {
            // A stage that came up while a find was already open — a split
            // stage built by a second ⌘F — has the pill arrive like any
            // other; the single page keeps the pill mounted, and a find
            // opening walks the same leg from `finding` below.
            if browser.finding { arrive() }
        }
        .onChange(of: browser.finding) { _, open in open ? arrive() : leave() }
        .onChange(of: browser.findFocus) { _, _ in focus() }
        .onChange(of: browser.needle) { _, _ in
            // Every keystroke is answered the way Metalterm answers one: the
            // bar of light dips out and is back before the next key lands.
            // Two hops through the run loop, because a dip that had nowhere
            // to come from is no dip at all.
            press = 0
            DispatchQueue.main.async {
                withAnimation(.linear(duration: FieldMotion.dip)) { press = 1 }
            }
        }
    }

    /// Arriving: a leg of Metalterm's own window, the pill drawn out of its
    /// corner along it. Reduce Motion gets the place without the trip.
    private func arrive() {
        if Motion.reduced {
            leg = 1
        } else {
            withAnimation(.linear(duration: FieldMotion.arrive)) { leg = 1 }
        }
        focus()
    }

    /// Leaving: back into the corner, head first, the way it came out.
    private func leave() {
        if Motion.reduced {
            leg = 0
        } else {
            withAnimation(.linear(duration: FieldMotion.leave)) { leg = 0 }
        }
    }

    /// Into the field, and once more a moment later if it didn't take: with
    /// the Mac's keyboard navigation on, the keyboard went to the first
    /// button instead — the back button — until ⌘F was pressed again (#172).
    private func focus() {
        focused = true
        DispatchQueue.main.async {
            if !focused { focused = true }
        }
    }

    private func step(
        _ icon: String,
        label: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Palette.muted)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityHint(help)
        .help(help)
    }
}

// MARK: - the leg, drawn

/// One frame of the pill's leg. `animatableData` is the leg and the
/// keystroke's dip walked together — linearly, which is the point: every
/// curve of Metalterm's is read off them here in `body`, per frame, so what
/// arrives is Metalterm's motion itself and not a spring's idea of it.
private struct OutOfTheCorner: ViewModifier {
    var leg: Double
    var press: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(leg, press) }
        set { leg = newValue.first; press = newValue.second }
    }

    func body(content: Content) -> some View {
        content
            // The plate is the share of the pill the tail has drawn; the
            // light and the smear ride outside the mask, because they are
            // the part of the motion that is ahead of the plate.
            .mask { CornerShare(leg: leg) }
            .overlay {
                Smear(leg: leg)
                    .fill(Palette.ink.opacity(0.16))
            }
            .overlay {
                HeadLight(leg: leg)
                    .fill(Palette.ink.opacity(0.55 * FieldCurve.bleed(press)))
            }
            .opacity(FieldCurve.fade(leg))
    }
}

/// The pill drawn out of its trailing corner: the share of it that exists is
/// the leg's tail, so the leading edge is the edge that travels and the
/// right edge stays put — a thing that lives at the right of the window is
/// drawn out of the corner, never slid across what is beside it.
private struct CornerShare: Shape {
    var leg: Double

    func path(in rect: CGRect) -> Path {
        let drawn = rect.width * CGFloat(FieldCurve.tail(leg))
        return Path(CGRect(
            x: rect.maxX - drawn, y: rect.minY,
            width: max(0.01, drawn), height: rect.height
        ))
    }
}

/// The bar of light on the head — ahead of the plate while it travels, and
/// on the plate's own edge at rest, exactly where Metalterm's caret sits
/// once it has arrived.
private struct HeadLight: Shape {
    var leg: Double

    func path(in rect: CGRect) -> Path {
        let head = rect.maxX - rect.width * CGFloat(FieldCurve.head(leg))
        return Path(CGRect(
            x: head - FieldBox.bar, y: rect.minY + 4,
            width: FieldBox.bar, height: rect.height - 8
        ))
    }
}

/// The smear: the gap the head has opened in front of the plate, the page
/// showing through it — and nothing at all once the two curves have met.
private struct Smear: Shape {
    var leg: Double

    func path(in rect: CGRect) -> Path {
        let head = rect.maxX - rect.width * CGFloat(FieldCurve.head(leg))
        let tail = rect.maxX - rect.width * CGFloat(FieldCurve.tail(leg))
        let span = tail - head
        guard span > 1 else { return Path() }
        return Path(CGRect(
            x: head, y: rect.minY + 4, width: span, height: rect.height - 8
        ))
    }
}
