#!/bin/bash
# Runs one test case file inside the container. Every t_* function runs in a
# fresh bash process after reset_state, with a timeout so a prompt waiting
# for input cannot hang the suite.
case_file="$1"
case_name=$(basename "$case_file" .sh)
HARNESS=/src/tests/lib/harness.sh
log_dir="/out/logs/$case_name"

# NM_TEST_BUNDLE=1: run every case against the single-file bundle.
if [[ "${NM_TEST_BUNDLE:-}" == 1 ]]; then
    bash /src/tools/bundle.sh /tmp/nm-bundle.sh >/dev/null || exit 1
    export NM_TEST_APP=/tmp/nm-bundle.sh
fi

source "$HARNESS"
: > "$RESULTS"
mkdir -p "$log_dir"
create_test_cert

mapfile -t tests < <(grep -oE '^t_[A-Za-z0-9_]+\(\)' "$case_file" | tr -d '()')

for t in "${tests[@]}"; do
    timeout 60 bash -c '
        source "$1"; source "$2"
        export CURRENT_TEST="$3"
        reset_state
        "$3"
    ' _ "$HARNESS" "$case_file" "$t" > "$log_dir/$t.log" 2>&1
    rc=$?
    if ((rc == 124)); then
        CURRENT_TEST="$t" fail "timed out (waiting for input?)"
    elif ! grep -q " $t :: " "$RESULTS"; then
        CURRENT_TEST="$t" fail "no assertions recorded (rc=$rc)"
    fi
done

pass_n=$(grep -c '^PASS' "$RESULTS")
fail_n=$(grep -c '^FAIL' "$RESULTS")
known_n=$(grep -c '^KNOWN' "$RESULTS")
grep -E '^(FAIL|KNOWN)' "$RESULTS" | sed 's/^/  /'
printf '%-22s %3d passed  %3d failed  %3d known-defect markers\n' \
    "$case_name" "$pass_n" "$fail_n" "$known_n"
cp "$RESULTS" "/out/results-$case_name.txt"
((fail_n == 0))
