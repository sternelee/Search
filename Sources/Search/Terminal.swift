import AppKit
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
// leader, and the slave device, opened on its three standard places, is
// then the session's controlling terminal — without Search ever forking,
// which a threaded process must not do. The program is reached through
// /bin/sh, which claims that terminal and execs itself away; why that is
// needed, and what it buys an interrupt, is at spawn.

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
private final class TerminalLane: @unchecked Sendable {
    // Sendable because there is one of these per terminal and one queue
    // that touches it: every read of the screen, the parser and the master
    // happens inside `queue.async`, in one order, which is the promise
    // `@unchecked` is standing in for.
    let screen: Screen
    let parser: Parser
    let queue: DispatchQueue
    // Hops to the main thread, bound after the terminal is whole (see
    // Terminal's init): the lane holds weakly, the terminal owns strongly.
    var said: ((Notice) -> Void)?
    var ended: ((Int32) -> Void)?
    var drawn: ((Damage, Modes) -> Void)?
    var copied: ((String) -> Void)?

    private var reading: DispatchSourceRead?
    private var dying: DispatchSourceProcess?
    private var master: Int32
    private let pid: pid_t
    /// One reading's bytes, kept across readings: a program printing a line
    /// at a time used to allocate a fresh 64 KB buffer for every line, which
    /// is most of what a hundred thousand lines cost.
    private var buffer = [UInt8](repeating: 0, count: 1 << 16)

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
        parser.copied = { [weak self] text in self?.copied?(text) }

        // The reading itself: woken when there is something to read, fed
        // until the kernel says there is nothing more, the damage handed
        // over once at the end of it — one look a reading, whether the
        // reading was one character or a whole log.
        let reads = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        reads.setEventHandler { [weak self] in
            guard let self, self.reading != nil else { return }
            var closed = false
            // Drain everything the kernel has, not one short read per wake:
            // `poll` says whether there is more, and a read from a ready
            // pty returns what is there rather than waiting for a full
            // buffer. A line-at-a-time program then costs one reading for
            // the whole burst, not one reading per line.
            var waiting = pollfd(fd: self.master, events: Int16(POLLIN), revents: 0)
            while true {
                guard poll(&waiting, 1, 0) > 0 else { break }
                let flags = waiting.revents
                waiting.revents = 0
                if flags & Int16(POLLIN) != 0 {
                    let taken = read(self.master, &self.buffer, self.buffer.count)
                    if taken > 0 {
                        self.parser.feed(self.buffer[0..<taken])
                        continue
                    }
                    if taken == 0 {
                        closed = true
                        break
                    }
                    if errno == EINTR { continue }
                    closed = errno == EIO
                    break
                }
                // A slave that has gone leaves the master readable for the
                // hang-up and nothing else; not saying so would leave the
                // read source firing at a lane with nothing to read, and
                // the program's own end waiting behind it forever.
                if flags & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { closed = true }
                break
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
            let code: Int32
            if status & 0x7F == 0 {
                code = (status >> 8) & 0x7F
            } else if status & 0x7F < 0x7F {
                code = -(status & 0x7F)
            } else {
                code = 0
            }
            self.reading?.cancel()
            self.reading = nil
            self.dying = nil
            self.deliver()
            self.ended?(code)
        }
        dying = dies
        dies.resume()
    }

    /// Take the screen's damage and hand it over, with the modes as they
    /// stand at that same moment — read here, in the lane's own order, so
    /// the two can never come apart. Nothing when nothing changed, which
    /// is the promise the renderer keeps: no frames when there is nothing
    /// to see. A mode the keyboard or the hand reads counts as a change,
    /// so a program that sets one and draws nothing is still heard.
    func deliver() {
        let taken = screen.take()
        guard !taken.empty else { return }
        drawn?(taken, screen.modes)
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

    /// Something changed, on the main thread, once a reading is done: what
    /// it was, and the modes a frame and the keyboard need to know about.
    /// Nothing of the screen comes with it: the screen is the lane's, and
    /// whoever reads it has to do it in the lane's own order (`look`,
    /// `scene`) rather than hold a reference to rows being written.
    var onDraw: ((Damage, Modes) -> Void)?

    /// The shell's line editor reported its line (OSC 7784, see
    /// TerminalDock): the dock that stands in for the prompt is told here,
    /// on the main thread, with the frame it owes asked for by the dock
    /// itself. The report says what the line is, never that it changed —
    /// the caller takes the state as it comes and works out the legs.
    var onDock: ((Dock) -> Void)?
    /// The program has ended: the exit, and whether it was Search that
    /// ended it. The last thing this says about itself.
    var onEnded: ((_ exit: Int32, _ byHand: Bool) -> Void)?

    /// The pseudo-terminal this one runs on (`/dev/ttys…`), the one fact
    /// about it that tells it apart from every other. What runs in it can
    /// say where it is with this, in a hook or anywhere else.
    let pty: String?

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
    // what TerminalLane's `@unchecked Sendable` is standing in for: one
    // queue, one order, no shared word.
    private let lane: TerminalLane?

    /// What the lane has said changed since the main thread last heard.
    /// A program printing a line at a time wakes the lane once per line,
    /// and one hop to the main thread per line is a queue of a hundred
    /// thousand frames where one will do: the damage is gathered here, and
    /// the main thread takes it in one go whenever it gets there.
    private var drawPending: (damage: Damage, modes: Modes)?
    private var drawScheduled = false
    private let drawLock = NSLock()

    // MARK: Starting

    init(command: TerminalCommand? = nil, width: Int = 80, height: Int = 24, directory: String? = nil) {
        self.command = command
        let screen = Screen(width: width, height: height)
        screen.backLimit = TerminalLook.scrollback
        let parser = Parser(screen: screen)
        let queue = DispatchQueue(label: "search.terminal." + UUID().uuidString)

        let shell = TerminalLook.shellPath()
        var argv = command?.argv ?? [shell, "-l"]
        var environment = command?.environment ?? ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        environment.append(contentsOf: [
            "TERM=xterm-256color",
            "COLORTERM=truecolor",
            "TERM_PROGRAM=Search",
            "TERM_PROGRAM_VERSION=\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1")",
        ])
        // The user's own shell is asked to mark the commands it runs (OSC
        // 133, OSC 7 — see TerminalShell); a command run on purpose is
        // never wrapped, having asked to be exactly what it is.
        if command == nil {
            (argv, environment) = TerminalShell.wrap(argv: argv, environment: environment)
        }
        let made = Terminal.spawn(
            argv, environment: environment, width: width, height: height,
            directory: directory ?? TerminalLook.startDirectory()
        )
        pid = made?.pid ?? 0
        // The slave's own path, so a program that runs in this terminal can
        // be told apart from one running anywhere else (see Island).
        pty = made?.pty
        lane = made.map {
            TerminalLane(screen: screen, parser: parser, master: $0.master, pid: $0.pid, queue: queue)
        }
        if let lane {
            // Now that the terminal is whole, the lane can hold it weakly.
            lane.said = { [weak self] notice in DispatchQueue.main.async { self?.heard(notice) } }
            lane.copied = { [weak self] text in DispatchQueue.main.async { self?.copied(text) } }
            lane.ended = { [weak self] code in DispatchQueue.main.async { self?.ended(code) } }
            lane.drawn = { [weak self] taken, modes in
                guard let self else { return }
                self.drawLock.lock()
                if var pending = self.drawPending {
                    pending.damage.merge(taken)
                    pending.modes = modes
                    self.drawPending = pending
                } else {
                    self.drawPending = (taken, modes)
                }
                let schedule = !self.drawScheduled
                self.drawScheduled = true
                self.drawLock.unlock()
                if schedule { DispatchQueue.main.async { self.deliverDraw() } }
            }
            queue.async { lane.listen() }
        } else {
            exit = -1
        }
    }

    /// What a terminal is made of: the master fd, the program's pid, and
    /// the slave's path. Started as a session leader of its own
    /// (POSIX_SPAWN_SETSID), the slave opened by the program itself as its
    /// controlling terminal, the master closed to it, everything else Search
    /// has open withheld (POSIX_SPAWN_CLOEXEC_DEFAULT). The path is the
    /// one thing the master's side can know about the slave's, which is why
    /// it comes back too: a program running in this terminal is tied to it
    /// by nothing else (see Island).
    private static func spawn(
        _ argv: [String], environment: [String], width: Int, height: Int, directory: String?
    ) -> (master: Int32, pid: pid_t, pty: String)? {
        // A program that is not there is not a terminal at all. posix_spawn
        // would say so itself, but the shell below starts it now, and a shell
        // reports a program it cannot run as an exit of its own.
        guard let program = argv.first, runnable(program) else { return nil }
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
        // Where it starts: the folder Settings names, when it names one.
        // A command run on purpose starts there too — there is one answer
        // to where a terminal starts, and it is not different for a command.
        if let directory {
            posix_spawn_file_actions_addchdir_np(&actions, directory)
        }
        // A session of its own, and nothing else Search has open.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        // The program is reached through /bin/sh, which takes the session's
        // controlling terminal as it starts. A session leader with a tty open
        // does not own it: making it the controlling one is a call the program
        // makes for itself, and not every program makes it — sh and bash ask,
        // zsh does not. With no controlling terminal there is no foreground
        // group, so ^C reaches the tty and stops there. The exec replaces the
        // shell before it runs a line, so the program is still the process
        // that was spawned, under its own pid, in the session the shell began.
        let carrier = ["/bin/sh", "-c", "exec \"$@\"", "sh"] + argv
        var cargv: [UnsafeMutablePointer<CChar>?] = carrier.map { strdup($0) } + [nil]
        defer { cargv.forEach { free($0) } }
        var cenv: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
        defer { cenv.forEach { free($0) } }
        var child: pid_t = 0
        let made = posix_spawn(&child, carrier[0], &actions, &attributes, &cargv, &cenv)
        close(slave)
        guard made == 0, child > 0 else {
            close(master)
            return nil
        }
        // A program that dies must not take Search with it.
        _ = fcntl(master, F_SETNOSIGPIPE, 1)
        return (master, child, path)
    }

    /// Whether a program can be started at all: a file, and one the system
    /// will run. posix_spawn's own answer, asked before the shell in between
    /// could give a different one.
    private static func runnable(_ path: String) -> Bool {
        var status = stat()
        guard stat(path, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
            return false
        }
        return (status.st_mode & 0o111) != 0
    }

    // MARK: Being talked to, on the main thread

    private func heard(_ notice: Notice) {
        switch notice {
        case .title(let said): title = said
        case .cwd(let folder): cwd = folder
        case .note, .bell: onNotice?(notice)
        case .dock(let report): onDock?(report)
        }
    }

    /// OSC 52: the program put something on the clipboard. Honoured, but
    /// only if the person said programs may — the setting exists because
    /// this is a write into a place the whole machine shares, made by a
    /// program nobody is watching. A *read* never is, whichever way the
    /// setting goes: see the parser, where the refusal is written, because
    /// that is where the question is asked.
    private func copied(_ text: String) {
        guard TerminalLook.takesClipboard else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func drawn(_ taken: Damage, _ modes: Modes) {
        onDraw?(taken, modes)
    }

    /// The one hop the lane scheduled: everything gathered since the last
    /// time, handed over as one reading. `drawScheduled` goes back first,
    /// so damage that arrives while this is being delivered schedules the
    /// next hop rather than being folded into a frame already on its way.
    private func deliverDraw() {
        drawLock.lock()
        let pending = drawPending
        drawPending = nil
        drawScheduled = false
        drawLock.unlock()
        guard let pending else { return }
        drawn(pending.damage, pending.modes)
    }

    /// One moment of the screen, as the renderer sees it: the rows a
    /// frame shows, top first, and the caret where it sits. Taken under
    /// the lane's own order, so a frame never reads a screen being
    /// written — a torn row of half a command is worse than a late one.
    struct Scene {
        var lines: [Row]
        var caret: (x: Int, y: Int)?
        var width: Int
        var height: Int
        var back: Int
        /// The place the frame's first line is at, so that a row of one
        /// frame can be told from the same row of the last: a place is
        /// absolute and never comes round again, and row `r` of a frame is
        /// the place `top + r`. How far a frame has moved up the screen is
        /// what tells the damage-driven cell cache which way to move the
        /// records it keeps, and how far (see TerminalCells).
        var top = 0
        /// Every hyperlink the screen has interned (see Screen.links), so
        /// that whoever draws it, or clicks in it, can turn the number a
        /// square carries back into an address.
        var links: [String] = []
        /// The colour the program gave the caret (OSC 12), or `.plain`
        /// for the theme's own.
        var cursorInk: Paint = .plain
        /// The block a prompt is being built in, if the last mark the shell
        /// printed began one and nothing has ended it since: where the
        /// prompt's first row is, by place. The input dock holds this
        /// moment against the frame (see TerminalDock) — the rows of a
        /// prompt that the dock stands in for are on the screen underneath,
        /// written there by the shell's own echo, and the frame is told to
        /// veil them until the command runs and they become history.
        var prompt: Int? = nil

        /// The whole frame read as text, one row under the last: for the
        /// caller that wants what a program printed rather than its squares.
        /// Each row trims its own padding, as a row's text does.
        var text: String {
            lines.map(\.text).joined(separator: "\n")
        }
    }

    /// The scene a frame would show, `scroll` lines above the bottom: what
    /// the view draws, taken as one moment of the screen. A value, so that
    /// nothing in it moves while the frame is drawn — the rows in it are
    /// copies, though the squares are the screen's own (see Screen.scene) —
    /// and the lane's queue is held for the length of the copy and no
    /// longer. For asks the live screen can answer where it stands, `look`.
    func scene(scroll: Int) -> Scene? {
        guard let lane else { return nil }
        return lane.queue.sync {
            let lifted = min(max(scroll, 0), lane.screen.back.count)
            return lane.screen.scene(lifted: lifted)
        }
    }

    /// One look at the screen without copying it: `body` runs on the lane's
    /// own queue, in the lane's own order, on the live rows — the same
    /// promise `scene` keeps, with none of the allocation. For an ask the
    /// live screen can answer where it stands (where the next command block
    /// begins, how many there are) this is the whole of it; `scene` is for
    /// an ask whose answer has to outlive the look — the rows a frame is
    /// drawn from. The lift is clamped to the scrollback for the reader, so
    /// `body` never has to.
    func look<T>(scroll: Int, _ body: (Screen, Int) -> T) -> T? {
        guard let lane else { return nil }
        return lane.queue.sync {
            body(lane.screen, min(max(scroll, 0), lane.screen.back.count))
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
        pour(Array(text.utf8))
    }

    /// Bytes to the program as they are, with nothing put round them. The
    /// mouse protocols count in bytes and not in characters — 32 plus a
    /// column, which passes 127 on a screen wider than 95 — and a String
    /// would write those as two bytes each, which the program on the other
    /// end reads as a different event entirely.
    func pour(_ bytes: [UInt8]) {
        guard let lane else { return }
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

    /// The scrollback a terminal keeps, changed under one already running:
    /// the limit lives on the screen, which is the lane's, so it is set
    /// there — and the rows a lower limit just put outside it go with it.
    func setScrollback(_ limit: Int) {
        guard let lane else { return }
        lane.queue.async {
            lane.screen.backLimit = limit
            lane.screen.trim()
        }
    }

    /// The screen and the scrollback wiped at a stroke — ⇧⌘K's clear,
    /// typed by hand (TerminalView.clearBuffer). ED 3 takes what has
    /// scrolled off and ED 2 what is showing; a shell's own `clear` only
    /// ever reaches for the screen.
    func clear() {
        guard let lane else { return }
        lane.queue.async {
            lane.screen.eraseDisplay(3)
            lane.screen.eraseDisplay(2)
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

    /// Everything on the screen, scrollback first, for whoever searches it
    /// (see TerminalFind). A read, not a look: the damage is left where it
    /// is, for the draw it belongs to.
    func whole(_ see: @escaping ([Row]) -> Void) {
        guard let lane else { return }
        lane.queue.async {
            see(Array(lane.screen.back) + lane.screen.rows)
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

extension Screen {
    /// The cell the caret is drawn in, or nil when there is nothing to
    /// draw: the view is lifted into the scrollback, the program turned the
    /// caret off (DECTCEM), or the cursor is below the last row. One home
    /// for that rule, so a view that reads it off a live screen and one
    /// that reads it from a copied scene cannot disagree about it.
    func caret(lifted: Int) -> (x: Int, y: Int)? {
        lifted == 0 && visible && y < height ? (x, y) : nil
    }

    /// The frame this screen is showing, `lifted` rows above the bottom of
    /// it: the whole of what the view draws, taken in one look.
    ///
    /// The rows are copied out by value, but a copied row is the same
    /// squares — an `Array` is copied only when it is written to — so a row
    /// of one frame is the same row as the row of the last, which is what
    /// lets a frame be drawn from the one before it (see TerminalCells).
    func scene(lifted: Int) -> Terminal.Scene {
        var lines: [Row] = []
        lines.reserveCapacity(height)
        for row in 0..<height {
            let index = back.count + row - lifted
            if index < 0 { lines.append(Row(width: width)) }
            else if index < back.count { lines.append(back[index]) }
            else { lines.append(rows[index - back.count]) }
        }
        let caret = caret(lifted: lifted)
        return Terminal.Scene(
            lines: lines, caret: caret,
            width: width, height: height, back: back.count,
            // The first line's place: the lift is clamped to the scrollback
            // above, so this is a row that is really there.
            top: place(0) - lifted,
            links: links, cursorInk: cursorInk,
            // The prompt being built, if there is one: the last mark the
            // shell printed began a block and nothing has run it yet.
            prompt: blocks.last(where: { $0.state == .prompt }).map { $0.first }
        )
    }
}
