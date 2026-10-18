#!/bin/bash
# ==========================================================
# NGINX Manager Pro - UI helpers and messaging
# Sourced by nginx-site.sh: defines functions only.
# ==========================================================

# ==========================================================
# UI HELPERS / MESSAGING
# ==========================================================
pause() {
    echo
    read -n1 -s -r -p "$(echo -e "${GRAY}Press any key...${NC}")"
    echo
}

header() {
    clear
    echo -e "${BLUE}${BOLD}NGINX MANAGER PRO${NC}"
    echo "──────────────────────────────────────────────────────"
}

msg_success() { echo -e "${GREEN}✓ $1${NC}"; }
msg_warning() { echo -e "${YELLOW}! $1${NC}"; }
msg_error()   { echo -e "${RED}✗ $1${NC}"; }
msg_step()    { echo -e "${CYAN}→ $1${NC}"; }

# read_input <var> <prompt>  -- read -p into the named variable.
# Returns 1 at end of input (a last line without a newline still counts as
# input), so prompt loops can stop instead of re-prompting forever.
read_input() {
    read -p "$2" "$1" || [[ -n "${!1}" ]]
}

# Reports that stdin has closed; the caller then stops its flow.
input_closed() {
    echo
    msg_warning "Input closed - ${1:-cancelled}"
}

# confirm "question" [default]  -- default is "y" or "n" (default: "n")
# Returns 0 for yes, 1 for no. Empty input accepts the default; end of
# input is always "no".
confirm() {
    local question="$1" default="${2:-n}"
    local hint="y/N"
    [[ "$default" == "y" ]] && hint="Y/n"

    echo -e -n "${YELLOW}${question} [${hint}]: ${NC}"
    local answer
    if ! read answer && [[ -z "$answer" ]]; then
        echo
        return 1
    fi
    answer="${answer:-$default}"
    [[ "$answer" =~ ^[Yy]$ ]]
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
