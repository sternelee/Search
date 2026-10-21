import Foundation

// The shell integration of a terminal tab (see TERMINAL.md). The shell
// itself is asked to mark the commands it runs — OSC 133 around them, OSC 7
// wherever it goes — the way metalterm does it, and the way it is done here
// is the same one's promise kept: nothing of the user's is ever written,
// not one line of any rc file. Every shell loads its own configuration from
// a place the environment names — zsh reads $ZDOTDIR, bash takes --rcfile —
// so the integration is a few files of ours in the app's own folder, each
// one sourcing the user's own first and untouched. A shell that has no such
// place (fish, sh) simply runs without marks, as itself.
//
// The marks: A where a prompt starts, C where the command runs, D with the
// exit where it ends. The parser feeds them to the grid (see
// TerminalParse), which keeps the blocks by place (see TerminalGrid), and
// the view walks those blocks to jump between commands (⌘↑, ⌘↓).
enum TerminalShell {

    /// The argv and environment of a shell about to be started, wrapped
    /// so that it marks its commands — when it is a shell that can be
    /// asked, with files that are ours. A command run on purpose is never
    /// wrapped: it asked to be exactly what it is.
    static func wrap(argv: [String], environment: [String]) -> (argv: [String], environment: [String]) {
        guard let program = argv.first else { return (argv, environment) }
        let name = (program as NSString).lastPathComponent
        switch name {
        case "zsh":
            var environment = environment
            environment.append("ZDOTDIR=\(folder.path)")
            write(".zshenv", zshEnv)
            write(".zprofile", source(".zprofile"))
            write(".zshrc", zshrc)
            write(".zlogin", source(".zlogin"))
            return (argv, environment)
        case "bash":
            // A login shell reads its profiles and never the --rcfile; an
            // interactive one without -l reads only the --rcfile, which
            // sources the user's own .bashrc first.
            var argv = argv.filter { $0 != "-l" }
            let rc = folder.appendingPathComponent("search.bashrc").path
            argv += ["--rcfile", rc, "-i"]
            write("search.bashrc", bashrc)
            return (argv, environment)
        default:
            return (argv, environment)
        }
    }

    /// Where the integration's own files live: the app's folder, beside
    /// the session and the rest — the test world's when the app is a test
    /// run, as everything it keeps (see Store).
    private static var folder: URL {
        let folder = Store.file("Terminal")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func write(_ name: String, _ text: String) {
        let file = folder.appendingPathComponent(name)
        try? text.data(using: .utf8)?.write(to: file, options: .atomic)
    }

    /// zsh reads .zshenv before everything, always, and the user's own may
    /// point ZDOTDIR somewhere on purpose — so ours is said again after it.
    /// The path is quoted: "Application Support" has a space, and a bare
    /// word there is a glob a shell with no match for chokes on.
    private static var zshEnv: String {
        """
        # Search's terminal integration — ours, not yours. ZDOTDIR pointed
        # here is what made the shell read it; yours is sourced untouched.
        [[ -e "$HOME/.zshenv" ]] && source "$HOME/.zshenv"
        ZDOTDIR='\(folder.path)'
        """
    }

    /// What a login shell and a login shell alone reads, before .zshrc
    /// (.zprofile) and after it (.zlogin) — the user's own, if there is one.
    private static func source(_ name: String) -> String {
        """
        # Search's terminal integration — ours, not yours. Sourcing
        # yours, untouched, if there is one.
        [[ -e "$HOME/\(name)" ]] && source "$HOME/\(name)"
        """
    }

    private static var zshrc: String {
        """
        # Search's terminal integration — ours, not yours. This file is
        # here because ZDOTDIR said so; yours is sourced first, untouched.
        [[ -e "$HOME/.zshrc" ]] && source "$HOME/.zshrc"

        # With ZDOTDIR pointed here, zsh would keep history beside this
        # file. It keeps it where it always has, unless yours said better.
        [[ -n "$HISTFILE" ]] || HISTFILE="$HOME/.zsh_history"

        __search_precmd() {
          local rc=$?
          printf '\\e]133;D;%s\\e\\\\' "$rc"
          printf '\\e]133;A\\e\\\\'
          printf '\\e]7;file://%s%s\\e\\\\' "$HOST" "$PWD"
        }
        __search_preexec() {
          printf '\\e]133;C\\e\\\\'
        }
        precmd_functions+=(__search_precmd)
        preexec_functions+=(__search_preexec)
        """
    }

    private static var bashrc: String {
        """
        # Search's terminal integration — ours, not yours. This file is
        # here because --rcfile said so; yours is sourced first, untouched.
        [[ -f "$HOME/.bashrc" ]] && source "$HOME/.bashrc"

        # bash has no preexec of its own to mark the running command; a
        # block that never hears C simply runs from its prompt to its end.
        __search_prompt_command() {
          local rc=$?
          printf '\\e]133;D;%s\\e\\\\' "$rc"
          printf '\\e]133;A\\e\\\\'
          printf '\\e]7;file://%s%s\\e\\\\' "$HOSTNAME" "$PWD"
        }
        case ";${PROMPT_COMMAND};" in
          *";__search_prompt_command;"*) ;;
          *) PROMPT_COMMAND="__search_prompt_command${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
        esac
        """
    }
}
