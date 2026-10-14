import Combine
import Darwin
import Foundation

// The terminal itself: a program behind a pseudo-terminal, and everything
// between it and the rest of Search. The program — a shell, in the first
// place, though nothing here knows it is one — is started on the other end
// of a pair of devices the kernel stands between (openpty's master and
// slave), with its own session and its own controlling terminal, so that
// the job control every shell expects works exactly as it does in any
// terminal an app has ever shown.
//
// The reading, the parsing (see TerminalParse), and the screen it all
// writes into (see TerminalGrid) are one thing, done in one order on one
// serial queue — the lane (see TerminalLane below). Nothing of the lane
// is touched from anywhere but the lane, and the lane never reaches back
// except on the main thread, with what has changed since the last look.
// No frames when nothing changed is a promise that starts here: `onDraw`
// is called once a reading is done, and only when something came of it.
//
// The start of the process is the same one AIEngine uses (posix_spawn,
// with the file actions doing the wiring), with one difference that makes
// a terminal a terminal: POSIX_SPAWN_SETSID makes the program a session
// leader, and the slave device opened *by the program itself* then becomes
// its controlling terminal — the property of a session leader opening a
// tty — without Search ever forking, which a threaded process must not do.

/// The command behind a terminal, when it is not the shell the Mac uses.
struct TerminalCommand: Equatable {
    var argv: [String]
    var environment: [String]?
}

/// The lane the terminal lives on: the screen, the parser, the master fd,
/// and the sources that feed them — all on one serial queue, all plain,
/// with no actor anywhere (which is why it is not nested in Terminal: a
/// type nested in an isolated one is isolated with it). Reaching back is
/// by the three closures it is born with, which hop to the main thread
/// themselves.
private final class TerminalLane {
    let screen: Screen
    let parser: Parser
    let queue: DispatchQueue
    // Hops to the main thread, bound after the terminal is whole (see
    // Terminal's init): the lane holds weakly, the terminal owns strongly.
    var said: ((Notice) -> Void)?
    var ended: ((Int32) -> Void)?
    var drawn: ((Damage) -> Void)?

    private var reading: DispatchSourceRead?
    private var dying: DispatchSourceProcess?
    private var master: Int32
    private let pid: pid_t

    init(screen: Screen, parser: Parser, master: Int32, pid: pid_t, queue: DispatchQueue) {
        self.screen = screen
        self.parser = parser
        self.master = master
        self.pid = pid
        self.queue = queue
    }

    // MARK: The reading

    /// From here on, everything is the lane's: the sources start, the
    /// parser answers, the program's words arrive.
    func listen() {
        // The program's answers go back as they are asked; what it says
        // aloud comes over on the main thread.
        parser.reply = { [master] text in
            _ = TerminalLane.pour(master, Array(text.utf8))
        }
        parser.say = { [weak self] notice in self?.said?(notice) }

        // The reading itself: woken when there is something to read, fed
        // until the kernel says there is nothing more, the damage handed
        // over once at the end of it — one look a reading, whether the
        // reading was one character or a whole log.
        let reads = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        reads.setEventHandler { [weak self] in
            guard let self, self.reading != nil else { return }
            var buffer = [UInt8](repeating: 0, count: 1 << 16)
            var closed = false
            while true {
                let taken = read(self.master, &buffer, buffer.count)
                if taken > 0 {
                    self.parser.feed(Array(buffer[0..<taken]))
                    if taken < buffer.count { break }
                } else if taken == 0 {
                    closed = true
                    break
                } else {
                    // EIO: every reader on the other end is gone, which is
                    // what a program ending looks like from this side.
                    closed = errno == EIO
                    break
                }
            }
            self.deliver()
            if closed {
                reads.cancel()
            }
        }
        reads.setCancelHandler { [weak self] in
            guard let self else { return }
            self.reading = nil
            self.deliver()
            close(self.master)
            self.master = -1
        }
        reading = reads
        reads.resume()

        // The program's end, told by the system rather than guessed from
        // a silent master.
        let dies = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        dies.setEventHandler { [weak self] in
            guard let self else { return }
            var status: Int32 = 0
            waitpid(self.pid, &status, WNOHANG)
            // The wait the macros would do, written where Swift can see
            // it: a low byte of zero is an exit, the code above it;
            // anything else is a signal, the negated code to tell the
            // two apart.
            let code = status & 0x7F == 0 ? (status >> 8) & 0x7F
                : (status & 0x7F) < 0x7F ? -(status & 0x7F) : 0
            self.reading?.cancel()
            self.reading = nil
            self.dying = nil
            self.deliver()
            self.ended?(code)
        }
        dying = dies
        dies.resume()
    }

    /// Take the screen's damage and hand it over. Nothing when nothing
    /// changed — the promise the renderer keeps: no frames when there is
    /// nothing to see.
    func deliver() {
        let taken = screen.take()
        guard !taken.empty else { return }
        drawn?(taken)
    }

    // MARK: Talking to it

    /// Write to the program's fd, all of it, or say it couldn't be.
    func pour(_ bytes: [UInt8]) -> Bool {
        TerminalLane.pour(master, bytes)
    }

    private static func pour(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty, fd >= 0 else { return true }
        var sent = 0
        while sent < bytes.count {
            let took = bytes.withUnsafeBytes { raw in
                write(fd, raw.baseAddress!.advanced(by: sent), bytes.count - sent)
            }
            if took <= 0 { return false }
            sent += took
        }
        return true
    }

    /// The screen's new size: the slave's with it, and the kernel tells
    /// the program itself (SIGWINCH to the foreground group of the
    /// controlling terminal, which is why the program starts with one).
    func resize(width: Int, height: Int) {
        screen.resize(width: width, height: height)
        var win = winsize(ws_row: UInt16(max(1, height)), ws_col: UInt16(max(1, width)), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &win)
        deliver()
    }
}

@MainActor
final class Terminal: ObservableObject, Identifiable {
    let id = UUID()

    /// The window title the program set (OSC 0 and 2), if it has set one.
    @Published private(set) var title = ""
    /// Where the shell is (OSC 7), for the field and the file menus.
    @Published private(set) var cwd: URL?
    /// The exit of the program, when it has ended. Zero is the good one.
    @Published private(set) var exit: Int32?

    /// The screen, with what has changed since the last look — on the
    /// main thread, once a reading is done. The screen is the lane's while
    /// it is being drawn: a look is a moment of it, and the renderer that
    /// comes (see TerminalDraw) is the one that makes the moment formal.
    var onDraw: ((Screen, Damage) -> Void)?
    /// The program has ended: the exit, and whether it was Search that
    /// ended it. The last thing this says about itself.
    var onEnded: ((_ exit: Int32, _ byHand: Bool) -> Void)?

    /// What the program said that the screen can't hold (see Notice), on
    /// the main thread. BEL comes here too.
    var onNotice: ((Notice) -> Void)?

    private let command: TerminalCommand?
    private var pid: pid_t = 0

    /// Whether Search stopped the program itself, so the exit that comes
    /// back is not shown as the program's own doing.
    private var byHand = false

    // The lane, and everything it holds: the screen, the parser, the
    // master fd — none of it touched from anywhere but the lane, which is
    // what `nonisolated(unsafe)` is promising the compiler it can stop
    // worrying about: one queue, one order, no shared word.
    nonisolated(unsafe) private let lane: TerminalLane?

    // MARK: Starting

    init(command: TerminalCommand? = nil, width: Int = 80, height: Int = 24) {
        self.command = command
        let screen = Screen(width: width, height: height)
        let parser = Parser(screen: screen)
        let queue = DispatchQueue(label: "search.terminal." + UUID().uuidString)

        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        var argv = command?.argv ?? [shell, "-l"]
        var environment = command?.environment ?? ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        environment.append(contentsOf: [
            "TERM=xterm-256color",
            "COLORTERM=truecolor",
            "TERM_PROGRAM=Search",
            "TERM_PROGRAM_VERSION=\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1")",
        ])
        var pair: (master: Int32, pid: pid_t)?
        // The user's own shell is asked to mark the commands it runs (OSC
        // 133, OSC 7 — see TerminalShell); a command run on purpose is
        // never wrapped, having asked to be exactly what it is.
        if command == nil {
            (argv, environment) = TerminalShell.wrap(argv: argv, environment: environment)
        }
        if let made = Terminal.spawn(argv, environment: environment, width: width, height: height) {
            pair = made
            pid = made.pid
        }

        var holding: TerminalLane?
        if let pair {
            holding = TerminalLane(
                screen: screen, parser: parser, master: pair.master, pid: pair.pid, queue: queue)
        }
        lane = holding
        if let lane, pair != nil {
            // Now that the terminal is whole, the lane can hold it weakly.
            lane.said = { [weak self] notice in DispatchQueue.main.async { self?.heard(notice) } }
            lane.ended = { [weak self] code in DispatchQueue.main.async { self?.ended(code) } }
            lane.drawn = { [weak self] taken in DispatchQueue.main.async { self?.drawn(taken) } }
            queue.async { lane.listen() }
        } else {
            exit = -1
        }
    }

    /// The pair a terminal is made of: the master fd, and the program's
    /// pid. Started as a session leader of its own (POSIX_SPAWN_SETSID),
    /// the slave opened by the program itself as its controlling terminal,
    /// the master closed to it, everything else Search has open withheld
    /// (POSIX_SPAWN_CLOEXEC_DEFAULT).
    private static func spawn(_ argv: [String], environment: [String], width: Int, height: Int) -> (master: Int32, pid: pid_t)? {
        var master: Int32 = 0
        var slave: Int32 = 0
        var win = winsize(ws_row: UInt16(max(1, height)), ws_col: UInt16(max(1, width)), ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &win) == 0 else {
            return nil
        }
        // The slave's path, for the program to open itself. openpty gives
        // the fd; the session leader's own open is what makes it the
        // controlling terminal, and only the path can be opened again.
        var name = [CChar](repeating: 0, count: 1024)
        guard ttyname_r(slave, &name, name.count) == 0, name[0] != 0 else {
            close(master)
            close(slave)
            return nil
        }
        let path = String(cString: name)

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        // The program opens the slave itself, on all three of the standard
        // places, as a session leader — its controlling terminal.
        posix_spawn_file_actions_addopen(&actions, 0, path, O_RDWR, 0o622)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)
        // The master is Search's; never the program's.
        posix_spawn_file_actions_addclose(&actions, master)
        posix_spawn_file_actions_addclose(&actions, slave)
        // A session of its own, and nothing else Search has open.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var cargv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { cargv.forEach { free($0) } }
        var cenv: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
        defer { cenv.forEach { free($0) } }
        var child: pid_t = 0
        let made = posix_spawn(&child, argv[0], &actions, &attributes, &cargv, &cenv)
        close(slave)
        guard made == 0, child > 0 else {
            close(master)
            return nil
        }
        // A program that dies must not take Search with it.
        _ = fcntl(master, F_SETNOSIGPIPE, 1)
        return (master, child)
    }

    // MARK: Being talked to, on the main thread

    private func heard(_ notice: Notice) {
        switch notice {
        case .title(let said): title = said
        case .cwd(let folder): cwd = folder
        case .note, .bell: onNotice?(notice)
        }
    }

    private func drawn(_ taken: Damage) {
        guard let lane else { return }
        onDraw?(lane.screen, taken)
    }

    /// One moment of the screen, as the renderer sees it: the rows a
    /// frame shows, top first, and the caret where it sits. Taken under
    /// the lane's own order, so a frame never reads a screen being
    /// written — a torn row of half a command is worse than a late one.
    struct Scene {
        /// A gutter mark, as the frame sees it (see TerminalDraw): the red
        /// one of a failed command, the dim one of a command still running.
        struct Mark: Equatable {
            var row: Int          // the first row it covers, in the frame
            var span: Int         // the rows it covers, one at least
            var failed: Bool
        }

        var lines: [Row]
        var marks: [Mark] = []
        var caret: (x: Int, y: Int)?
        var width: Int
        var height: Int
        var back: Int
    }

    /// The scene a frame would show, `scroll` lines above the bottom.
    func scene(scroll: Int) -> Scene? {
        guard let lane else { return nil }
        return lane.queue.sync {
            let screen = lane.screen
            let lifted = min(max(scroll, 0), screen.back.count)
            var lines: [Row] = []
            lines.reserveCapacity(screen.height)
            for row in 0..<screen.height {
                let index = screen.back.count + row - lifted
                if index < 0 { lines.append(Row(width: screen.width)) }
                else if index < screen.back.count { lines.append(screen.back[index]) }
                else { lines.append(screen.rows[index - screen.back.count]) }
            }
            let caret = lifted == 0 && screen.visible && screen.y < screen.height
                ? (screen.x, screen.y) : nil
            // The gutter marks of the command blocks (OSC 133), a place at a
            // time: the visible row of a place is found the way the rows
            // above were, the whole screen kept in mind. A block rolled past
            // the top of the scrollback is gone with its rows.
            var marks: [Scene.Mark] = []
            let ending = screen.place(screen.y)
            for block in screen.blocks {
                // A finished command that went fine leaves no mark — a
                // glance only wants the failures (red) and the command
                // still running (a wisp from where it began to the caret).
                // Striping every finished block's whole span reads as a
                // stray vertical line once the output is tall.
                if block.state == .done && !block.failed { continue }
                let end = block.last ?? ending
                let first = block.first - screen.backBase - screen.back.count + lifted
                let last = end - screen.backBase - screen.back.count + lifted
                let low = max(first, 0), high = min(last, screen.height - 1)
                guard low <= high else { continue }
                marks.append(Scene.Mark(row: low, span: high - low + 1, failed: block.failed))
            }
            return Scene(
                lines: lines, marks: marks, caret: caret,
                width: screen.width, height: screen.height, back: screen.back.count
            )
        }
    }

    private func ended(_ code: Int32) {
        exit = code
        onEnded?(code, byHand)
    }

    // MARK: Talking to it

    /// Write to the program. What the keyboard sends, and the answers to
    /// its questions.
    func send(_ text: String) {
        guard let lane else { return }
        let bytes = Array(text.utf8)
        lane.queue.async {
            _ = lane.pour(bytes)
        }
    }

    /// A paste, wrapped the way the program asked to have it (2004), or
    /// as plain characters when it never asked.
    func paste(_ text: String) {
        guard let lane else { return }
        lane.queue.async {
            let wrapped = lane.screen.bracketedPaste ? "\u{1b}[200~\(text)\u{1b}[201~" : text
            _ = lane.pour(Array(wrapped.utf8))
        }
    }

    /// The screen's new size: the slave's with it, and the program told by
    /// the kernel itself.
    func resize(width: Int, height: Int) {
        guard let lane else { return }
        lane.queue.async {
            lane.resize(width: width, height: height)
        }
    }

    /// End the program: the hangup a closing terminal has always sent,
    /// the polite way first and the sure one shortly after.
    func stop() {
        guard exit == nil, pid > 0 else { return }
        byHand = true
        let pid = self.pid
        kill(pid, SIGHUP)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            kill(pid, SIGTERM)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            kill(pid, SIGKILL)
        }
    }

    /// Look at the screen where it lives, on the lane — for whoever draws
    /// (see TerminalDraw, when there is one) and whoever tests. The look
    /// takes the damage with it.
    func look(_ see: @escaping (Screen) -> Void) {
        guard let lane else { return }
        lane.queue.async {
            _ = lane.screen.take()
            see(lane.screen)
        }
    }

    /// Everything on the screen, scrollback first, for whoever searches it
    /// (see TerminalFind). A read, not a look: the damage is left where it
    /// is, for the draw it belongs to.
    func whole(_ see: @escaping ([Row]) -> Void) {
        guard let lane else { return }
        lane.queue.async {
            see(lane.screen.back + lane.screen.rows)
        }
    }

    /// What the tab is called: the title the program set, or the command
    /// itself, or a terminal — the last what a tab is called before
    /// anything has happened in it.
    var named: String {
        if !title.isEmpty { return title }
        if let command, let last = command.argv.last { return last }
        return "Terminal"
    }
}
