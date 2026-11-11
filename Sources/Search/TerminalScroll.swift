import AppKit

// The pill that says the frame is lifted into the scrollback, and takes it
// back down on a click.
//
// A lifted frame is otherwise invisible as a state: the newest output is
// arriving somewhere below, and nothing on screen says so — the caret is not
// drawn lifted (see Terminal.scene), so the one thing that always marks the
// live screen is missing exactly when a person needs to know they are not
// looking at it. The pill is the mark: how far up the frame is, in lines,
// and a press is the settle a swipe down or an End would make.

/// One small plate over the frame's bottom corner, drawn rather than
/// layered: it changes only when the lift does, which is a redraw an
/// AppKit draw can afford where a Metal frame could not care less.
@MainActor
final class TerminalScrollCue: NSView {
    /// What the last frame wanted said, kept to see whether the next one is
    /// worth a draw at all — the lift is spoken once per change, not once
    /// per frame.
    private var said = 0
    /// The pill's face: the status bar's own size, read again when the look
    /// changes, so the frame's furniture agrees about how tall it writes.
    private var face = TerminalScrollCue.face()

    /// A press settles the frame back at the bottom, the same settle a
    /// swipe down makes; the view owns the words, the terminal owns the
    /// lift.
    var onPress: (() -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = false
        // A button, for whatever is listening in those terms.
        setAccessibilityRole(.button)
        setAccessibilityLabel("Back to the bottom")
    }

    required init?(coder: NSCoder) { nil }

    /// The face the pill writes with: the status bar's own, which follows
    /// the configured size by the status bar's own ratio (see the bar).
    static func face() -> NSFont {
        TerminalLook.face(size: TerminalStatusBar.chrome)
    }

    /// The look changed: the face, and with it the width the words need.
    func refont() {
        face = TerminalScrollCue.face()
        said = 0
        needsDisplay = true
    }

    /// Say where the frame is, and put the pill where it belongs: over the
    /// frame's bottom corner, above the status bar and the dock's strip
    /// (`floor`), in from the edge by the margin the dock and the find
    /// panel keep. Hidden at the bottom, where there is nothing to say.
    func update(lift: Int, in bounds: CGRect, above floor: CGFloat) {
        isHidden = lift <= 0
        guard lift > 0, bounds.width > 1 else { return }
        let title = "↑ \(Self.write(lift))"
        let wide = (title as NSString).size(withAttributes: [.font: face as Any]).width.rounded(.up)
        let pad: CGFloat = 9
        let height: CGFloat = 22
        frame = NSRect(
            x: bounds.width - DockBox.margin - wide - pad * 2,
            y: floor + DockBox.air,
            width: wide + pad * 2,
            height: height
        )
        if said != lift {
            said = lift
            setAccessibilityValue("\(lift) lines up")
            toolTip = "Lifted \(Self.write(lift)) lines — click to go back down"
            title_ = title
            needsDisplay = true
        }
    }

    private var title_ = ""

    /// A count with its commas in, the way the settings panel writes the
    /// scrollback's own sizes.
    private static let counter: NumberFormatter = {
        let counter = NumberFormatter()
        counter.numberStyle = .decimal
        return counter
    }()

    private static func write(_ lines: Int) -> String {
        counter.string(from: NSNumber(value: lines)) ?? "\(lines)"
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !title_.isEmpty else { return }
        // The ground the dock's plate carries, and its hairline: the pill is
        // furniture of the same make, standing over rows it means to cover.
        TerminalScrollCue.ground.withAlphaComponent(DockBox.ground).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        TerminalFieldPanel.word.withAlphaComponent(0.14).setStroke()
        let line = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        line.lineWidth = 1
        line.stroke()
        let ink = TerminalFieldPanel.word.withAlphaComponent(0.80)
        let wide = (title_ as NSString).size(withAttributes: [.font: face as Any, .foregroundColor: ink]).width
        (title_ as NSString).draw(
            at: NSPoint(x: (bounds.width - wide) / 2, y: (bounds.height - face.capHeight) / 2),
            withAttributes: [.font: face as Any, .foregroundColor: ink]
        )
    }

    /// The theme's ground, the same read the dock's plate makes of it.
    private static var ground: NSColor {
        let theme = TerminalDraw.Theme.current(TerminalLook.theme)
        return NSColor(
            srgbRed: CGFloat(theme.ground.x), green: CGFloat(theme.ground.y),
            blue: CGFloat(theme.ground.z), alpha: 1
        )
    }

    /// The press is the pill's whole job; a drag is a press that moved, and
    /// still settles, which is what a person who missed by a pixel wants.
    override func mouseDown(with event: NSEvent) {
        onPress?()
    }
}
