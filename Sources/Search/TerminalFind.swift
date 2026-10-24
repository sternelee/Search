import AppKit
import simd

// ⌘F in a terminal tab (see TERMINAL.md): a find over everything the
// terminal has ever said, the scrollback whole. The field sits over the
// frame's corner; the matches are painted over their rows by the renderer's
// mark pass (see TerminalDraw), the one being stood on held harder; stepping
// carries the view to it. The search is literal and case-blind — the
// terminal's own text is plain, and a regex over a scrollback is a tool, not
// a find.
//
// The panel has manners, and they are Metalterm's (see TerminalField): its
// right edge is pinned to the window's margin and the arrival draws its
// leading edge out of that corner on the quartic head of a smear, with the
// smear trailing in the gap behind it; a keystroke bleeds the bar at its leading edge; a
// count that grows pushes the plate's edge out on the same leg, briefly
// thinner for how fast it went; and it leaves the way it came, head first.
// The proportions are Metalterm's `mt_gpu::motion::Cursor`; the plate and the
// bars are this app's, because the bottom dock is the one thing TERMINAL.md
// says not to take.
//
// The state lives in the view itself (an extension cannot hold it); the
// search is asked of the terminal under the lane's own order, so it reads
// rows nobody is writing (see Terminal.whole).

extension TerminalView {

    // MARK: - open, step, close

    /// The find opens with the panel over the frame's top corner, the
    /// keyboard in its field, and the first match already stepped to. Open,
    /// it takes the keyboard back from itself; the matches stay.
    func openFind() {
        if let panel = findPanel {
            window?.makeFirstResponder(panel.field)
            panel.field.selectText(self)
            return
        }
        let field = NSTextField(string: "")
        field.placeholderAttributedString = NSAttributedString(
            string: "Find in scrollback",
            attributes: [
                .font: TerminalLook.face(size: 12),
                .foregroundColor: TerminalFieldPanel.word.withAlphaComponent(0.35),
            ]
        )
        field.font = TerminalLook.face(size: 12)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.delegate = self
        field.target = self
        field.action = #selector(stepForwardFind(_:))

        let panel = TerminalFieldPanel(field: field)
        addSubview(panel)
        findPanel = panel
        findEdge = TerminalFieldBar(tint: TerminalFieldPanel.word)
        findGhost = TerminalFieldSmear(tint: TerminalFieldPanel.word)
        if let findEdge { addSubview(findEdge) }
        if let findGhost { addSubview(findGhost) }

        // A panel that has never been anywhere arrives out of its own corner
        // — the edge it belongs to, and the edge it leaves by.
        let home = findHome()
        if Motion.reduced {
            findMotion.settle(home.leading, wide: home.width)
        } else {
            findMotion.arrive(home.leading, wide: home.width, at: CACurrentMediaTime())
        }
        drawFind()
        present()
        window?.makeFirstResponder(field)
        field.selectText(self)
    }

    /// One match to the next, forward or back, around the end, and the
    /// view carried to it.
    func stepFind(forward: Bool) {
        guard !findings.isEmpty else { return }
        if finding < 0 {
            finding = forward ? 0 : findings.count - 1
        } else {
            finding = (finding + (forward ? 1 : findings.count - 1)) % findings.count
        }
        reflectFind()
        carry()
    }

    /// The find closes with its panel, and its highlights with it. The panel
    /// goes the way it came, head first, and the views are let go by the
    /// frame that finishes the leg (see `drawFind`) — so closing is never a
    /// cut, and the matches go from the screen the moment the panel starts to
    /// leave rather than outliving it.
    func closeFind() {
        guard findPanel != nil else { return }
        findings = []
        finding = -1
        if Motion.reduced {
            findMotion.settle(findMotion.advance(at: CACurrentMediaTime()).head, wide: 0)
            tearDownFind()
        } else {
            findMotion.leave(at: CACurrentMediaTime())
        }
        present()
    }

    // MARK: - the search

    /// The search again, for the field's text as it is now — the whole
    /// screen asked of the terminal, the matches stepped to when they come.
    func research() {
        let needle = findField?.stringValue ?? ""
        terminal.whole { [weak self] rows in
            DispatchQueue.main.async {
                guard let self else { return }
                self.findings = needle.isEmpty ? [] : TerminalView.matches(for: needle, in: rows)
                self.finding = -1
                if !self.findings.isEmpty {
                    self.finding = 0
                    self.reflectFind()
                    self.carry()
                } else {
                    self.reflectFind()
                    self.present()
                }
            }
        }
    }

    /// The places a needle shows in rows of the grid: row, column, and
    /// cells wide — whole-screen places, the row an index of the whole
    /// (scrollback first, the screen after it). Case-blind, literal.
    static func matches(for needle: String, in rows: [Row]) -> [(row: Int, col: Int, len: Int)] {
        guard !needle.isEmpty else { return [] }
        var hits: [(row: Int, col: Int, len: Int)] = []
        for (index, row) in rows.enumerated() {
            let text = row.text
            var room = text.startIndex..<text.endIndex
            while let hit = text.range(of: needle, options: .caseInsensitive, range: room) {
                // A cell is a character: the column is the distance from
                // the row's head, the width the needle's own length.
                hits.append((index, text.distance(from: text.startIndex, to: hit.lowerBound), needle.count))
                room = hit.upperBound..<text.endIndex
            }
        }
        return hits
    }

    // MARK: - in a frame

    /// The matches a frame shows, as the renderer's mark pass wants them:
    /// cell, row, cells wide, one tall. The one being stood on is left to
    /// `found(in:)`, which holds it harder.
    func finds(in scene: Terminal.Scene) -> [simd_float4] {
        guard findPanel != nil, !findings.isEmpty else { return [] }
        var hits: [simd_float4] = []
        for (place, hit) in findings.enumerated() {
            if place == finding { continue }
            if let rect = rect(of: hit, in: scene) { hits.append(rect) }
        }
        return hits
    }

    /// The match being stood on, as the renderer wants it, or nothing.
    func found(in scene: Terminal.Scene) -> simd_float4? {
        guard findings.indices.contains(finding) else { return nil }
        return rect(of: findings[finding], in: scene)
    }

    /// One whole-screen hit, as the renderer's mark pass wants it: the
    /// row it lands on in this frame, if it lands on this frame at all.
    private func rect(of hit: (row: Int, col: Int, len: Int), in scene: Terminal.Scene) -> simd_float4? {
        // A whole-screen row lands on the frame lifted `lift` lines: its
        // row is its place over the whole, minus the scrollback, plus the
        // lift (see Terminal.scene).
        let row = hit.row - scene.back + lift
        guard row >= 0, row < scene.lines.count else { return nil }
        let col = min(hit.col, scene.width - 1)
        let len = max(1, min(hit.len, scene.width - col))
        return simd_float4(Swift.Float(col), Swift.Float(row), Swift.Float(len), 1)
    }

    // MARK: - private hands

    /// Where the panel belongs when it is still: its leading (left) edge, its
    /// own width, and the band of the frame it sits over. The plate hangs off
    /// the right edge — 14 points in — so an edge that moves is the left one,
    /// and that is the edge the smear is drawn on.
    ///
    /// Which end of the frame it hangs off is the one thing about it that is
    /// a matter of taste (see TerminalLook.findPlace): the top corner, where
    /// it has always been, or the bottom one, which is where Metalterm puts
    /// its own input box. The view is not flipped, so the top is a large y and
    /// the bottom a small one, and the panel's height is the same either way.
    private func findHome() -> (leading: CGFloat, width: CGFloat, y: CGFloat, height: CGFloat) {
        FieldBox.home(
            wide: findPanel?.wanted ?? 260, in: bounds, at: TerminalLook.findPlace
        )
    }

    /// The field's panel over the frame's corner — and every frame of the leg
    /// it is on, until it is still. Called from `layout()` and from `frame()`;
    /// it draws nothing itself, it puts the frame's model on the views and
    /// asks for the next frame while there is one owed.
    func placeFindField() {
        guard findPanel != nil else { return }
        let home = findHome()
        findMotion.place(home.leading, wide: home.width, at: CACurrentMediaTime())
        drawFind()
    }

    /// One frame of the panel: the plate placed where the tail has got to,
    /// squeezed by how fast it is going, faded by which leg it is on, and the
    /// two curves — the bar of light on the head, and the smear filling the
    /// gap the head has opened in front of the plate.
    func drawFind() {
        guard let panel = findPanel else { return }
        let now = CACurrentMediaTime()
        let home = findHome()
        let model = findMotion.advance(at: now)
        if findMotion.isAway {
            tearDownFind()
            present()
            return
        }
        // The plate rides the tail, so the head runs ahead of it and the gap
        // between them is the smear: light off the leading edge with the
        // terminal showing through behind it. Its right edge is pinned to the
        // window's margin and the travel pulls its leading edge out to the
        // left — the panel is drawn out of the frame's corner rather than slid
        // across it, which is what a thing that lives at the right edge of the
        // window does. A plate sliding in from off the edge would paint itself
        // over whatever is beside the window.
        let margin = home.leading + home.width
        let width = max(0, (margin - model.tail) * model.squeeze)
        panel.frame = NSRect(
            x: margin - width, y: home.y, width: width, height: home.height
        )
        panel.alphaValue = model.body
        let band = NSRect(
            x: 0, y: 4, width: FieldBox.bar, height: home.height - 8
        )
        if let findEdge {
            findEdge.frame = band.offsetBy(dx: model.head - FieldBox.bar, dy: home.y)
            findEdge.alphaValue = model.edgeAlpha * model.body
        }
        if let findGhost {
            // The smear is the gap itself — Metalterm's `warp_span` returns the
            // two positions and the distance between them, and the caller draws
            // one bar across the whole of it. A fixed-length stub would not be
            // a smear; it would be a second bar following the first.
            let span = model.smear
            findGhost.frame = NSRect(
                x: min(model.head, model.tail) - FieldBox.bar,
                y: home.y + 4,
                width: max(0, span),
                height: home.height - 8
            )
            // Faint, and fainter the further it is stretched: a long throw is a
            // smudge of light, not a bright rule across the terminal.
            findGhost.alphaValue = 0.34 * min(1, FieldBox.reach / max(1, span)) * model.body
        }
        // The next frame of the leg, asked for off the run loop rather than
        // from in here: a pacer with no display link to wait for draws on the
        // call itself, and asking from inside a frame would be a frame inside
        // a frame. One hop is all it takes, and the link coalesces the rest.
        guard findMotion.moving(at: now) else { return }
        findAsking = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.findAsking else { return }
            self.findAsking = false
            self.present()
        }
    }

    /// The panel and its bars let go — the frame that finished the leaving
    /// leg, or a close with nothing to animate.
    private func tearDownFind() {
        findPanel?.removeFromSuperview()
        findEdge?.removeFromSuperview()
        findGhost?.removeFromSuperview()
        findPanel = nil
        findEdge = nil
        findGhost = nil
        findAsking = false
        findings = []
        finding = -1
    }

    /// The words beside the field — how many, and which — and the plate
    /// asked for the room they take. A count that grew is a plate whose
    /// leading edge has to move out, which is a leg of its own.
    func reflectFind() {
        guard let panel = findPanel else { return }
        let needle = findField?.stringValue ?? ""
        if needle.isEmpty {
            panel.count.stringValue = ""
        } else if findings.isEmpty {
            panel.count.stringValue = "none"
        } else {
            panel.count.stringValue = "\(max(1, finding + 1)) of \(findings.count)"
        }
        panel.needsLayout = true
        panel.layoutSubtreeIfNeeded()
        panel.remeasure()
        placeFindField()
    }

    /// Carry the view to the match being stood on: a match in the
    /// scrollback is brought to the top of the frame, a match on the
    /// screen stays where it is.
    private func carry() {
        guard let scene = terminal.scene(scroll: lift),
              findings.indices.contains(finding) else { return }
        let hit = findings[finding]
        // The row the hit wants in this frame: the top of the scrollback's
        // own, or the hit's own place on the screen.
        let wants = hit.row < scene.back ? 2 : hit.row - scene.back
        lift = min(max(wants + scene.back - hit.row, 0), scene.back)
        present()
    }

    @objc func stepForwardFind(_ sender: Any?) {
        stepFind(forward: true)
    }
}

extension TerminalView: NSTextFieldDelegate {

    /// Every keystroke in the field, searched as it stands — and answered
    /// where it lands: the bar at the panel's leading edge bleeds once,
    /// which is Metalterm's per-glyph half of typing, and the one part of
    /// the panel that must not wait for a search to come back.
    func controlTextDidChange(_ object: Notification) {
        findMotion.press(at: CACurrentMediaTime())
        drawFind()
        present()
        research()
    }

    /// The keyboard left the field — the find is over, its highlights with
    /// it. A shell asked to type takes the keyboard back.
    ///
    /// The event is not the answer to "did the person leave the field":
    /// AppKit posts it while it is still moving the keyboard, including the
    /// session it ends on its way to making the field's own editor — which
    /// is what opening the panel does. Reading it as an answer closed the
    /// panel the instant it opened, so ⌘F showed a flash in the corner and
    /// nothing else ever since the panel moved to the top: the plate was
    /// torn down on the same run loop turn that laid it down.
    ///
    /// So the question is asked once the move is over, and it is asked of
    /// the field's own editor rather than of the window's responder — while
    /// the words are being typed the first responder is the field *editor*,
    /// never the field, so comparing the responder to the field answers
    /// "left" at every moment of a session that never stopped.
    func controlTextDidEndEditing(_ object: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let field = self.findField else { return }
            if field.currentEditor() == nil { self.closeFind() }
        }
    }
}
