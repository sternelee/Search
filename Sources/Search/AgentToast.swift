import AppKit

/// The little cards that confirm something happened — ported from orbit-pi's
/// `toast.rs`, which calls them toasts.
///
/// A toast exists because the thing it confirms is easy to miss: an
/// option-click that copied a row looks exactly like an option-click that
/// did not. It is *not* a place to report failures — those keep their own
/// standing line, because a card that fades away is a card a person can
/// miss, and a failure that can be missed is a failure that will be.
///
/// The rules, and why each one:
///
/// - A card's life is its kind's own. Copying something is worth three
///   seconds of the eye; a warning is worth six, because it asks for a
///   decision rather than reporting a fact.
/// - Pressing the same thing twice must not stack two cards. A repeat of a
///   card still on screen refreshes that card — its life restarts from now,
///   so the second press is visible even when the first is nearly gone.
/// - At most `mostVisible` cards. A burst of events must never bury the
///   talk behind its own confirmations; the oldest leaves instead.
struct AgentToast: Equatable {
    /// What it is saying. The kind picks the tint and how long it holds.
    enum Kind: Equatable {
        case info, success, warning, error

        /// Seconds it holds before it starts to go.
        var ttl: CFTimeInterval {
            switch self {
            case .success: return 3
            case .info: return 4
            case .warning: return 6
            case .error: return 8
            }
        }

        var tint: NSColor {
            switch self {
            case .info: return .secondaryLabelColor
            case .success: return .systemGreen
            case .warning: return .systemOrange
            case .error: return .systemRed
            }
        }

        /// A glyph, not an icon file: the terminal's own alphabet.
        var glyph: String {
            switch self {
            case .info: return "·"
            case .success: return "✓"
            case .warning: return "!"
            case .error: return "✕"
            }
        }
    }

    let id: Int
    let kind: Kind
    let title: String
    /// A second line, when there is one worth a line.
    let body: String?
    /// When it was put up, and when it last restarted. A repeat push moves
    /// `born` forward and bumps `revision`, so the card's fade restarts
    /// rather than resuming a fade that already finished.
    var born: CFTimeInterval
    var revision: Int

    /// When it is gone: held, then faded. The fade is the same length for
    /// every kind, because it is about the eye, not about the news.
    static let fade: CFTimeInterval = 0.18

    var dies: CFTimeInterval { born + kind.ttl + Self.fade }

    /// How much of it is still there — 1 while it holds, then a slide to 0.
    func body(at now: CFTimeInterval) -> CGFloat {
        let held = born + kind.ttl
        guard now > held else { return 1 }
        return max(0, 1 - (now - held) / Self.fade)
    }
}

/// The stack itself. Oldest first; the layer paints the newest nearest the
/// corner, which is where the eye goes.
struct AgentToasts: Equatable {
    /// Cards visible at once.
    static let mostVisible = 4

    private(set) var items: [AgentToast] = []
    private var next = 0

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }

    /// Put a card up, or refresh the twin already up. Returns its id.
    @discardableResult
    mutating func push(_ kind: AgentToast.Kind, _ title: String, body: String? = nil,
                       at now: CFTimeInterval) -> Int {
        if let twin = items.firstIndex(where: {
            $0.kind == kind && $0.title == title && $0.body == body
        }) {
            items[twin].born = now
            items[twin].revision += 1
            return items[twin].id
        }
        let id = next
        next += 1
        if items.count >= Self.mostVisible { items.removeFirst() }
        items.append(AgentToast(id: id, kind: kind, title: title, body: body,
                                born: now, revision: 0))
        return id
    }

    /// Take one down by hand. Returns whether it was there.
    @discardableResult
    mutating func dismiss(_ id: Int) -> Bool {
        let before = items.count
        items.removeAll { $0.id == id }
        return items.count != before
    }

    /// Drop the ones whose time is up. Returns whether anything left, so a
    /// caller knows whether the next expiry is worth a timer at all.
    @discardableResult
    mutating func expire(at now: CFTimeInterval) -> Bool {
        let before = items.count
        items.removeAll { now >= $0.dies }
        return items.count != before
    }

    /// When the next card dies — the one moment this stack needs looking at
    /// again. A stack with nothing in it needs no clock, which is why the
    /// layer only runs a timer while something is up.
    var nextDeath: CFTimeInterval? { items.map(\.dies).min() }
}

/// The cards on screen, over the talk's top-right corner — the one part of
/// the plate nothing else claims.
///
/// It draws over the paper rather than beside it: a confirmation is about
/// what is already there, so it appears where the eye already is and takes
/// no room from anything.
final class TerminalToastLayer: NSView {
    /// Room past the agent switch, which floats over the same corner.
    private var topInset: CGFloat { TerminalChatSwitch.height + TerminalChatSwitch.inset * 2 + 6 }
    private static let width: CGFloat = 250
    private static let pad: CGFloat = 8
    private static let gap: CGFloat = 6

    private(set) var stack = AgentToasts()
    private var clock: Timer?
    private var face: NSFont { TerminalLook.face(size: max(10, TerminalLook.size - 2.5)) }
    private var noteFace: NSFont { TerminalLook.face(size: max(9, TerminalLook.size - 4)) }

    override var isFlipped: Bool { false }
    /// Cards are a report, not a target: the talk under them keeps its
    /// clicks, so a card can never make a row unreachable.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func say(_ kind: AgentToast.Kind, _ title: String, body: String? = nil) {
        stack.push(kind, title, body: body, at: CACurrentMediaTime())
        arm()
        needsDisplay = true
    }

    /// Drop the cards whose time is up. Called by the timer and by tests.
    func sweep(at now: CFTimeInterval = CACurrentMediaTime()) {
        let before = stack.count
        stack.expire(at: now)
        if stack.count != before { needsDisplay = true }
        if stack.isEmpty { clock?.invalidate(); clock = nil } else { arm() }
    }

    /// One timer, set for the moment the oldest card dies rather than a
    /// heartbeat: a card stack that is empty costs no frames at all.
    private func arm() {
        clock?.invalidate()
        guard let death = stack.nextDeath else { clock = nil; return }
        let wait = max(0.02, death - CACurrentMediaTime() + 0.005)
        clock = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweep() }
        }
    }

    deinit { clock?.invalidate() }

    // MARK: - draw

    override func draw(_ dirty: NSRect) {
        guard !stack.isEmpty else { return }
        let now = CACurrentMediaTime()
        // Newest at the top: what just happened is the thing being looked
        // for, and an older card sliding down is a card already read.
        var top = bounds.height - topInset
        for toast in stack.items.reversed() {
            let alpha = toast.body(at: now)
            guard alpha > 0 else { continue }
            let card = NSRect(x: bounds.width - Self.width - TerminalChatSwitch.inset, y: 0,
                              width: Self.width, height: height(of: toast))
            let placed = NSRect(x: card.minX, y: top - card.height, width: card.width,
                                height: card.height)
            paint(toast, in: placed, alpha: alpha)
            top = placed.minY - Self.gap
        }
    }

    private func height(of toast: AgentToast) -> CGFloat {
        var tall = Self.pad * 2 + box(toast.title, font: face, width: Self.width - Self.pad * 2 - 16).height
        if let body = toast.body, !body.isEmpty {
            tall += 2 + box(body, font: noteFace, width: Self.width - Self.pad * 2 - 16).height
        }
        return max(26, tall)
    }

    private func box(_ words: String, font: NSFont, width: CGFloat) -> NSRect {
        (words as NSString).boundingRect(
            with: NSSize(width: max(1, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
    }

    private func paint(_ toast: AgentToast, in rect: NSRect, alpha: CGFloat) {
        let ground = TerminalChatView.ground
        ground.withAlphaComponent(0.94 * alpha).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
        TerminalFieldPanel.word.withAlphaComponent(0.12 * alpha).setStroke()
        let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        edge.lineWidth = 1
        edge.stroke()

        // The kind's own colour, as a mark down the left edge and as the
        // glyph — two signals for the same fact, because a colour alone is
        // not something everybody reads.
        toast.kind.tint.withAlphaComponent(0.85 * alpha).setFill()
        NSRect(x: rect.minX + 6, y: rect.minY + 6, width: 2, height: rect.height - 12).fill()

        let glyph = toast.kind.glyph
        let glyphAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(10, face.pointSize), weight: .semibold),
            .foregroundColor: toast.kind.tint.withAlphaComponent(0.95 * alpha),
        ]
        let glyphSize = (glyph as NSString).size(withAttributes: glyphAttrs)
        (glyph as NSString).draw(at: NSPoint(x: rect.minX + Self.pad + 4,
                                            y: rect.maxY - Self.pad - glyphSize.height),
                                 withAttributes: glyphAttrs)

        let left = rect.minX + Self.pad + 4 + glyphSize.width + 5
        let room = rect.width - (left - rect.minX) - Self.pad
        let titleBox = box(toast.title, font: face, width: room)
        toast.title.draw(
            in: NSRect(x: left, y: rect.maxY - Self.pad - titleBox.height,
                       width: room, height: titleBox.height),
            withAttributes: [.font: face,
                             .foregroundColor: TerminalFieldPanel.word.withAlphaComponent(0.92 * alpha)]
        )
        if let body = toast.body, !body.isEmpty {
            let noteBox = box(body, font: noteFace, width: room)
            body.draw(
                in: NSRect(x: left, y: rect.minY + Self.pad, width: room, height: noteBox.height),
                withAttributes: [.font: noteFace,
                                 .foregroundColor: TerminalFieldPanel.word.withAlphaComponent(0.45 * alpha)]
            )
        }
    }
}
