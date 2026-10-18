#!/bin/bash
# D11: prompts must handle end of input. Every run here is bounded in time
# (timeout) and output size (ulimit -f), so the current looping behaviour
# cannot hang or flood the suite.
#
# Exit 124 = killed by timeout, 153 = output limit hit: both mean the app
# kept looping after stdin closed. After the D11 fix these become
# "exits promptly with a non-zero status".

looped() { [[ "$1" == 124 || "$1" == 153 ]]; }

t_eof_in_first_run_setup() {
    known_defect "D11: first-run setup loops forever on EOF"
    run_app_bounded '' 3
    local rc=$?
    looped "$rc"; assert_eq 0 $? "still running after 3s (rc=$rc)"
    assert_matches "$(head -c 200000 /tmp/bounded.out)" "Invalid domain" "re-prompts on EOF"
}

t_eof_in_main_menu() {
    known_defect "D11: main menu redraws forever on EOF"
    fixture_configured
    run_app_bounded '' 3
    local rc=$?
    looped "$rc"; assert_eq 0 $? "still running after 3s (rc=$rc)"
    local draws
    draws=$(head -c 2000000 /tmp/bounded.out | grep -c "NGINX MANAGER PRO")
    ((draws > 1)) && pass "menu redrawn repeatedly ($draws)" || fail "menu redrawn repeatedly ($draws)"
}

t_eof_in_add_site() {
    known_defect "D11: add-site prompt loops forever on EOF"
    fixture_configured
    run_app_bounded '1\na\n' 3
    local rc=$?
    looped "$rc"; assert_eq 0 $? "still running after 3s (rc=$rc)"
    assert_matches "$(head -c 200000 /tmp/bounded.out)" "Invalid name" "re-prompts on EOF"
    assert_eq "{}" "$(cat "$MANAGER_DIR/sites.json")" "no site written"
}
