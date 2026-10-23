import AppKit

// The terminal's own settings: the face it is set in, the colours it paints
// with, the shell and folder it starts in, and the shape of its cursor.
//
// Preferences holds them the way it holds every other setting — a line in
// the settings file, bound to a control in the panel — and leaves them here,
// where the terminal can read them without a Preferences in hand. A change
// is said on `changed`, which is how a terminal already on screen hears
// about it: the panel is not the terminal's to know.

/// What a terminal paints with: the Mac's own light or dark, or a palette
/// that stays put whichever way the Mac is set.
enum TerminalTheme: String, CaseIterable, Identifiable {
    case system, light, dark, solarizedLight, solarizedDark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Match the Mac"
        case .light: return "Light"
        case .dark: return "Dark"
        case .solarizedLight: return "Solarized Light"
        case .solarizedDark: return "Solarized Dark"
        }
    }
}

/// Where the ⌘F panel sits in the frame. Metalterm's own input box is a dock
/// at the bottom, which TERMINAL.md declines to copy — but the *place* is not
/// the furniture, and a find bar over the top corner is a long way from the
/// words you are looking at when the thing you are hunting is the prompt you
/// just typed. So it is a setting, and it starts where it has always been.
enum TerminalFindPlace: String, CaseIterable, Identifiable {
    case top, bottom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .top: return "Top"
        case .bottom: return "Bottom"
        }
    }
}

/// The shape of the cursor. A block covers the whole cell, the way the
/// terminals of old did; a bar or a line is thinner, and leaves the glyph
/// under it readable.
enum TerminalCursor: String, CaseIterable, Identifiable {
    case block, bar, underline

    var id: String { rawValue }

    var title: String {
        switch self {
        case .block: return "Block"
        case .bar: return "Bar"
        case .underline: return "Underline"
        }
    }

    /// The word the shader reads it as: the frame carries this, and the
    /// background pass draws a block while the mark pass draws the rest.
    var word: UInt32 {
        switch self {
        case .block: return 0
        case .bar: return 1
        case .underline: return 2
        }
    }
}

@MainActor
enum TerminalLook {
    /// The terminal's face: a fixed-pitch family's name, and the size in
    /// points it is set in. An empty family is the Mac's own monospaced one.
    static var family = ""
    static var size: Double = home
    static var theme: TerminalTheme = .system
    static var cursor: TerminalCursor = .block
    /// Whether the cursor blinks while the keyboard is in the terminal.
    static var blinks = true
    /// Where the ⌘F panel sits: over the frame's top corner, or over its
    /// bottom one. Only the panel's place — the smear, the bars and the
    /// bleed are the same either way, because they run along the panel's own
    /// leading edge rather than down the frame.
    static var findPlace: TerminalFindPlace = .top
    /// The room left at the terminal's edges, in points.
    static var padding: Double = 4
    /// The program a new terminal runs. Empty is the Mac's own shell.
    static var shell = ""
    /// Where a new terminal starts. Empty is wherever Search itself is.
    static var directory = ""
    /// How many rows of scrollback a terminal keeps.
    static var scrollback = 100_000
    /// Whether a program may take the mouse (1000/1002/1003). With this
    /// off a click is always the start of a selection and the wheel always
    /// scrolls the scrollback — Option does the same thing for one click,
    /// whatever the setting.
    static var takesMouse = true
    /// Whether a program may put something on the clipboard (OSC 52). A
    /// read is never honoured either way: the setting is about writes,
    /// which are the half a program can do on purpose.
    static var takesClipboard = true
    /// Whether ⌘-click opens a link the screen is showing (OSC 8). Off,
    /// the words are words: no underline follows the pointer and nothing
    /// is opened, which is what someone who does not want a click on
    /// something a program printed to leave the machine wants.
    static var opensLinks = true
    /// Whether a program's synchronized output (2026) is waited for: the
    /// program says when it has finished drawing a frame, and the terminal
    /// shows none of it until it says so. Off, the frame is drawn as it
    /// comes, which is what the mode exists to avoid — and what a terminal
    /// that ever got stuck mid-hold would want.
    static var syncsOutput = true

    /// Said whenever any of the above changes. A terminal on screen listens
    /// for it and takes the new look (see TerminalView); nothing else needs
    /// to — the shell and the folder are for terminals not yet made.
    static let changed = Notification.Name("search.terminal.changed")

    /// The scrollback sizes the panel offers, in rows. Every one a whole
    /// thousand, so the panel can write them with the commas in.
    static let scrollbacks = [1_000, 2_000, 5_000, 10_000, 25_000, 50_000, 100_000, 250_000, 500_000]

    /// The sizes the panel offers the face in, and the room it lets a
    /// terminal leave at its edges. Both in half points and whole ones.
    static let sizes: [Double] = stride(from: 9, through: 24, by: 0.5).map { $0 }
    static let paddings: [Double] = stride(from: 0, through: 16, by: 2).map { $0 }

    /// The size a face starts at, and ⌘0 goes back to.
    static let home = 13.0

    /// A face a point bigger or smaller, held within the sizes the panel
    /// offers — the walk the keyboard takes over the same stops the panel
    /// steps, so neither can drift past the ends the other offers.
    static func step(_ size: Double, by step: Int) -> Double {
        min(sizes.last ?? home, max(sizes.first ?? home, size + Double(step)))
    }

    /// The face the terminal draws with. A family that cannot be had is the
    /// Mac's own rather than no terminal at all — a font that was uninstalled
    /// since it was chosen must not cost anyone a shell.
    static func face(size given: CGFloat? = nil) -> NSFont {
        let size = given ?? CGFloat(TerminalLook.size)
        if !family.isEmpty, let named = NSFont(name: family, size: size) { return named }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// A fixed-pitch face this Mac has: the name to keep, and the name to
    /// show. A struct rather than a pair because the panel walks the list
    /// by one of its fields.
    struct Face: Identifiable {
        let name: String
        let title: String
        var id: String { name }
    }

    /// The fixed-pitch faces this Mac has, for the panel's list. Asked once
    /// — the Mac's fonts do not change under a running app.
    static let faces: [Face] = {
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        return names
            .map { Face(name: $0, title: NSFont(name: $0, size: 12)?.displayName ?? $0) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }()

    /// The program a new terminal runs: the one asked for, if it is really
    /// there and can be run, and the Mac's own shell otherwise — the shell
    /// from the environment, and /bin/zsh if even that says nothing.
    static func shellPath() -> String {
        if !shell.isEmpty, FileManager.default.isExecutableFile(atPath: shell) { return shell }
        return ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
    }

    /// Where a new terminal starts: the folder asked for, if it is still
    /// there, and nothing otherwise — a terminal with nowhere to go starts
    /// wherever Search itself is, which is what it has always done.
    static func startDirectory() -> String? {
        guard !directory.isEmpty else { return nil }
        let folder = (directory as NSString).expandingTildeInPath
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder), isFolder.boolValue
        else { return nil }
        return folder
    }

    /// Say that something above changed.
    static func announce() {
        NotificationCenter.default.post(name: changed, object: nil)
    }
}
