#!/bin/bash
# User interface: output styling, terminal detection, the gum front end
# (mocked: tests/mocks/gum), the plain fallback, non-interactive mode,
# cancellation and Ctrl-C. Real gum is never used; nothing needs a person
# at a terminal ("script" provides a pseudo-terminal where one is needed).

ESC=$'\033'

# assert_contains strips colour codes, so escape sequences are checked on
# the raw output.
has_escapes() { [[ "$1" == *"$ESC["* ]]; }
assert_escapes() { # output message
    if has_escapes "$1"; then pass "$2"; else fail "$2 (no escape sequences)"; fi
}
assert_no_escapes() { # output message
    if has_escapes "$1"; then fail "$2 (escape sequences found)"; else pass "$2"; fi
}

# Runs the app on a pseudo-terminal, typing the given chunks with a pause
# before each, so the app sees a real terminal (colours, Ctrl-C as a key).
run_on_tty() { # env-assignments chunk...
    local env="$1"
    shift
    {
        local chunk
        for chunk in "$@"; do
            sleep 1
            printf '%b' "$chunk"
        done
        sleep 1
    } | timeout 30 script -qec "env TERM=xterm $env bash $APP" /dev/null 2>&1
}

# ==========================================================
# Styling and terminal detection
# ==========================================================
t_helpers_plain_output() {
    fixture_configured; load_app
    ui_init </dev/null >/dev/null 2>&1
    assert_eq "✓ done" "$(msg_success done)" "success"
    assert_eq "! careful" "$(msg_warning careful)" "warning"
    assert_eq "✗ failed" "$(msg_error failed)" "error"
    assert_eq "→ working" "$(msg_step working)" "step"
    assert_eq "● ENABLED|○ DISABLED|✓ ok|! warn|✗ err|— none|? unknown" \
        "$(ui_badge on ENABLED)|$(ui_badge off DISABLED)|$(ui_badge ok ok)|$(ui_badge warn warn)|$(ui_badge err err)|$(ui_badge none none)|$(ui_badge other unknown)" \
        "badges"
    assert_eq "● ON       |" "$(ui_badge_cell 11 on ON)|" "badge padded to its column"
    assert_eq "  Label          value" "$(ui_kv Label value)" "key/value line"
    assert_eq "NGINX Manager Pro › Sites › app" "$(ui_screen Sites app | head -1)" "screen title"
}

t_no_ansi_when_piped() {
    fixture_configured
    seed "new_site app http; enable_site app"
    local out
    out=$(run_app '2\n1\nq\nq\nq\n')
    assert_contains "$out" "● ENABLED" "content is there"
    assert_no_escapes "$out" "no escape sequences in piped output"
    assert_not_called "clear" "screen not cleared when piped"
}

t_colour_on_terminal_and_no_color() {
    fixture_configured
    local out
    out=$(run_on_tty "" 'q\n')
    assert_escapes "$out" "colours on a terminal"
    assert_contains "$out" "Basic interface: gum is not installed" "fallback explained on a terminal"
    assert_count "$out" "Basic interface:" 1 "explained once"
    out=$(run_on_tty "NO_COLOR=1" 'q\n')
    assert_no_escapes "$out" "NO_COLOR: no colours"
    assert_contains "$out" "NGINX Manager Pro" "NO_COLOR: still works"
}

t_ascii_without_utf8_locale() {
    fixture_configured
    seed "new_site app http; enable_site app"
    local out
    out=$(printf '2\nq\nq\n' | LANG=C LC_ALL=C timeout 20 bash "$APP" 2>&1)
    assert_eq 0 "$(printf '%s' "$out" | LC_ALL=C tr -d '\000-\177' | wc -c)" "only ASCII characters"
    assert_matches "$out" '^  1 +app +\* ENABLED +HTTP ' "ASCII status symbol"
    assert_matches "$out" '^-{60}$' "ASCII rule"
    assert_contains "$out" "NGINX Manager Pro > Sites" "ASCII title separator"
}

# ==========================================================
# Command line and non-interactive mode
# ==========================================================
t_help_and_unknown_option() {
    local out rc
    out=$(setpriv --reuid=65534 --regid=65534 --clear-groups bash "$APP" --help 2>&1); rc=$?
    assert_eq 0 "$rc" "--help exits 0 without root"
    assert_contains "$out" "Usage: nginx-manager [--plain] [--non-interactive] [--help]" "usage"
    assert_not_contains "$out" "Run as root" "no sudo for --help"
    out=$(bash "$APP" --bogus 2>&1 </dev/null); rc=$?
    assert_eq 2 "$rc" "unknown option exits 2"
    assert_contains "$out" "unknown option '--bogus'" "named"
}

t_non_interactive_stops_at_first_question() {
    fixture_configured
    local out rc
    out=$(printf 'q\n' | timeout 10 bash "$APP" --non-interactive 2>&1); rc=$?
    assert_eq 1 "$rc" "exits 1 instead of reading the piped 'q'"
    assert_contains "$out" "NGINX service" "status still shown"
    assert_contains "$out" "Non-interactive mode: 'Select' needs an answer; stopping" "says why"
    assert_no_escapes "$out" "no escape sequences"

    rm -f "$MANAGER_DIR/config.conf"
    out=$(NM_NONINTERACTIVE=1 timeout 10 bash "$APP" 2>&1 </dev/null); rc=$?
    assert_eq 1 "$rc" "first-run setup: exits 1"
    assert_contains "$out" "Non-interactive mode: 'Base domain' needs an answer; stopping" "names the missing value"
    assert_contains "$out" "Input closed - setup not completed" "setup not completed"
}

t_non_interactive_confirm_is_no() {
    fixture_configured; load_app
    UI_NONINTERACTIVE=1
    confirm "Delete everything?" y </dev/null >/dev/null 2>&1
    assert_eq 1 $? "a default-yes question is still no"
    ui_input "Name" "default" </dev/null >/dev/null 2>&1
    assert_eq 1 $? "input with a default still stops"
}

# ==========================================================
# Plain prompts
# ==========================================================
t_plain_prompts() {
    fixture_configured; load_app
    ui_menu "T" b "a|Alpha|" "b|Beta|" <<< $'A\n' >/dev/null
    assert_eq "0 a" "$? $UI_REPLY" "key in any case"
    ui_menu "T" b "a|Alpha|" "b|Beta|" <<< $'\n' >/dev/null
    assert_eq "0 b" "$? $UI_REPLY" "empty answer takes the default"
    local out
    out=$(ui_menu "T" "" "a|Alpha|" <<< $'x\n\na\n' 2>&1)
    assert_count "$out" "Invalid option 'x'" 1 "unknown key rejected"
    ui_menu "T" "" "a|Alpha|" </dev/null >/dev/null
    assert_eq 1 $? "end of input"
    ui_pick "P" one two <<< $'2\n' >/dev/null
    assert_eq "0 two" "$? $UI_REPLY" "pick by number"
    ui_pick "P" one two <<< $'one\n' >/dev/null
    assert_eq "0 one" "$? $UI_REPLY" "pick by name"
    ui_pick "P" one two <<< $'\n' >/dev/null
    assert_eq 2 $? "empty answer goes back"
    out=$(ui_pick "P" one two <<< $'7\n' 2>&1)
    assert_contains "$out" "Invalid selection '7'" "out of range rejected"
    ui_input "Domain" "a.example.com" <<< $'\n' >/dev/null
    assert_eq "0 a.example.com" "$? $UI_REPLY" "input default"
    out=$(ui_input "Token" "" "" secret <<< $'hunter2\n' 2>&1)
    assert_not_contains "$out" "hunter2" "secret not echoed"
    confirm "Sure?" n <<< $'yes\n' >/dev/null
    assert_eq 0 $? "'yes' accepted"
    confirm "Sure?" y </dev/null >/dev/null
    assert_eq 1 $? "end of input is no"
}

# Ctrl-C at a question cancels that flow and returns to the menu; the
# manager keeps running and nothing is written.
t_ctrl_c_cancels_form() {
    fixture_configured
    local out
    out=$(run_on_tty "" '3\n' 'app\n' '\003' 'q\n')
    assert_contains "$out" "Cancelled - nothing was changed" "cancel reported"
    assert_eq "{}" "$(cat "$MANAGER_DIR/sites.json")" "no site saved"
    assert_no_file "$SITES_AVAILABLE/app.conf" "no config written"
    assert_count "$out" "Main menu" 2 "back at the main menu"
}

t_secret_not_echoed_on_terminal() {
    fixture_configured
    local out
    out=$(run_on_tty "" '4\n' '4\n' 'supersecret\n' '\n' 'q\n' 'q\n')
    assert_contains "$out" "Cloudflare credentials saved" "saved"
    assert_not_contains "$out" "supersecret" "never echoed by the terminal"
    assert_eq "dns_cloudflare_api_token = supersecret" "$(cat "$MANAGER_DIR/secrets/cloudflare.ini")" "stored"
}

# During an operation Ctrl-C is ignored, also by the commands it runs, so
# the operation finishes instead of stopping half-way.
t_operation_not_interrupted() {
    fixture_configured
    local out
    out=$(setsid bash -c '
        NM_NO_MAIN=1 source "$1" >/dev/null 2>&1
        ui_trap_interrupts
        ( sleep 0.5; kill -INT -- -$$ ) &
        ui_run bash -c "sleep 1.5; echo op-finished"
        echo "rc=$?"
        ( sleep 0.5; kill -INT -- -$$ ) &
        bash -c "sleep 1.5; echo unguarded-finished"
        echo "unguarded rc=$?"
    ' _ "$APP" 2>&1)
    assert_contains "$out" "op-finished" "guarded operation completes"
    assert_contains "$out" "rc=0" "with its own status"
    assert_not_contains "$out" "unguarded-finished" "control: an unguarded command is interrupted"
}

# ==========================================================
# Gum front end (mocked)
# ==========================================================
t_gum_missing_falls_back() {
    fixture_configured
    local out rc
    out=$(printf '6\n\nq\n' | NM_UI=gum timeout 20 bash "$APP" 2>&1); rc=$?
    assert_eq 0 "$rc" "plain interface works"
    assert_contains "$out" "[1] Status" "plain menu shown"
    assert_matches "$out" '^  Prompts +○ Basic \(gum is not installed\)$' "settings explain why"
}

t_gum_too_old_falls_back() {
    fixture_configured
    use_gum
    echo "gum version v0.14.5 (abc)" > /tmp/gum-version
    local out
    out=$(printf '6\n\nq\n' | NM_UI=gum timeout 20 bash "$APP" 2>&1)
    assert_contains "$out" "gum 0.14.5 is too old (0.15 or newer needed)" "reason shown"
    assert_eq "gum --version" "$(gum_calls)" "gum only asked for its version"
}

t_gum_not_used_without_terminal() {
    fixture_configured
    use_gum
    local out
    out=$(run_app '6\n\nq\n')
    assert_contains "$out" "Basic (not running in a terminal)" "auto mode needs a terminal"
    assert_not_contains "$(gum_calls)" "choose" "gum never prompted"
}

t_gum_failure_falls_back_once() {
    fixture_configured
    use_gum "2"
    local out rc
    out=$(printf 'q\n' | NM_UI=gum timeout 20 bash "$APP" 2>&1); rc=$?
    assert_eq 0 "$rc" "continues and quits from the plain menu"
    assert_count "$out" "gum failed (exit 2); continuing with the basic interface" 1 "reported once"
    assert_eq 1 "$(gum_calls | grep -c '^gum choose')" "gum not retried"
}

t_gum_menu_arguments() {
    fixture_configured; load_app
    use_gum "0 #2"
    NM_UI=gum ui_init </dev/null >/dev/null 2>&1
    ui_menu "Pick" b "a|Alpha|first" "b|Beta|second" >/dev/null
    assert_eq "0 b" "$? $UI_REPLY" "label mapped back to its key"
    assert_contains "$(gum_calls)" "gum choose | --header=Pick | --height=15 | --selected=Beta    second | -- | Alpha   first | Beta    second" \
        "options after --, default preselected"
}

t_gum_add_site() {
    fixture_configured
    use_gum "0 #3" "0 app" "0 app.lan.example.com" "0 127.0.0.1:8080" "0 #2" "0" "0" "0 #9"
    local out rc
    out=$(printf '\n' | NM_UI=gum timeout 20 bash "$APP" 2>&1); rc=$?
    assert_eq 0 "$rc" "exits 0"
    golden_compare https.conf "$SITES_AVAILABLE/app.conf"
    assert_symlink "$SITES_ENABLED/app.conf" "enabled"
    assert_called "systemctl reload nginx" "reloaded"
    local calls
    calls=$(gum_calls)
    assert_contains "$calls" "gum input | --header=Domain | --prompt=>  | --placeholder=the name clients use, e.g. app.lan.example.com | --value=app.lan.example.com" \
        "domain suggested as an editable value"
    assert_contains "$calls" "gum confirm | --default=true | -- | Create site 'app'?" "summary confirmed"
    assert_contains "$calls" "gum confirm | --default=true | -- | Enable site now?" "enable asked"
    assert_contains "$out" "Site enabled" "result reported"
}

t_gum_cancel_changes_nothing() {
    fixture_configured
    # New site, name, then Esc at the domain; Ctrl-C at the main menu quits.
    use_gum "0 #3" "0 app" "1" "130"
    local out rc
    out=$(NM_UI=gum timeout 20 bash "$APP" 2>&1 </dev/null); rc=$?
    assert_eq 0 "$rc" "cancelling the main menu exits 0"
    assert_contains "$out" "Cancelled - nothing was changed" "cancel reported"
    assert_eq "{}" "$(cat "$MANAGER_DIR/sites.json")" "no site saved"
    assert_no_file "$SITES_AVAILABLE/app.conf" "no config written"
}

t_gum_backend_failure_shown() {
    fixture_configured
    use_gum "0 #3" "0 app" "0 app.other.com" "0 127.0.0.1:8080" "0 #2" "0" "0 #9"
    local out
    out=$(printf '\n' | NM_UI=gum timeout 20 bash "$APP" 2>&1)
    assert_contains "$out" "Could not create site" "failure shown"
    assert_not_contains "$out" "Configuration generated" "no success claimed"
    assert_not_contains "$(gum_calls)" "Enable site now?" "not offered to enable"
    assert_db 'has("app") | not' "rolled back"
}

t_gum_delete_needs_exact_name() {
    fixture_configured
    seed "new_site app http; enable_site app"
    # Sites, open app, Delete, wrong name; Back, Esc out of the list, Quit.
    use_gum "0 #2" "0 #1" "0 #6" "0 App" "0 #7" "1" "0 #9"
    run_app_gum() { printf '\n' | NM_UI=gum timeout 20 bash "$APP" 2>&1; }
    local out
    out=$(run_app_gum)
    assert_contains "$out" "Cancelled (name did not match)" "wrong name refused"
    assert_db 'has("app")' "site kept"
    assert_contains "$(gum_calls)" "gum input | --header=Type the site name to confirm deletion" "typed confirmation via gum"
    # Esc at the confirmation also keeps the site.
    use_gum "0 #2" "0 #1" "0 #6" "1" "0 #7" "1" "0 #9"
    out=$(run_app_gum)
    assert_contains "$out" "Cancelled - nothing was changed" "Esc cancels"
    assert_db 'has("app")' "site still kept"
    use_gum "0 #2" "0 #1" "0 #6" "0 app" "1" "0 #9"
    out=$(run_app_gum)
    assert_contains "$out" "Site 'app' deleted" "exact name deletes"
    assert_db 'has("app") | not' "site gone"
}

t_gum_confirm_defaults() {
    fixture_configured
    seed "new_site app http; enable_site app"
    # Sites, open app, Regenerate, answer No; Back, Esc, Quit.
    use_gum "0 #2" "0 #1" "0 #4" "1" "0 #7" "1" "0 #9"
    printf '\n' | NM_UI=gum timeout 20 bash "$APP" >/dev/null 2>&1
    assert_contains "$(gum_calls)" "gum confirm | --default=false | -- | Regenerate configuration for 'app'?" \
        "default-no question preselects No"
    assert_eq 0 "$(ls "$MANAGER_DIR/backups" | wc -l)" "declined: nothing regenerated"
    # Ctrl-C at a yes/no question is "no".
    use_gum "0 #2" "0 #1" "0 #2" "130" "0 #7" "1" "0 #9"
    printf '\n' | NM_UI=gum timeout 20 bash "$APP" >/dev/null 2>&1
    assert_symlink "$SITES_ENABLED/app.conf" "Ctrl-C at 'Disable site?' keeps it enabled"
}

t_gum_site_list_searchable() {
    fixture_configured
    seed "new_site app http; enable_site app; new_site web http"
    # Sites, Esc out of the list, Quit.
    use_gum "0 #2" "1" "0 #9"
    NM_UI=gum timeout 20 bash "$APP" </dev/null >/dev/null 2>&1
    local call
    call=$(gum_calls | grep '^gum filter')
    assert_contains "$call" "--placeholder=Search sites..." "searchable"
    assert_matches "$call" '-- \| app +● ENABLED +HTTP +app\.lan\.example\.com +127\.0\.0\.1:8080 \| web +○ DISABLED' "rows carry the symlink state"
    assert_contains "$call" "| + New site | Import existing nginx configs | Regenerate all configurations | Back" "actions listed after the sites"
}

# ==========================================================
# Site state and plugin recovery through the UI
# ==========================================================
t_list_state_comes_from_symlink() {
    fixture_configured
    seed "new_site app http; new_site web http; db_update_enabled web true"
    echo "# hand-made" > "$SITES_ENABLED/app.conf"
    local out
    out=$(run_app '2\nq\nq\n')
    assert_matches "$out" '^  1 +app +\? UNKNOWN ' "something that is not a symlink: unknown"
    assert_contains "$out" "is not a symlink; the manager will not enable, disable or delete it" "explained"
    assert_matches "$out" '^  2 +web +○ DISABLED ' "db flag true, no symlink: disabled"
    assert_eq "# hand-made" "$(cat "$SITES_ENABLED/app.conf")" "listing changes nothing"
    assert_db '.web.enabled == true' "listing does not touch the db"
}

t_plugin_broken_can_be_disabled_from_menu() {
    fixture_configured; load_app
    PLUGIN_DIR=/tmp/nm-plugins-none
    printf 'ghost\n' > "$MANAGER_DIR/plugins.enabled"
    local out
    out=$(plugins_menu <<< $'d\nghost\n\nq\n' 2>&1)
    assert_contains "$out" "enabled, but not installed in /tmp/nm-plugins-none - disable it" "problem shown"
    assert_contains "$out" "An enabled plugin cannot run, so sites cannot be created or changed." "consequence shown"
    assert_contains "$out" "Plugin 'ghost' disabled" "disabled from the menu"
    assert_eq "" "$(grep -v '^#' "$MANAGER_DIR/plugins.enabled")" "persisted"
}

t_plugin_invalid_enabled_list_explained() {
    fixture_configured; load_app
    printf 'Bad ID\n' > "$MANAGER_DIR/plugins.enabled"
    local out
    out=$(plugins_menu <<< $'d\n\nq\n' 2>&1)
    assert_contains "$out" "line 1: not a plugin ID" "reason shown"
    assert_contains "$out" "rm $MANAGER_DIR/plugins.enabled" "recovery shown"
    assert_contains "$out" "fix or remove it first" "disable explains instead of failing silently"
    assert_eq "Bad ID" "$(cat "$MANAGER_DIR/plugins.enabled")" "file left for the user to fix"
    out=$(run_app 'q\n')
    assert_contains "$out" "No plugin can run" "dashboard warns"
}

t_plugin_details_hide_values() {
    fixture_configured; load_app
    PLUGIN_DIR=/src/plugins   # the checkout's example plugin, also for the bundle
    mkdir -p "$MANAGER_DIR/plugins"
    printf '%s\n' "TOKEN=s3cret" > "$MANAGER_DIR/plugins/example.conf"
    printf 'v' | plugin_secret_set example api-key >/dev/null 2>&1
    local out
    out=$(plugin_details example <<< $'\n' 2>&1)
    assert_matches "$out" '^  Version +[0-9]+\.[0-9]+\.[0-9]+$' "manifest shown"
    assert_matches "$out" '^  Hooks +location-directives$' "hooks shown"
    assert_matches "$out" '^  Secrets +api-key$' "secret names shown"
    assert_not_contains "$out" "s3cret" "setting values not shown"
}

# ==========================================================
# Final review regressions
# ==========================================================
# gum splits --selected on commas: a default option containing one must be
# escaped, or nothing is preselected and Enter picks the first option (in
# Edit, that silently proposed HTTP instead of the site's BOTH).
t_gum_default_with_comma_escaped() {
    fixture_configured; load_app
    use_gum "0 #3"
    NM_UI=gum ui_init </dev/null >/dev/null 2>&1
    ui_choose_tls both >/dev/null
    assert_eq "0 both" "$? $UI_REPLY" "Both chosen"
    assert_contains "$(gum_calls)" '--selected=Both    ports 80 and 443\, no redirect |' "comma escaped for gum's list parsing"
}

# gum rejects "--value -x" (it reads -x as a flag), and domains may start
# with "-": values are always passed as --flag=value.
t_gum_values_starting_with_dash() {
    fixture_configured; load_app
    use_gum "0 -x.lan.example.com"
    NM_UI=gum ui_init </dev/null >/dev/null 2>&1
    ui_input "Domain" "-x.lan.example.com" "-hint" >/dev/null
    assert_eq "0 -x.lan.example.com" "$? $UI_REPLY" "answer kept"
    assert_contains "$(gum_calls)" "--placeholder=-hint | --value=-x.lan.example.com" "passed as --flag=value"
}

# gum draws its screens on stderr: with stderr redirected, auto mode keeps
# the basic interface. With everything on the terminal it uses gum.
t_gum_auto_mode_needs_terminal_stderr() {
    fixture_configured
    use_gum "0 #9"
    { sleep 1; printf '6\n'; sleep 1; printf '\n'; sleep 1; printf 'q\n'; sleep 1; } \
        | timeout 30 script -qec "env TERM=xterm bash $APP 2>/tmp/stderr.log" /dev/null >/tmp/tty.out 2>&1
    assert_contains "$(cat /tmp/tty.out)" "Basic (not running in a terminal)" "stderr redirected: basic interface"
    assert_not_contains "$(gum_calls)" "gum choose" "gum not used"

    use_gum "0 #9"
    run_on_tty "" >/dev/null
    assert_contains "$(gum_calls)" "gum choose | --header=Main menu" "full terminal: gum used automatically"
}

t_gum_version_probe_failures() {
    fixture_configured
    use_gum
    local out
    echo "gum version unknown (built from source)" > /tmp/gum-version
    out=$(printf '6\n\nq\n' | NM_UI=gum timeout 20 bash "$APP" 2>&1)
    assert_contains "$out" "gum version could not be determined (0.15 or newer needed)" "unexpected output: fallback"
    echo "gum version v0.16.2" > /tmp/gum-version; echo 2 > /tmp/gum-version-rc
    out=$(printf '6\n\nq\n' | NM_UI=gum timeout 20 bash "$APP" 2>&1)
    assert_contains "$out" "gum version could not be determined" "failing probe: fallback even with a version printed"
    echo "gum version v2.0.2 (1a2b3c4)" > /tmp/gum-version; echo 0 > /tmp/gum-version-rc
    use_gum "0 #6" "1" "0 #9"
    out=$(printf '\n' | NM_UI=gum timeout 20 bash "$APP" 2>&1)
    assert_matches "$out" '^  Prompts +✓ gum 2\.0\.2 \(enhanced\)$' "v2 accepted"
}

# Ctrl-C while the dashboard checks nginx must not kill the check and leave
# "Not running" on screen (and cached).
t_ctrl_c_during_status_check() {
    fixture_configured
    printf '%s\n' '#!/bin/bash' 'echo "systemctl $*" >> /tmp/mock-calls.log' 'sleep 1.5' > "$MOCK_BIN/systemctl"
    local out
    out=$(setsid bash -c '
        NM_NO_MAIN=1 source "$1" >/dev/null 2>&1
        ui_init; ui_trap_interrupts
        ( sleep 0.5; kill -INT -- -$$ ) &
        render_dashboard_status
    ' _ "$APP" 2>&1)
    assert_matches "$out" '^  NGINX service +✓ Running$' "check finished despite Ctrl-C"
    assert_not_contains "$out" "nginx is not running" "no false warning"
}

# SIGTERM/SIGHUP while a secret is typed (echo off) must restore the
# terminal, then still end the manager by that signal. A wrapper on the
# pseudo-terminal runs the app in the foreground, records its PID, and
# reports the terminal's echo setting after the app has gone.
assert_signal_restores_echo() { # signal expected-status
    fixture_configured
    rm -f /tmp/app.pid
    cat > /tmp/wrapper.sh <<WRAP
bash -c 'echo \$\$ > /tmp/app.pid; exec bash "\$1"' _ "$APP"
echo "app-status=\$?"
stty -a | grep -oE '(^| )-?echo( |;|\$)' | head -1 | tr -d ' ;' | sed 's/^/echo-flag=/'
WRAP
    local out
    out=$({
        sleep 1; printf '4\n'; sleep 1; printf '4\n'; sleep 1.5
        kill -s "$1" "$(cat /tmp/app.pid)"; sleep 1.5
    } | timeout 30 script -qec "env TERM=xterm bash /tmp/wrapper.sh" /dev/null 2>&1)
    assert_contains "$out" "API token: " "$1: reached the secret prompt"
    assert_contains "$out" "app-status=$2" "$1: manager ended by the signal"
    assert_contains "$out" "echo-flag=echo" "$1: terminal echo restored"
    assert_not_contains "$out" "echo-flag=-echo" "$1: echo not left off"
    assert_not_contains "$out" "Cloudflare credentials saved" "$1: no success reported"
    assert_no_file "$MANAGER_DIR/secrets/cloudflare.ini" "$1: nothing written"
}

t_sigterm_at_secret_restores_echo() { assert_signal_restores_echo TERM 143; }
t_sighup_at_secret_restores_echo() { assert_signal_restores_echo HUP 129; }

# After a secret prompt that ended normally, TERM/HUP are back to their
# default handling.
t_secret_prompt_resets_signal_traps() {
    fixture_configured
    local out
    out=$(printf 'x\n' | script -qec "bash -c 'NM_NO_MAIN=1 source $APP >/dev/null 2>&1; ui_read \"S: \" secret; echo \"reply=\$UI_REPLY\"; trap -p TERM HUP; echo traps-listed'" /dev/null 2>&1)
    assert_contains "$out" "reply=x" "secret read"
    assert_not_contains "$out" "trap --" "no TERM/HUP trap left behind"
    assert_contains "$out" "traps-listed" "ran to the end"
}
