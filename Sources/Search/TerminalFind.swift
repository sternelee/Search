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
// The state lives in the view itself (an extension cannot hold it); the
// search is asked of the terminal under the lane's own order, so it reads
// rows nobody is writing (see Terminal.whole).

extension TerminalView {

    // MARK: - open, step, close

    /// The find opens with the field over the frame's top corner, the
    /// keyboard in it, and the first match already stepped to. Open, it
    /// takes the keyboard back from itself; the matches stay.
    func openFind() {
        if let findField {
            window?.makeFirstResponder(findField)
            findField.selectText(self)
            return
        }
        let field = NSTextField(string: "")
        field.placeholderString = "Find in scrollback"
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: 12, weight: .regular)
        field.delegate = self
        field.target = self
        field.action = #selector(stepForwardFind(_:))
        findField = field
        addSubview(field)
        placeFindField()
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
        carry()
    }

    /// The find closes with its field, and its highlights with it.
    func closeFind() {
        findField?.removeFromSuperview()
        findField = nil
        findings = []
        finding = -1
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
                if !self.findings.isEmpty { self.stepFind(forward: true) } else { self.present() }
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
        guard findField != nil, !findings.isEmpty else { return [] }
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

    /// The field over the frame's top corner, away from the text.
    func placeFindField() {
        guard let findField else { return }
        let wide: CGFloat = 200
        findField.frame = NSRect(
            x: bounds.width - wide - TerminalDraw.inset - 4,
            y: bounds.height - 24 - TerminalDraw.inset,
            width: wide, height: 22
        )
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

    /// Every keystroke in the field, searched as it stands.
    func controlTextDidChange(_ object: Notification) {
        research()
    }

    /// The keyboard left the field — the find is over, its highlights with
    /// it. A shell asked to type takes the keyboard back.
    func controlTextDidEndEditing(_ object: Notification) {
        if window?.firstResponder !== findField { closeFind() }
    }
}
