#!/bin/bash
# ==========================================================
# NGINX Manager Pro - user interface: terminal detection, styling, prompts
# Sourced by nginx-site.sh: defines state and functions only.
#
# Every screen is drawn and every question asked through these helpers.
# Prompts use Gum (github.com/charmbracelet/gum, 0.15 or newer) when it is
# installed and stdin, stdout and stderr are terminals. Otherwise they read
# lines from stdin, which also lets input be piped in. Nothing here changes any
# configuration.
#
# Prompt helpers put the answer in UI_REPLY and return:
#   0  answered
#   1  no input: end of input, or non-interactive mode
#   2  cancelled (Esc or Ctrl-C)
# ==========================================================

UI_REPLY=""
# Set by ui_init. The defaults (no Gum, UTF-8 symbols) are what a caller
# that never runs ui_init gets.
UI_MODE=auto            # auto | gum | plain   (NM_UI, --plain)
UI_GUM=0                # 1: prompts use gum
UI_GUM_VERSION=""
UI_GUM_NOTE=""          # why gum is not used
UI_GUM_MIN="0.15"
UI_NONINTERACTIVE=0     # NM_NONINTERACTIVE=1, --non-interactive
UI_INTERRUPTED=0
UI_INT_TRAP=""
UI_TTY_STATE=""          # terminal settings while a secret is typed
UI_NOTE_SHOWN=0
UI_COLS=80
UI_WIDTH=60
UI_PICK_LABELS=()
SYM_OK="✓" SYM_ERR="✗" SYM_WARN="!" SYM_STEP="→" SYM_ON="●" SYM_OFF="○"
SYM_NONE="—" SYM_UNKNOWN="?" SYM_SEP="›" SYM_ARROW="→" UI_RULE_CHAR="─"

# ==========================================================
# DETECTION
# ==========================================================
ui_init() {
    UI_MODE="${NM_UI:-${UI_MODE:-auto}}"
    case "$UI_MODE" in
        auto|gum|plain) ;;
        *) UI_MODE=auto ;;
    esac
    [[ "${NM_NONINTERACTIVE:-}" == 1 ]] && UI_NONINTERACTIVE=1

    # Colour only on a real terminal, and never when NO_COLOR is set.
    if [[ -n "${NO_COLOR:-}" || ! -t 1 || ! -t 2 || "${TERM:-dumb}" == dumb ]]; then
        BLUE="" GREEN="" RED="" YELLOW="" CYAN="" GRAY="" NC="" BOLD=""
    fi
    case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
        *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) ;;
        *)
            SYM_OK="+" SYM_ERR="x" SYM_WARN="!" SYM_STEP=">" SYM_ON="*" SYM_OFF="-"
            SYM_NONE="-" SYM_UNKNOWN="?" SYM_SEP=">" SYM_ARROW="->" UI_RULE_CHAR="-"
            ;;
    esac
    ui_detect_gum
}

# Decides whether prompts use gum; UI_GUM_NOTE says why not.
# NM_UI=gum skips only the terminal check (gum then fails without one, and
# the basic interface takes over).
ui_detect_gum() {
    UI_GUM=0 UI_GUM_VERSION="" UI_GUM_NOTE=""
    if [[ "$UI_MODE" == plain ]]; then
        UI_GUM_NOTE="basic interface selected (--plain or NM_UI=plain)"
        return
    fi
    if ((UI_NONINTERACTIVE)); then
        UI_GUM_NOTE="non-interactive mode"
        return
    fi
    if ! command -v gum >/dev/null 2>&1; then
        UI_GUM_NOTE="gum is not installed"
        return
    fi
    # Real gum prints "gum version v0.16.2 (abc1234)". A failing or hanging
    # probe counts as an unknown version.
    local version probe=(gum --version)
    command -v timeout >/dev/null 2>&1 && probe=(timeout 5 gum --version)
    version=$("${probe[@]}" 2>/dev/null </dev/null) || version=""
    version="${version%%$'\n'*}"
    if [[ "$version" =~ ([0-9]+)\.([0-9]+)(\.[0-9]+)? ]]; then
        UI_GUM_VERSION="${BASH_REMATCH[0]}"
        if ((BASH_REMATCH[1] == 0 && BASH_REMATCH[2] < ${UI_GUM_MIN#0.})); then
            UI_GUM_NOTE="gum $UI_GUM_VERSION is too old ($UI_GUM_MIN or newer needed)"
            return
        fi
    else
        UI_GUM_NOTE="gum version could not be determined ($UI_GUM_MIN or newer needed)"
        return
    fi
    # gum draws on stderr and returns the answer on stdout: all three must be
    # the terminal, or its screens would land in a redirected file.
    if [[ "$UI_MODE" != gum ]] && [[ ! -t 0 || ! -t 1 || ! -t 2 || "${TERM:-dumb}" == dumb ]]; then
        UI_GUM_NOTE="not running in a terminal"
        return
    fi
    UI_GUM=1
}

# A gum run that failed for any reason other than the user cancelling
# switches the rest of the session to the basic interface. gum itself exits
# 1 both for Esc and for most runtime errors, so only other statuses (e.g. 80
# for an unsupported flag) are recognised as failures; an error with status 1
# is treated as cancelling, which never changes anything.
ui_gum_failed() {
    UI_GUM=0
    UI_GUM_NOTE="gum failed (exit $1)"
    msg_warning "gum failed (exit $1); continuing with the basic interface"
}

# Runs gum; its output goes to UI_REPLY. Returns 0, 2 when the user
# cancelled (Esc: 1, Ctrl-C: 130), or 3 when gum itself failed.
ui_gum() {
    local out rc
    out=$(gum "$@")
    rc=$?
    case "$rc" in
        0) UI_REPLY="$out"; return 0 ;;
        1|130) return 2 ;;
        *) ui_gum_failed "$rc"; return 3 ;;
    esac
}

# Ctrl-C at a prompt cancels the prompt instead of killing the manager.
ui_trap_interrupts() {
    UI_INT_TRAP='UI_INTERRUPTED=1'
    trap "$UI_INT_TRAP" INT
}

# ui_shield <command> [args...]
# Runs a command with Ctrl-C ignored, also by the commands it starts, so an
# interruption can neither stop it half-way nor make a status check (nginx
# -t, systemctl) look failed. Returns the command's status.
ui_shield() {
    trap '' INT
    "$@"
    local rc=$?
    if [[ -n "$UI_INT_TRAP" ]]; then trap "$UI_INT_TRAP" INT; else trap - INT; fi
    return $rc
}

# ui_run <command> [args...]
# Runs an operation that changes the system under ui_shield and marks the
# cached dashboard status as stale. Returns the command's status.
ui_run() {
    ui_shield "$@"
    local rc=$?
    DASH_TIME=0
    return $rc
}

# gum takes list flags (--selected) as comma-separated values: a literal
# comma in an option must be escaped.
ui_gum_escape_list() { printf '%s' "${1//,/\\,}"; }

ui_update_width() {
    local cols="${COLUMNS:-}"
    [[ -z "$cols" && -t 1 ]] && cols=$(tput cols 2>/dev/null)
    [[ "$cols" =~ ^[0-9]+$ ]] && ((cols >= 20)) || cols=80
    UI_COLS=$cols
    UI_WIDTH=$((cols < 62 ? cols - 2 : 60))
}

# ==========================================================
# OUTPUT
# ==========================================================
msg_success() { printf '%s\n' "${GREEN}${SYM_OK} $1${NC}"; }
msg_warning() { printf '%s\n' "${YELLOW}${SYM_WARN} $1${NC}"; }
msg_error()   { printf '%s\n' "${RED}${SYM_ERR} $1${NC}"; }
msg_step()    { printf '%s\n' "${CYAN}${SYM_STEP} $1${NC}"; }

ui_hint() { printf '%s\n' "  ${GRAY}$1${NC}"; }

ui_rule() {
    local line
    printf -v line '%*s' "$UI_WIDTH" ''
    printf '%s\n' "${GRAY}${line// /$UI_RULE_CHAR}${NC}"
}

# Clears the screen only on a terminal; piped output is never cleared.
ui_clear() {
    [[ -t 1 ]] || return 0
    clear 2>/dev/null || printf '\033[H\033[2J'
}

# ui_screen [<title>...]  -- starts a screen: "NGINX Manager Pro > a > b".
ui_screen() {
    ui_clear
    ui_update_width
    local title="${BLUE}${BOLD}NGINX Manager Pro${NC}" part
    for part in "$@"; do
        title+=" ${GRAY}${SYM_SEP}${NC} ${BOLD}${part}${NC}"
    done
    printf '%s\n' "$title"
    ui_rule
    echo
}

ui_section() { printf '\n%s\n' "${BOLD}$1${NC}"; }

# ui_kv <label> <value>  -- one aligned "label  value" line.
ui_kv() { printf '  %-14s %s\n' "$1" "$2"; }

# ui_badge <state> <text>  -- a status word with its symbol and colour.
# States: ok, warn, err (health); on, off (enabled or not); none (not
# configured); unknown (could not be determined).
ui_badge() {
    case "$1" in
        ok)      printf '%s' "${GREEN}${SYM_OK} $2${NC}" ;;
        warn)    printf '%s' "${YELLOW}${SYM_WARN} $2${NC}" ;;
        err)     printf '%s' "${RED}${SYM_ERR} $2${NC}" ;;
        on)      printf '%s' "${GREEN}${SYM_ON} $2${NC}" ;;
        off)     printf '%s' "${GRAY}${SYM_OFF} $2${NC}" ;;
        none)    printf '%s' "${GRAY}${SYM_NONE} $2${NC}" ;;
        *)       printf '%s' "${YELLOW}${SYM_UNKNOWN} $2${NC}" ;;
    esac
}

# ui_badge_cell <width> <state> <text>  -- a badge padded to a table column.
ui_badge_cell() {
    local plain
    plain=$(NC="" GREEN="" YELLOW="" RED="" GRAY="" ui_badge "$2" "$3")
    pad_colored "$(ui_badge "$2" "$3")" "$plain" "$1"
}

# Prints "$colored" then pads with spaces so the VISIBLE width matches
# $width, based on the visible length of "$plain" (avoids ANSI escape
# codes throwing off column alignment in tables).
pad_colored() {
    local colored="$1" plain="$2" width="$3"
    local pad=$((width - ${#plain}))
    ((pad < 0)) && pad=0
    printf "%s%*s" "$colored" "$pad" ""
}

# Truncates $1 to $2 visible characters, appending "..." when it was cut,
# so a long value shortens instead of dragging the rest of a table row
# out of alignment.
truncate_field() {
    local text="$1" width="$2"
    if ((${#text} > width)); then
        printf "%s..." "${text:0:$((width - 3))}"
    else
        printf "%s" "$text"
    fi
}

# Shows, once per session and only to a person at a terminal, why the
# basic interface is in use and how to get the enhanced one.
ui_gum_note() {
    ((UI_GUM || UI_NOTE_SHOWN || UI_NONINTERACTIVE)) && return 0
    [[ "$UI_MODE" == plain || ! -t 0 || ! -t 1 ]] && return 0
    UI_NOTE_SHOWN=1
    echo
    ui_hint "Basic interface: $UI_GUM_NOTE. Install gum $UI_GUM_MIN+ for arrow-key menus and search (see Help)."
}

ui_cancel_hint() {
    if ((UI_GUM)); then
        ui_hint "Esc cancels without changing anything."
    else
        ui_hint "Ctrl-C cancels without changing anything."
    fi
}

# ==========================================================
# PROMPTS
# ==========================================================
# Reads one line (plain interface). A last line without a newline still
# counts as input. On a terminal bash resumes a plain read after Ctrl-C,
# so the line is read in short slices and the interrupt flag is checked
# between them; text typed so far is kept across slices.
ui_read() { # prompt [secret]
    UI_REPLY=""
    if ((UI_NONINTERACTIVE)); then
        local what
        what=$(printf '%s' "$1" | sed 's/\x1b\[[0-9;]*m//g')
        what="${what%%[:\[]*}"
        echo
        msg_error "Non-interactive mode: '${what% }' needs an answer; stopping"
        return 1
    fi
    printf '%s' "$1"
    UI_INTERRUPTED=0
    local reply="" part rc
    # Echo stays off for the whole secret, not just during each slice. If
    # SIGTERM or SIGHUP arrives meanwhile, the terminal is restored first.
    UI_TTY_STATE=""
    if [[ "$2" == secret && -t 0 ]] && UI_TTY_STATE=$(stty -g 2>/dev/null); then
        trap 'ui_tty_signal TERM' TERM
        trap 'ui_tty_signal HUP' HUP
        stty -echo 2>/dev/null
    fi
    while true; do
        part=""
        read -r -t 0.5 part
        rc=$?
        reply+="$part"
        ((rc > 128 && !UI_INTERRUPTED)) || break
    done
    if [[ -n "$UI_TTY_STATE" ]]; then
        stty "$UI_TTY_STATE" 2>/dev/null
        UI_TTY_STATE=""
        trap - TERM HUP
    fi
    [[ "$2" == secret ]] && echo
    if ((UI_INTERRUPTED)); then
        echo
        return 2
    fi
    ((rc)) && [[ -z "$reply" ]] && return 1
    UI_REPLY="$reply"
}

# SIGTERM/SIGHUP during a secret prompt: restores the terminal settings
# saved by ui_read, then dies from the same signal (default handling), so
# the signal is neither swallowed nor turned into an ordinary exit.
ui_tty_signal() { # signal
    [[ -n "$UI_TTY_STATE" ]] && stty "$UI_TTY_STATE" 2>/dev/null
    trap - "$1"
    kill -s "$1" "$BASHPID"
}

# Explains why a flow stopped at a prompt (status 1 or 2 from a prompt).
ui_aborted() { # status [what-stops]
    echo
    if (($1 == 1)); then
        msg_warning "Input closed - ${2:-cancelled}"
    else
        msg_warning "Cancelled - nothing was changed"
    fi
}

# ui_menu <title> <default-key> <key|label|hint>...
# Offers the items and puts the chosen key in UI_REPLY. The plain
# interface lists "[key] label  hint" and accepts a key in any case; gum
# lists the labels. An empty answer picks <default-key>, if there is one.
ui_menu() {
    local title="$1" default="$2"
    shift 2
    local keys=() labels=() hints=() item key label hint width=0 i
    for item in "$@"; do
        IFS='|' read -r key label hint <<< "$item"
        keys+=("$key") labels+=("$label") hints+=("$hint")
        ((${#label} > width)) && width=${#label}
    done

    if ((UI_GUM)); then
        local options=() selected=() rc
        for i in "${!keys[@]}"; do
            if [[ -n "${hints[i]}" ]]; then
                printf -v item "%-${width}s   %s" "${labels[i]}" "${hints[i]}"
            else
                item="${labels[i]}"
            fi
            options+=("$item")
            [[ "${keys[i]}" == "$default" ]] && selected=("--selected=$(ui_gum_escape_list "$item")")
        done
        ui_gum choose "--header=$title" --height=15 "${selected[@]}" -- "${options[@]}"
        rc=$?
        if ((rc == 0)); then
            for i in "${!options[@]}"; do
                [[ "${options[i]}" == "$UI_REPLY" ]] && { UI_REPLY="${keys[i]}"; return 0; }
            done
            ui_gum_failed "unexpected choice"
        elif ((rc != 3)); then
            return $rc
        fi
    fi

    [[ -n "$title" ]] && printf '%s\n' "${BOLD}$title${NC}"
    for i in "${!keys[@]}"; do
        if [[ -n "${hints[i]}" ]]; then
            printf "  [%s] %-${width}s  %s\n" "${keys[i]^^}" "${labels[i]}" "${GRAY}${hints[i]}${NC}"
        else
            printf "  [%s] %s\n" "${keys[i]^^}" "${labels[i]}"
        fi
    done
    echo
    local answer
    while true; do
        ui_read "Select${default:+ [${default^^}]}: " || return
        answer="${UI_REPLY:-$default}"
        [[ -z "$answer" ]] && continue
        for i in "${!keys[@]}"; do
            [[ "${keys[i],,}" == "${answer,,}" ]] && { UI_REPLY="${keys[i]}"; return 0; }
        done
        msg_error "Invalid option '$answer' - enter one of the keys in brackets"
    done
}

# ui_pick <title> <value>...
# Picks one value from a list and puts it in UI_REPLY. Labels to show
# instead of the values can be set in UI_PICK_LABELS first (one per value).
# Gum offers a searchable list; the plain interface a numbered one that
# also accepts a value typed in full. An empty answer cancels.
ui_pick() {
    local title="$1"
    shift
    local values=("$@") labels=("${UI_PICK_LABELS[@]}") i rc
    UI_PICK_LABELS=()
    ((${#labels[@]} == ${#values[@]})) || labels=("${values[@]}")

    if ((UI_GUM)); then
        ui_gum filter "--header=$title" "--placeholder=Type to search..." --height=15 -- "${labels[@]}"
        rc=$?
        if ((rc == 0)); then
            for i in "${!labels[@]}"; do
                [[ "${labels[i]}" == "$UI_REPLY" ]] && { UI_REPLY="${values[i]}"; return 0; }
            done
            ui_gum_failed "unexpected choice"
        elif ((rc != 3)); then
            return $rc
        fi
    fi

    printf '%s\n' "${BOLD}$title${NC}"
    for i in "${!labels[@]}"; do
        printf "  %3d) %s\n" $((i + 1)) "${labels[i]}"
    done
    echo
    while true; do
        ui_read "Number or name (Enter goes back): " || return
        [[ -z "$UI_REPLY" ]] && return 2
        if [[ "$UI_REPLY" =~ ^[0-9]+$ ]] && ((UI_REPLY >= 1 && UI_REPLY <= ${#values[@]})); then
            UI_REPLY="${values[UI_REPLY - 1]}"
            return 0
        fi
        for i in "${!values[@]}"; do
            [[ "${values[i]}" == "$UI_REPLY" ]] && return 0
        done
        [[ "${UI_REPLY,,}" == q ]] && return 2
        msg_error "Invalid selection '$UI_REPLY'"
    done
}

# ui_input <label> [default] [hint] [secret]
# Asks for one value. An empty answer takes <default>. Gum shows the
# default as an editable value; the plain interface as "label [default]".
ui_input() {
    local label="$1" default="$2" hint="$3" mode="$4" rc
    if ((UI_GUM)); then
        local args=(input "--header=$label" "--prompt=> ")
        [[ -n "$hint" ]] && args+=("--placeholder=$hint")
        [[ -n "$default" ]] && args+=("--value=$default")
        [[ "$mode" == secret ]] && args+=(--password)
        ui_gum "${args[@]}"
        rc=$?
        if ((rc == 0)); then
            UI_REPLY="${UI_REPLY:-$default}"
            # gum clears its prompt: leave the answer on screen.
            [[ "$mode" == secret ]] || printf '%s\n' "${GRAY}$label:${NC} $UI_REPLY"
            return 0
        fi
        ((rc != 3)) && return $rc
    fi
    [[ -n "$hint" ]] && ui_hint "$hint"
    ui_read "$label${default:+ [$default]}: " "$mode" || return
    UI_REPLY="${UI_REPLY:-$default}"
}

# confirm "question" [default]  -- default is "y" or "n" (default: "n")
# Returns 0 for yes, 1 for no. An empty answer takes the default; end of
# input, cancelling and non-interactive mode are always "no".
confirm() {
    local question="$1" default="${2:-n}" rc
    if ((UI_GUM)); then
        local def=false
        [[ "$default" == y ]] && def=true
        gum confirm --default="$def" -- "$question"
        rc=$?
        case "$rc" in
            0) printf '%s\n' "${YELLOW}${question}${NC} yes"; return 0 ;;
            1|130) printf '%s\n' "${YELLOW}${question}${NC} no"; return 1 ;;
            *) ui_gum_failed "$rc" ;;
        esac
    fi

    local hint="y/N"
    [[ "$default" == "y" ]] && hint="Y/n"
    ui_read "${YELLOW}${question} [${hint}]: ${NC}" || {
        (($? == 1 && !UI_NONINTERACTIVE)) && echo
        return 1
    }
    local answer="${UI_REPLY:-$default}"
    [[ "${answer,,}" == y || "${answer,,}" == yes ]]
}

# ui_confirm_typed <expected> <prompt>
# For destructive actions: the user must type <expected> exactly.
# Returns 0 on a match, 1 input closed, 2 cancelled, 3 no match.
ui_confirm_typed() {
    ui_input "$2" "" "" || return
    [[ "$UI_REPLY" == "$1" ]] || return 3
}

pause() {
    ((UI_NONINTERACTIVE)) && return 0
    echo
    printf '%s' "${GRAY}Press any key to continue...${NC}"
    # Any key, end of input or Ctrl-C continues (see ui_read for the slices).
    UI_INTERRUPTED=0
    while read -rsn1 -t 0.5; (($? > 128 && !UI_INTERRUPTED)); do :; done
    echo
}

# ui_pager  -- shows stdin: in gum's pager, or printed followed by a pause.
ui_pager() {
    local text
    text=$(cat)
    if ((UI_GUM)); then
        printf '%s\n' "$text" | gum pager
        local rc=$?
        ((rc == 0 || rc == 1 || rc == 130)) && return 0
        ui_gum_failed "$rc"
    fi
    printf '%s\n' "$text"
    pause
}
