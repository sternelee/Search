import AppKit

// The status bar: the terminal's bottom line, under everything, holding
// the folder the shell is in and what Git says about it. Metalterm's own
// bar is furniture its renderer draws; this one is a view because it is
// words rather than cells (the same line the dock's plate walks, and the
// plate sits directly above it).
//
// The two halves of it are news of different kinds. The folder arrives
// with the shell itself (OSC 7, reported per prompt by the same script
// that reports the dock), and Git is *asked for*: `git status
// --porcelain=v2 --branch`, the machine-readable form, run with
// GIT_OPTIONAL_LOCKS=0 so a status bar never blocks the person's own git.
// It is asked for when the folder changes, when a command finishes (the
// `done` turn of a block), and every so often besides — because a branch
// can move without this terminal being the one that moved it, and
// Metalterm's answer to that is a metadata watch, which is a thing the
// port can owe a later round.
//
// The counts are the ones Metalterm parses (its poller reads the same
// porcelain v2 fields): `+` for what is staged, `~` for what is changed
// but not, `?` for what is untracked, `⇡` and `⇣` for how far ahead and
// behind the branch is — shown only when they are not zero, because a
// quiet repository is the thing to say nothing about.

/// What Git said, in the counts a status bar shows. Pure, and parsed out
/// of the machine-readable report so a test can read it the way the bar
/// does.
struct GitStatus: Equatable {
    var branch = ""
    var ahead = 0
    var behind = 0
    var staged = 0
    var unstaged = 0
    var untracked = 0

    /// Whether anything in it is worth saying: a branch alone is, and so
    /// is any count — the bar's question, answered without a view.
    var worthSaying: Bool { !branch.isEmpty || ahead > 0 || behind > 0 || staged > 0 || unstaged > 0 || untracked > 0 }

    /// `git status --porcelain=v2 --branch`, read. Nil when the report
    /// says nothing — no `branch.head`, the shape a folder outside any
    /// repository gives — which is the bar's cue to show the folder alone.
    static func parse(_ report: String) -> GitStatus? {
        var seen = false
        var oid = ""
        var out = GitStatus()
        for line in report.split(separator: "\n") {
            if line.hasPrefix("# branch.head ") {
                seen = true
                let head = String(line.dropFirst("# branch.head ".count))
                // A detached head has no name; the commit it stands on is
                // the honest thing to call it, the way every status line
                // does.
                out.branch = head == "(detached)" ? String(oid.prefix(7)) : head
            } else if line.hasPrefix("# branch.oid ") {
                oid = String(line.dropFirst("# branch.oid ".count))
            } else if line.hasPrefix("# branch.ab ") {
                // `+2 -1`: ahead, then behind, in the units of commits.
                for word in line.dropFirst("# branch.ab ".count).split(separator: " ") {
                    if word.hasPrefix("+") { out.ahead = Int(word.dropFirst()) ?? 0 }
                    if word.hasPrefix("-") { out.behind = Int(word.dropFirst()) ?? 0 }
                }
            } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") || line.hasPrefix("u ") {
                // An entry: `1 <XY> …` changed, `2 <XY> …` renamed, `u <XY> …`
                // unmerged. What matters is the pair — X is the index's
                // word, Y the working tree's — and an unmerged pair says
                // both, which is what a conflict is.
                let parts = line.split(separator: " ", maxSplits: 2)
                if parts.count > 1, parts[1].count == 2 {
                    let xy = parts[1]
                    if xy.first != "." { out.staged += 1 }
                    if xy.last != "." { out.unstaged += 1 }
                }
            } else if line.hasPrefix("? ") {
                out.untracked += 1
            }
        }
        return seen ? out : nil
    }
}

/// The folder as the bar writes it: `~` for home, and a path grown past
/// what a bar can hold is kept from the right end, because it is the
/// leaf of a path that tells you where you are. Pure, for a test to read
/// the same way.
enum StatusBarPath {
    static func write(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var path = url.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { path = "~" + path.dropFirst(home.count) }
        if path.count > 44 {
            let parts = path.split(separator: "/")
            if parts.count > 3 { return "/…/" + parts.suffix(2).joined(separator: "/") }
        }
        return path
    }
}

// MARK: - the asking

/// The git run itself: one serial queue, one process at a time, and a
/// deadline — because a bar that waits on git is a bar that can hang a
/// queue of its own making, and the person's git is never worth that.
enum TerminalGit {
    /// One git at a time: they are short, and the bar asks for them
    /// oftener than they change.
    private static let queue = DispatchQueue(label: "search.terminal.git", qos: .utility)

    /// `git status --porcelain=v2 --branch` in a folder, handed back on
    /// the main thread. Nil when git said nothing usable — not installed,
    /// no repository, or slow past the deadline.
    static func read(cwd: URL, then: @escaping @MainActor (GitStatus?) -> Void) {
        queue.async {
            let said = ask(cwd: cwd)
            Task { @MainActor in then(said) }
        }
    }

    private static func ask(cwd: URL) -> GitStatus? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["status", "--porcelain=v2", "--branch"]
        process.currentDirectoryURL = cwd
        // A status bar that took the person's index lock would be a status
        // bar in the way; this is what the flag is for.
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        // The deadline: a git that has not finished in three seconds is
        // not worth a bar's wait, and one that never finishes (a hung
        // mount) is terminated rather than inherited.
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        if done.wait(timeout: .now() + 3) == .timedOut {
            process.terminate()
            return nil
        }
        guard let report = String(
            data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        ) else { return nil }
        return GitStatus.parse(report)
    }
}

// MARK: - the bar

/// The status bar as a view: the folder, a hairline separator, the branch
/// and its counts — scenery, drawn by AppKit, put in the picture only
/// when the picture changed. It takes no input and asks for no frames.
@MainActor
final class TerminalStatusBar: NSView {
    /// What the last frame wanted drawn, kept to see whether the next one
    /// is worth an AppKit draw at all.
    private struct Picture: Equatable {
        var path = ""
        var git: GitStatus?
    }

    private var picture = Picture()

    /// The face the bar writes with — the terminal's own, a step down from
    /// the dock's, which is a step down from the grid's. Re-read when the
    /// look changes.
    private var face = TerminalLook.face(size: 11)
    /// The width of one glyph in it, measured once rather than asked of
    /// every glyph.
    private var advance: CGFloat = 0

    init() {
        super.init(frame: .zero)
        remeasure()
    }

    required init?(coder: NSCoder) { nil }

    /// A click is the terminal's to answer, not this bar's.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The look changed: the face, and with it the measure of a cell.
    func refont() {
        face = TerminalLook.face(size: 11)
        remeasure()
        needsDisplay = true
    }

    private func remeasure() {
        advance = ("0" as NSString).size(withAttributes: [.font: face as Any]).width.rounded(.up)
    }

    /// The news: the folder and what Git said. True when it differs from
    /// the last picture — and only a picture that changed is a draw worth
    /// asking for.
    func set(path: String, git: GitStatus?) -> Bool {
        var next = Picture()
        next.path = path
        next.git = git
        guard next != picture else { return false }
        picture = next
        return true
    }

    /// One word, in the ink the terminal's theme gives it. Returns where
    /// the word ended, so the next one knows where to begin.
    private func write(
        _ word: String, at x: CGFloat, alpha: CGFloat, rise: CGFloat = 0
    ) -> CGFloat {
        let ink = TerminalFieldPanel.word
        (word as NSString).draw(
            in: NSRect(
                x: x, y: (bounds.height - 15) / 2 - rise,
                width: advance * CGFloat(word.count), height: 15
            ),
            withAttributes: [
                .font: face as Any,
                .foregroundColor: ink.withAlphaComponent(alpha),
            ]
        )
        return x + advance * CGFloat(word.count)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !picture.path.isEmpty else { return }
        let ground = TerminalStatusBar.ground
        // The ground the dock's plate carries, and its hairline: the bar
        // is furniture of the same make.
        ground.withAlphaComponent(DockBox.ground).setFill()
        bounds.fill()
        TerminalFieldPanel.word.withAlphaComponent(0.14).setStroke()
        let hair = NSBezierPath()
        hair.move(to: NSPoint(x: 0, y: bounds.height - 0.5))
        hair.line(to: NSPoint(x: bounds.width, y: bounds.height - 0.5))
        hair.lineWidth = 1
        hair.stroke()
        // The folder, dimmed: the branch is the news, the folder is where
        // the news is happening.
        var x = DockBox.margin
        x = write(picture.path, at: x, alpha: 0.55)
        guard let git = picture.git, git.worthSaying else { return }
        // The separator, and then the branch with what it carries, each
        // count only when it is not zero — a quiet repository is the
        // thing to say nothing about.
        x += advance
        x = write("│", at: x, alpha: 0.30)
        x += advance
        if !git.branch.isEmpty {
            x = write(git.branch, at: x, alpha: 1)
        }
        for (word, alpha) in [
            (git.ahead > 0 ? "⇡\(git.ahead)" : nil, 0.80),
            (git.behind > 0 ? "⇣\(git.behind)" : nil, 0.80),
            (git.staged > 0 ? "+\(git.staged)" : nil, 0.80),
            (git.unstaged > 0 ? "~\(git.unstaged)" : nil, 0.80),
            (git.untracked > 0 ? "?\(git.untracked)" : nil, 0.55),
        ] {
            if let word {
                x += advance
                x = write(word, at: x, alpha: alpha)
            }
        }
    }

    /// The theme's ground, the same read the dock's plate makes of it.
    private static var ground: NSColor {
        let theme = TerminalDraw.Theme.current(TerminalLook.theme)
        return NSColor(
            srgbRed: CGFloat(theme.ground.x), green: CGFloat(theme.ground.y),
            blue: CGFloat(theme.ground.z), alpha: CGFloat(theme.ground.w)
        )
    }
}
