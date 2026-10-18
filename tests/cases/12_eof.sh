#!/bin/bash
# D11: prompts must handle end of input. Every run here is bounded in time
# (timeout) and output size (ulimit -f), so a regression to looping cannot
# hang or flood the suite.
#
# Exit 124 = killed by timeout, 153 = output limit hit: both mean the app
# kept looping after stdin closed. At end of input the app now stops the
# current flow and exits promptly with status 1.

looped() { [[ "$1" == 124 || "$1" == 153 ]]; }

# Runs the app with the given input; checks it exits 1 (not looping) and
# says why. Output is left in /tmp/bounded.out.
assert_stops_at_eof() { # input message
    run_app_bounded "$1" 5
    local rc=$?
    looped "$rc" && fail "$2: still running after 5s (rc=$rc)" || assert_eq 1 "$rc" "$2: exits 1"
    assert_contains "$(head -c 200000 /tmp/bounded.out)" "Input closed" "$2: end of input reported"
}

t_eof_in_first_run_setup() {
    assert_stops_at_eof '' "at domain prompt"
    assert_not_contains "$(cat "$MANAGER_DIR/config.conf")" "SETUP_DONE=true" "setup not marked done"
    assert_stops_at_eof 'lan.example.com\n' "at email prompt"
    assert_not_contains "$(cat "$MANAGER_DIR/config.conf")" "SETUP_DONE=true" "setup still not marked done"
    assert_count "$(cat /tmp/bounded.out)" "Invalid email" 0 "no re-prompt loop"
}

t_eof_in_main_menu() {
    fixture_configured
    assert_stops_at_eof '' "main menu"
    assert_count "$(cat /tmp/bounded.out)" "NGINX MANAGER PRO" 1 "menu drawn once"
}

t_eof_in_add_site() {
    fixture_configured
    local input
    for input in '1\na\n' '1\na\napp\n' '1\na\napp\napp.lan.example.com\n' \
            '1\na\napp\napp.lan.example.com\n127.0.0.1:8080\n'; do
        assert_stops_at_eof "$input" "add site after '$input'"
        assert_eq "{}" "$(cat "$MANAGER_DIR/sites.json")" "no site written after '$input'"
        assert_no_file "$SITES_AVAILABLE/app.conf" "no config written after '$input'"
    done
}

# End of input at a yes/no question is "no", whatever the default.
t_eof_at_confirm_means_no() {
    fixture_configured
    assert_stops_at_eof '1\na\napp\napp.lan.example.com\n127.0.0.1:8080\n1\n' "at 'Enable site now? [Y/n]'"
    assert_contains "$(cat /tmp/bounded.out)" "Site created (disabled)" "created, not enabled"
    assert_no_symlink "$SITES_ENABLED/app.conf" "not enabled"
    assert_not_called "systemctl reload" "no reload"
}

t_eof_in_edit_site() {
    fixture_configured
    seed "new_site app http"
    local before original input
    before=$(cat "$MANAGER_DIR/sites.json")
    original=$(cat "$SITES_AVAILABLE/app.conf")
    for input in '1\ne\n1\n' '1\ne\n1\n\n' '1\ne\n1\n\n\n'; do
        assert_stops_at_eof "$input" "edit after '$input'"
        assert_eq "$before" "$(cat "$MANAGER_DIR/sites.json")" "db unchanged after '$input'"
        assert_eq "$original" "$(cat "$SITES_AVAILABLE/app.conf")" "config unchanged after '$input'"
    done
}

t_eof_in_cloudflare_token() {
    fixture_configured
    assert_stops_at_eof '2\n4\n' "at token prompt"
    assert_no_file "$MANAGER_DIR/secrets/cloudflare.ini" "no credentials written"
}

# The lock is held by the process, so stopping at end of input frees it.
t_eof_exit_releases_lock() {
    fixture_configured
    assert_stops_at_eof '1\n' "sites menu"
    local out rc
    out=$(run_app 'q\n'); rc=$?
    assert_eq 0 "$rc" "next start works"
    assert_not_contains "$out" "Manager already running" "lock released"
}
