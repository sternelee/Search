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
        // The body is Metalterm's zsh integration, ported whole — the parts
        // of it that make the dock work: the reporting, the ordering of the
        // marks around the user's own hooks, the keep-if-ours key bindings,
        // and the machinery that survives a framework re-sourcing its
        // config. It is measured code (oh-my-zsh, powerlevel10k,
        // zsh-syntax-highlighting, `err_return`, `source ~/.zshrc` in a live
        // shell) and this is not the place to improve it. A raw string, so
        // the shell's own backslashes come through as they are.
        #"""
        # Search's terminal integration — ours, not yours. This file is
        # here because ZDOTDIR said so; yours is sourced first, untouched.
        [[ -e "$HOME/.zshrc" ]] && source "$HOME/.zshrc"

        # With ZDOTDIR pointed here, zsh would keep history beside this
        # file. It keeps it where it always has, unless yours said better.
        [[ -n "$HISTFILE" ]] || HISTFILE="$HOME/.zsh_history"

        # Aliases are turned off for the length of this block, and put back
        # at the end: zsh expands an alias when it parses the name, so with
        # `alias ls=eza` — which oh-my-zsh and most hand-written configs set —
        # a function definition below is a syntax error, and a syntax error
        # takes the rest of the block with it: no marks, no dock. Measured
        # against a real config, where it cost every function after line 74.
        if [[ -o aliases ]]; then
          _search_restore_aliases=1
        else
          _search_restore_aliases=0
        fi
        setopt no_aliases
        if [[ -z ${_search_input_dock_mode+x} ]]; then
          typeset -gr _search_input_dock_mode=${SEARCH_INPUT_DOCK:-1}
        fi
        unset SEARCH_INPUT_DOCK
        if [[ -z ${SEARCH_SHELL_INTEGRATION_ACTIVE-} ]]; then
          typeset -g SEARCH_SHELL_INTEGRATION_ACTIVE=1
          typeset -g _search_command_running=0
          typeset -gr _search_prompt_end=$'%{\e]133;B\a%}'

          # What was last reported, so a redraw that changed nothing writes
          # nothing. zsh redraws for reasons that are not typing — syntax
          # highlighting, an autosuggestion, a keymap change — and each one
          # would otherwise repeat the whole buffer down the pty.
          typeset -gi _search_reported_cursor=-1
          typeset -g _search_reported_buffer=
          typeset -g _search_reported_suggestion=
          typeset -gi _search_reported_plain=0
          # Beyond this size the real terminal grid keeps ownership.
          # Publishing a truncated prefix would make the visible command
          # disagree with what Enter submits.
          typeset -gri _search_buffer_max=1024
          typeset -gri _search_suggestion_max=512
          typeset -gi _search_owns_suggestion=0
          typeset -g _search_suggested_for=
          typeset -g _search_suggested_suffix=
          typeset -gri _search_history_max=256
          typeset -ga _search_history_recent=()

          # zsh's `PROMPT_SP` repair paints `PROMPT_EOL_MARK` (a literal `%`
          # by default) when a startup file writes without a trailing
          # newline. That transient glyph can reach the terminal's scrollback
          # before zsh erases its prompt row; the dock would hold a prompt
          # with a stray `%` above it. Keep only startup prompts marker-free;
          # line-init restores the user's exact value before editing begins.
          typeset -gi _search_restore_prompt_eol_mark=0
          typeset -gi _search_prompt_eol_mark_was_set=0
          typeset -g _search_saved_prompt_eol_mark=
          if (( _search_input_dock_mode )); then
            if [[ ${(t)PROMPT_EOL_MARK} != *readonly* ]]; then
              [[ -n ${PROMPT_EOL_MARK+x} ]] && _search_prompt_eol_mark_was_set=1
              _search_saved_prompt_eol_mark=${PROMPT_EOL_MARK-}
              PROMPT_EOL_MARK=
              _search_restore_prompt_eol_mark=1
            elif [[ -o prompt_sp ]]; then
              # A readonly custom marker cannot be replaced, and disabling
              # PROMPT_SP lets zsh's prompt carriage-return overwrite the
              # partial user output. Complete that one startup line instead.
              printf '\n'
            fi
          fi

          _search_restore_startup_prompt_spacer() {
            if (( _search_restore_prompt_eol_mark )); then
              _search_restore_prompt_eol_mark=0
              if (( _search_prompt_eol_mark_was_set )); then
                PROMPT_EOL_MARK=$_search_saved_prompt_eol_mark
              else
                unset PROMPT_EOL_MARK
              fi
            fi
            return 0
          }

          # Binds `key` to `widget`, but only while the key still sits on
          # one of zsh's own stock widgets for it — the listed names, or
          # nothing at all. The terminal fills gaps; it does not take keys
          # away. A framework's binding is not stock: oh-my-zsh putting
          # `up-line-or-beginning-search` on Up is the user's choice,
          # arriving through their config, and it stays.
          _search_bindkey_if_stock() {
            [[ ${SEARCH_KEYBINDINGS:-1} == 0 ]] && return 1
            local key=$1 widget=$2
            shift 2
            # No `--`: zsh's bindkey does not read it as an option
            # terminator. And the strip goes through a plain variable, so
            # `${$(bindkey ...)##* }` returns the whole line unchanged.
            local raw=$(bindkey "$key" 2>/dev/null)
            local current=${raw##* }
            local stock
            for stock in undefined-key "$@"; do
              if [[ $current == $stock ]]; then
                bindkey "$key" "$widget"
                return 0
              fi
            done
            return 1
          }

          # Finish zsh's completion setup on demand: a first-ever `compinit`
          # can spend well over 100 ms scanning fpath, which belongs to the
          # first Tab that asks, not to every new window's prompt.
          _search_setup_completion_now() {
            if (( ! $+functions[compdef] )); then
              autoload -Uz compinit || return
              local dump="$HOME/.zcompdump-search-$ZSH_VERSION"
              if [[ -s $dump ]]; then
                compinit -C -d "$dump" || return
              else
                compinit -i -d "$dump" || return
              fi
            fi
            zmodload -i zsh/complist 2>/dev/null || true
            zstyle ':completion:*' menu select=1
            zstyle ':completion:*' group-name ''
            zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'
            zstyle ':completion:*' use-cache yes
            _search_bindkey_if_stock '^I' menu-complete \
              _search_lazy_complete expand-or-complete complete-word || true
            _search_bindkey_if_stock '^[[Z' reverse-menu-complete \
              _search_lazy_reverse_complete || true
            return 0
          }

          _search_lazy_complete() {
            _search_setup_completion_now || return
            zle menu-complete
          }

          _search_lazy_reverse_complete() {
            _search_setup_completion_now || return
            zle reverse-menu-complete
          }

          _search_setup_completion() {
            [[ ${SEARCH_COMPLETION:-1} == 0 ]] && return 0
            if (( $+functions[compdef] )); then
              return 0
            fi
            zle -N _search_lazy_complete
            zle -N _search_lazy_reverse_complete
            _search_bindkey_if_stock '^I' _search_lazy_complete \
              menu-complete expand-or-complete complete-word || true
            _search_bindkey_if_stock '^[[Z' _search_lazy_reverse_complete \
              reverse-menu-complete || true
            return 0
          }

          _search_remember_history() {
            local command=$1
            [[ -z $command || $command == $_search_history_recent[1] ]] && return 0
            _search_history_recent=("$command" "${_search_history_recent[@]:0:_search_history_max-1}")
          }

          _search_setup_history() {
            zmodload -i zsh/parameter 2>/dev/null
            if [[ -z ${HISTFILE:-} ]]; then
              HISTFILE=${SEARCH_HISTORY_FILE:-"$HOME/.zsh_history"}
              HISTSIZE=2000
              SAVEHIST=2000
              setopt append_history inc_append_history hist_ignore_dups hist_reduce_blanks
            fi
            if (( ${#history} <= 1 )) && [[ -r $HISTFILE ]]; then
              local file=$HISTFILE
              fc -ap
              HISTSIZE=$_search_history_max
              fc -R "$file" 2>/dev/null
            fi
            local -a loaded
            loaded=("${(@f)$(fc -ln -$_search_history_max 2>/dev/null)}")
            local command
            for command in "${loaded[@]}"; do
              _search_remember_history "$command"
            done
          }

          # A history prefix lookup in a bounded newest-first array. `(r)`
          # asks zsh's C implementation for one matching value: no shell
          # loop, no process, no filesystem read, per key. The suffix never
          # goes in POSTDISPLAY — when Enter reveals the hidden row as
          # committed history, an unaccepted suffix painted there would
          # appear to have been executed.
          _search_history_suggest() {
            POSTDISPLAY=
            if [[ -z $BUFFER || $CURSOR -ne ${#BUFFER} || $BUFFER == ' '* || $BUFFER == *$'\n'* ]]; then
              _search_suggested_for=
              _search_suggested_suffix=
              return 0
            fi
            if [[ $BUFFER != $_search_suggested_for ]]; then
              local pattern="${(b)BUFFER}?*"
              local candidate=${_search_history_recent[(r)${~pattern}]}
              _search_suggested_for=$BUFFER
              _search_suggested_suffix=
              if [[ -n $candidate ]]; then
                _search_suggested_suffix=${candidate[${#BUFFER}+1,-1]}
              fi
            fi
          }

          _search_accept_suggestion() {
            if [[ -n $_search_suggested_suffix && $CURSOR -eq ${#BUFFER} ]]; then
              BUFFER+=$_search_suggested_suffix
              CURSOR=${#BUFFER}
              _search_suggested_for=
              _search_suggested_suffix=
            else
              zle .forward-char
            fi
          }

          _search_accept_suggestion_end() {
            if [[ -n $_search_suggested_suffix && $CURSOR -eq ${#BUFFER} ]]; then
              _search_accept_suggestion
            else
              zle .end-of-line
            fi
          }

          _search_accept_suggestion_word() {
            if [[ -z $_search_suggested_suffix || $CURSOR -ne ${#BUFFER} ]]; then
              zle .forward-word
              return
            fi
            setopt localoptions extendedglob
            local take=$_search_suggested_suffix
            if [[ $_search_suggested_suffix == (#b)([[:space:]]#)([^[:space:]]##)(*) ]]; then
              take=$match[1]$match[2]
            fi
            BUFFER+=$take
            CURSOR=${#BUFFER}
            _search_suggested_suffix=${_search_suggested_suffix#$take}
            _search_suggested_for=
          }

          # Escapes one OSC parameter into REPLY without a command
          # substitution on the per-key reporting path.
          _search_escape_report() {
            local text=$1
            text=${text//\\/\\\\}
            text=${text//$'\n'/\\n}
            text=${text//$'\r'/\\r}
            text=${text//$'\t'/\\t}
            text=${text//$'\e'/\\e}
            text=${text//$'\a'/\\a}
            text=${text//[[:cntrl:]]/}
            REPLY=${text//;/\\x3b}
          }

          _search_report_buffer() {
            _search_report_edit_line "$BUFFER" "$CURSOR" live
          }

          # The report itself, off a buffer and a cursor that are not
          # always the ones zle is holding: the paste caller reports a line
          # that has not been inserted yet. `live` in `$3` is what says the
          # suffix sources may be read; the paste caller must not pass it,
          # or the dock would ghost the old suggestion against the new line.
          # `$1` is tested before it is copied: this is the per-keystroke
          # path, and a buffer past the cap is discarded.
          _search_report_edit_line() {
            if (( ${#1} > _search_buffer_max )) || [[ $1 == *$'\n'* ]]; then
              if (( ! _search_reported_plain )); then
                printf '\e]7784;off\a'
              fi
              _search_reported_plain=1
              _search_reported_cursor=-1
              _search_reported_buffer=
              _search_reported_suggestion=
              return 0
            fi
            local buffer=$1
            # An assignment, not `(( cursor = ... ))`: that form returns
            # non-zero for a cursor of 0 — the caret at the start of the
            # line — and a shell run with `err_return` would take it for a
            # failed report.
            integer cursor=$(( $2 < _search_buffer_max ? $2 : _search_buffer_max ))
            if (( _search_reported_plain )); then
              _search_reported_plain=0
              _search_reported_cursor=-1
            fi
            local text=${buffer[1,$_search_buffer_max]}
            local suggestion=
            if [[ ${3-} == live && -n $buffer ]] && (( cursor == ${#buffer} )); then
              if (( _search_owns_suggestion )); then
                suggestion=${_search_suggested_suffix[1,$_search_suggestion_max]}
              else
                suggestion=${POSTDISPLAY[1,$_search_suggestion_max]}
              fi
            fi
            if (( cursor == _search_reported_cursor )) \
              && [[ $text == _search_reported_buffer \
                && $suggestion == _search_reported_suggestion ]]; then
              return 0
            fi
            _search_reported_cursor=$cursor
            _search_reported_buffer=$text
            _search_reported_suggestion=$suggestion
            _search_escape_report "$text"
            text=$REPLY
            _search_escape_report "$suggestion"
            suggestion=$REPLY
            printf '\e]7784;buf;%d;%s;%s\a' "$cursor" "$text" "$suggestion"
          }

          # A paste the dock would otherwise not see until the next
          # keystroke. oh-my-zsh binds `bracketed-paste-magic`, and that
          # widget ends in a blocking read; until that key arrives, no
          # report is written, and a paste looks like it took two presses.
          # `paste-finish` is the last hook that runs before the block, and
          # `$PASTED` is what it is about to insert.
          _search_report_paste() {
            (( ${NUMERIC:-1} != 1 )) && return 0
            local REPLY
            _search_report_edit_line "${LBUFFER}${PASTED}${RBUFFER}" \
              $(( ${#LBUFFER} + ${#PASTED} ))
            return 0
          }

          # A zstyle rather than a widget, so this composes with whatever
          # the user has on `paste-finish` instead of replacing it.
          _search_install_paste_finish() {
            local -a hooks
            zstyle -a :bracketed-paste-magic paste-finish hooks || hooks=()
            (( ${hooks[(I)_search_report_paste]} )) && return 0
            zstyle :bracketed-paste-magic paste-finish "${hooks[@]}" _search_report_paste
          }

          # `accept-line` leaves the buffer behind; nothing else would say
          # it is gone until the next prompt, and the dock would hold the
          # command that is already running.
          _search_report_done() {
            _search_reported_plain=0
            _search_reported_cursor=-1
            _search_reported_buffer=
            _search_reported_suggestion=
            _search_suggested_for=
            _search_suggested_suffix=
            printf '\e]7784;buf;0;;\a'
          }

          # A new prompt must report even when nothing changed: the
          # terminal drops the reported line on every OSC 133 `A` — the
          # shell drawing this prompt may not be the one that drew the
          # last, and `exec bash` keeps the marker while losing the
          # reports — so a shell that reports re-establishes it
          # immediately. "Empty again" equals "empty", which is every
          # Ctrl+C at an empty prompt: without this, the dock has nothing
          # to draw until a keystroke changes the buffer.
          _search_report_line_init() {
            _search_restore_startup_prompt_spacer
            _search_reported_cursor=-1
            _search_reported_buffer=
            _search_reported_suggestion=
            _search_report_buffer
          }

          _search_setup_line_editor() {
            (( _search_input_dock_mode )) || return 0
            (( ${_search_line_editor_ready:-0} )) && return 0
            # User options are global by default in zsh. `ERR_RETURN` makes
            # harmless probes abort the whole installer; keep their status
            # local without changing the user's option after this.
            setopt localoptions no_err_return
            typeset -gi _search_line_editor_ready=1
            _search_setup_completion

            if [[ ${SEARCH_HISTORY_SUGGESTIONS:-1} == 0 ]] \
              || (( $+functions[_zsh_autosuggest_fetch] || $+functions[_zsh_autosuggest_start] )); then
              _search_owns_suggestion=0
            else
              _search_owns_suggestion=1
              _search_setup_history
              zle -N _search_accept_suggestion
              zle -N _search_accept_suggestion_end
              zle -N _search_accept_suggestion_word
              # Both encodings of every arrow. A terminal in application
              # cursor mode sends `^[OC` for Right where normal mode sends
              # `^[[C`, and zle switches the terminal into application mode
              # for the length of each line. Binding only one form is why
              # Right stopped accepting a suggestion under a real config.
              _search_bindkey_if_stock '^[[C' _search_accept_suggestion forward-char || true
              _search_bindkey_if_stock '^[OC' _search_accept_suggestion forward-char || true
              _search_bindkey_if_stock '^[[F' _search_accept_suggestion_end end-of-line || true
              _search_bindkey_if_stock '^[OF' _search_accept_suggestion_end end-of-line || true
              _search_bindkey_if_stock '^E' _search_accept_suggestion_end end-of-line || true
              _search_bindkey_if_stock '^[[1;3C' _search_accept_suggestion_word forward-word || true
              _search_bindkey_if_stock '^[[A' history-beginning-search-backward up-line-or-history || true
              _search_bindkey_if_stock '^[OA' history-beginning-search-backward up-line-or-history || true
              _search_bindkey_if_stock '^[[B' history-beginning-search-forward down-line-or-history || true
              _search_bindkey_if_stock '^[OB' history-beginning-search-forward down-line-or-history || true
            fi

            _search_install_zle_hooks
          }

          # Private cursor steps used only by click-to-move. They bypass
          # ordinary arrow bindings, so Right cannot accept an autosuggestion
          # and a plugin cannot turn a click into history navigation.
          _search_click_left() {
            (( CURSOR > 0 )) && (( CURSOR-- ))
            return 0
          }
          _search_click_right() {
            (( CURSOR < ${#BUFFER} )) && (( CURSOR++ ))
            return 0
          }

          # One compact terminal-to-ZLE edit for a selection in the dock.
          # A bounded read consumes `<first>;<end>~`, validates it against
          # the live BUFFER, then changes BUFFER and CURSOR once.
          _search_delete_selection() {
            setopt localoptions no_err_return
            local payload= ch= first_text last_text prefix suffix
            integer i valid=1
            for (( i = 0; i < 10; i++ )); do
              (( PENDING > 0 || KEYS_QUEUED_COUNT > 0 )) || return 0
              read -r -k 1 ch || return 0
              [[ $ch == '~' ]] && break
              if [[ $ch == [0-9] || $ch == ';' ]]; then
                payload+=$ch
              else
                valid=0
              fi
            done
            (( valid )) && [[ $ch == '~' ]] || return 0
            first_text=${payload%%;*}
            last_text=${payload#*;}
            [[ $first_text != $payload && -n $first_text && -n $last_text \
              && $last_text != *';'* ]] || return 0
            [[ $first_text == <-> && $last_text == <-> ]] || return 0
            integer first=$(( 10#$first_text ))
            integer last=$(( 10#$last_text ))
            (( first >= 0 && first < last && last <= ${#BUFFER} )) || return 0
            prefix=${BUFFER[1,$first]}
            suffix=${BUFFER[$(( last + 1 )),-1]}
            BUFFER=$prefix$suffix
            CURSOR=$first
            return 0
          }

          # Mouse motion stays in the renderer; its release sends one
          # absolute boundary. Match the reported buffer length before
          # moving, so a queued insertion cannot reinterpret the boundary
          # in a differently sized command.
          _search_dock_cursor() {
            setopt localoptions no_err_return
            local payload= ch= length_text target_text
            integer i valid=1
            for (( i = 0; i < 10; i++ )); do
              (( PENDING > 0 || KEYS_QUEUED_COUNT > 0 )) || return 0
              read -r -k 1 ch || return 0
              [[ $ch == '~' ]] && break
              if [[ $ch == [0-9] || $ch == ';' ]]; then
                payload+=$ch
              else
                valid=0
              fi
            done
            (( valid )) && [[ $ch == '~' ]] || return 0
            length_text=${payload%%;*}
            target_text=${payload#*;}
            [[ $length_text != $payload && -n $length_text && -n $target_text \
              && $target_text != *';'* ]] || return 0
            [[ $length_text == <-> && $target_text == <-> ]] || return 0
            integer length=$(( 10#$length_text ))
            integer target=$(( 10#$target_text ))
            (( length == ${#BUFFER} && length <= _search_buffer_max \
              && target >= 0 && target <= length )) || return 0
            [[ $BUFFER != *$'\n'* ]] || return 0
            CURSOR=$target
            return 0
          }

          _search_setup_click_move() {
            (( ${_search_click_move_ready:-0} )) && return 0
            setopt localoptions no_err_return
            typeset -gi _search_click_move_ready=1
            zle -N _search_click_left
            zle -N _search_click_right
            local map
            # `main` may name a user-created map rather than one of the
            # three standard roots; binding an alias and its target twice
            # is harmless.
            for map in emacs viins vicmd main; do
              bindkey -M "$map" '^[[27;9;68~' _search_click_left
              bindkey -M "$map" '^[[27;9;67~' _search_click_right
            done
            if (( _search_input_dock_mode )); then
              zle -N _search_delete_selection
              zle -N _search_dock_cursor
              for map in emacs viins vicmd main; do
                bindkey -M "$map" '^[[27;9;88~' _search_delete_selection
                bindkey -M "$map" '^[[27;9;71~' _search_dock_cursor
              done
            fi
            return 0
          }

          # The three widgets the dock rides on, as one string. The hook
          # lists count too: a plugin wrapping the dispatcher and another
          # re-adding it before the next prompt restores every name.
          _search_zle_signature() {
            local init finish redraw
            zstyle -s zle-line-init widgets init ' ' || init=
            zstyle -s zle-line-finish widgets finish ' ' || finish=
            zstyle -s zle-line-pre-redraw widgets redraw ' ' || redraw=
            REPLY="${widgets[zle-line-init]-}|${widgets[zle-line-finish]-}|${widgets[zle-line-pre-redraw]-}|$init|$finish|$redraw"
          }

          # Move one of our direct fallback wrappers out of the way before
          # handing the widget back to zsh's hook dispatcher. A helper loaded
          # later preserves the widget it finds as a hook of its own.
          _search_leave_zle_fallback() {
            local hook=$1 wrapper=$2 previous=$3
            if [[ ${widgets[zle-$hook]-} == user:$wrapper ]]; then
              if [[ -n $previous ]] && (( $+functions[$previous] )); then
                zle -N "zle-$hook" "$previous"
              elif [[ -n $previous ]] && (( $+widgets[$previous] )); then
                zle -A "$previous" "zle-$hook"
              else
                zle -D "zle-$hook" 2>/dev/null
              fi
            elif [[ ${widgets[zle-$hook]-} == user:azhw:zle-$hook \
              && -n $previous && $previous != azhw:zle-$hook ]] \
              && (( $+functions[$previous] || $+widgets[$previous] )); then
              if (( $+functions[$previous] )); then
                zle -N -- "user:$previous" "$previous"
              else
                zle -A -- "$previous" "user:$previous"
              fi
              add-zle-hook-widget "$hook" "user:$previous"
            fi
            add-zle-hook-widget -d "$hook" "$wrapper" 2>/dev/null
            add-zle-hook-widget -d "$hook" "user:$wrapper" 2>/dev/null
          }

          _search_zle_noop() { return 0 }

          # A plugin that wrapped a hook (fast-syntax-highlighting, legacy
          # z-sy-h) calls what it wrapped through an alias. Re-queued inside
          # that same dispatcher, the alias closes a cycle.
          _search_cut_zle_cycles() {
            setopt localoptions no_ksh_arrays
            local hook previous widget value list
            local -A replacement
            integer foreign=0
            for hook in line-init line-finish line-pre-redraw; do
              value=${widgets[zle-$hook]-}
              [[ $value == user:* && $value != user:azhw:zle-$hook \
                && $value != user:_search_zle_* ]] && foreign=1
              zstyle -s "zle-$hook" widgets list '|' || list=
              [[ $list == *:user:* ]] && foreign=1
            done
            (( foreign )) || return 0
            for hook in line-init line-finish line-pre-redraw; do
              case $hook in
                line-init) previous=${_search_prev_line_init-} ;;
                line-finish) previous=${_search_prev_line_finish-} ;;
                *) previous=${_search_prev_redraw-} ;;
              esac
              replacement[user:azhw:zle-$hook]=_search_zle_noop
              replacement[user:_search_zle_${hook//-/_}]=_search_zle_noop
              if [[ ${widgets[zle-$hook]-} != user:azhw:zle-$hook && -n $previous ]] \
                && (( $+functions[$previous] )); then
                replacement[user:_search_zle_${hook//-/_}]=$previous
              fi
            done
            for widget in ${(k)widgets[@]}; do
              value=${widgets[$widget]-}
              [[ -n ${replacement[$value]-} ]] || continue
              case $widget in
                zle-line-init|zle-line-finish|zle-line-pre-redraw) ;;
                *) zle -N -- "$widget" "${replacement[$value]}" ;;
              esac
            done
            return 0
          }

          # Idempotent, because it runs again whenever something has taken
          # a widget away. `source ~/.zshrc` in a live shell is common and
          # does real damage: oh-my-zsh and prezto both remove
          # `zle-line-init` and `zle-line-finish` when their setup runs a
          # second time. One lost hook and the dock falls back into the
          # grid for the rest of the session, on every command.
          _search_install_zle_hooks() {
            setopt localoptions no_err_return
            zmodload -i zsh/parameter 2>/dev/null
            _search_cut_zle_cycles
            # `autoload +X` reports whether this invocation loaded the
            # function, not whether it is callable; inspect the
            # postcondition instead.
            autoload -Uz +X add-zle-hook-widget 2>/dev/null
            if (( $+functions[add-zle-hook-widget] )) \
              && [[ ${functions[add-zle-hook-widget]} != 'builtin autoload -X'* ]]; then
              _search_leave_zle_fallback \
                line-init _search_zle_line_init "${_search_prev_line_init-}"
              _search_leave_zle_fallback \
                line-finish _search_zle_line_finish "${_search_prev_line_finish-}"
              _search_leave_zle_fallback \
                line-pre-redraw _search_zle_line_pre_redraw "${_search_prev_redraw-}"
              # Delete before adding: re-installing a hook still registered
              # would leave two copies of it, reported twice per keystroke.
              if (( _search_owns_suggestion )); then
                add-zle-hook-widget -d line-pre-redraw _search_history_suggest 2>/dev/null
                add-zle-hook-widget line-pre-redraw _search_history_suggest
              fi
              add-zle-hook-widget -d line-pre-redraw _search_report_buffer 2>/dev/null
              add-zle-hook-widget line-pre-redraw _search_report_buffer
              add-zle-hook-widget -d line-init _search_report_line_init 2>/dev/null
              add-zle-hook-widget line-init _search_report_line_init
              add-zle-hook-widget -d line-finish _search_report_done 2>/dev/null
              add-zle-hook-widget line-finish _search_report_done
            else
              if [[ ${widgets[zle-line-init]-} == user:* \
                && ${widgets[zle-line-init]-} != user:_search_zle_line_init ]]; then
                typeset -g _search_prev_line_init=${widgets[zle-line-init]#user:}
              fi
              if [[ ${widgets[zle-line-finish]-} == user:* \
                && ${widgets[zle-line-finish]-} != user:_search_zle_line_finish ]]; then
                typeset -g _search_prev_line_finish=${widgets[zle-line-finish]#user:}
              fi
              if [[ ${widgets[zle-line-pre-redraw]-} == user:* \
                && ${widgets[zle-line-pre-redraw]-} != user:_search_zle_line_pre_redraw ]]; then
                typeset -g _search_prev_redraw=${widgets[zle-line-pre-redraw]#user:}
              fi
              _search_zle_line_init() {
                setopt localoptions no_err_return
                [[ -n ${_search_prev_line_init-} ]] && "$_search_prev_line_init" "$@"
                _search_report_line_init
                return 0
              }
              _search_zle_line_finish() {
                setopt localoptions no_err_return
                [[ -n ${_search_prev_line_finish-} ]] && "$_search_prev_line_finish" "$@"
                _search_report_done
                return 0
              }
              _search_zle_line_pre_redraw() {
                setopt localoptions no_err_return
                (( _search_owns_suggestion )) && _search_history_suggest
                [[ -n ${_search_prev_redraw-} ]] && "$_search_prev_redraw" "$@"
                _search_report_buffer
                return 0
              }
              zle -N zle-line-init _search_zle_line_init
              zle -N zle-line-finish _search_zle_line_finish
              zle -N zle-line-pre-redraw _search_zle_line_pre_redraw
            fi
            _search_zle_signature
            typeset -g _search_zle_installed=$REPLY
            return 0
          }

          # Runs after every other precmd, so it has the last word on what
          # the prompt is. The terminal draws the prompt, so the shell must
          # not: a theme that rebuilds `PROMPT` on every prompt — starship
          # does — is overwritten here rather than argued with.
          # `_search_prompt` is what this file settled on below, so the
          # assignment happens only when something replaced it.
          _search_precmd_prompt_end() {
            # `A` belongs immediately before the prompt, after every user
            # precmd has finished, so it names the row zsh is about to
            # draw the prompt on.
            printf '\e]133;A;cl=line;mt=click-v1\a'
            # Only when something actually replaced it: assigning `PROMPT`
            # on every prompt even when identical is not free — it made a
            # live resize leave three copies of the output where one
            # belonged.
            if (( _search_input_dock_mode )) \
              && [[ -n ${_search_prompt+x} && $PROMPT != ${_search_prompt}* ]]; then
              PROMPT=$_search_prompt
              RPROMPT=$_search_rprompt
            fi
            if [[ $PROMPT == *${_search_prompt_end} ]]; then
              PROMPT=${PROMPT%${_search_prompt_end}}
            fi
            PROMPT+=$_search_prompt_end
          }

          _search_preexec() {
            _search_remember_history "$1"
            printf '\e]133;C\a'
            _search_command_running=1
          }

          # Status first, `A` last. A hook appended later (`source
          # ~/.zshrc` re-adding pure's) otherwise prints under `A`, and the
          # dock hides that row as prompt.
          _search_order_precmd() {
            setopt localoptions no_ksh_arrays
            [[ ${precmd_functions[1]-} == _search_precmd_start \
              && ${precmd_functions[-1]-} == _search_precmd_prompt_end ]] && return 0
            precmd_functions=(
              _search_precmd_start
              ${${precmd_functions:#_search_precmd_start}:#_search_precmd_prompt_end}
              _search_precmd_prompt_end
            )
          }

          _search_precmd_start() {
            local command_status=$?
            # Fallback for a user-owned `precmd`: zsh has already
            # snapshotted the hooks, so this repairs the next prompt.
            _search_order_precmd
            # `precmd` survives what takes the zle hooks away, so this is
            # where they get put back. It runs before `line-init` does, so
            # the dock returns on the very next prompt.
            if (( ${_search_line_editor_ready:-0} )); then
              _search_zle_signature
              [[ $REPLY == "${_search_zle_installed-}" ]] || _search_install_zle_hooks
              _search_install_paste_finish
            fi
            if (( _search_command_running )); then
              printf '\e]133;D;%d\a' "$command_status"
              _search_command_running=0
            fi
            # OSC 7 keeps the terminal's idea of the working directory
            # current, the same promise the old integration made.
            printf '\e]7;file://%s%s\e\\\\' "${HOST:-localhost}" "$PWD"
          }

          _search_order_precmd
          # zsh calls a `precmd` function before it snapshots
          # `precmd_functions`, so only here can a hook added by the last
          # command be reordered for this very prompt.
          (( $+functions[precmd] )) || precmd() { _search_order_precmd }
          preexec_functions=(
            _search_preexec
            ${preexec_functions:#_search_preexec}
          )
        fi

        # The user's own aliases work again from here; only this block was
        # parsed without them.
        (( _search_restore_aliases )) && setopt aliases
        unset _search_restore_aliases

        # The wrapper's tail: the line editor, the prompt the dock draws,
        # click-to-move, and the snapshot of both for the restore above.
        if (( _search_input_dock_mode )); then
          _search_setup_line_editor
          PROMPT='❯ '
          RPROMPT=''
        fi
        _search_setup_click_move
        typeset -g _search_prompt=$PROMPT
        typeset -g _search_rprompt=$RPROMPT
        """#
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
