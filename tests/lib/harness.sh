#!/bin/bash
# ==========================================================
# Test harness helpers.
# Only ever sourced inside the disposable test container (see tests/run.sh):
# it freely rewrites /etc/nginx, /etc/nginx-manager and /usr/local/bin.
# ==========================================================

# NM_TEST_APP points the suite at another entry point (e.g. the bundle).
APP="${NM_TEST_APP:-/src/nginx-site.sh}"
RESULTS="/tmp/nm-results"
OUT_DIR="/out"
GOLDEN_DIR="/src/tests/golden"
FIXTURES="/src/tests/fixtures"
MOCK_BIN="/opt/mockbin"
MOCK_LOG="/tmp/mock-calls.log"
MOCK_RC="/tmp/mock-rc"
CERT_LIVE="/etc/letsencrypt/live/lan.example.com"
MANAGER_DIR="/etc/nginx-manager"
SITES_AVAILABLE="/etc/nginx/sites-available"
SITES_ENABLED="/etc/nginx/sites-enabled"

export PATH="$MOCK_BIN:$PATH"
export TERM=dumb
# Pin a UTF-8 locale: ${#var} counts characters there but bytes under C,
# which changes table padding around "●"/"○".
export LANG=C.UTF-8 LC_ALL=C.UTF-8

# ==========================================================
# RESULTS
# ==========================================================
_record() { echo "$1 ${CURRENT_TEST:-?} :: $2" >> "$RESULTS"; }
pass() { _record PASS "$1"; }
fail() { _record FAIL "$1"; echo "FAIL: $1" >&2; }

# Marks behaviour that is asserted as-is but is a confirmed defect
# scheduled for a fix in Stage 2d. Fixing it must update the test.
known_defect() { _record KNOWN "$1"; }

# ==========================================================
# ASSERTIONS
# ==========================================================
assert_eq() { # expected actual message
    if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 (expected '$1', got '$2')"; fi
}

strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }

# Output assertions compare against the text with colour codes removed.
assert_contains() { # haystack needle message
    local text
    text=$(printf '%s' "$1" | strip_ansi)
    if [[ "$text" == *"$2"* ]]; then
        pass "$3"
    else
        fail "$3 (output missing '$2')"
        printf '%s\n' "$text" | sed 's/^/    | /' >&2
    fi
}

assert_not_contains() { # haystack needle message
    local text
    text=$(printf '%s' "$1" | strip_ansi)
    if [[ "$text" != *"$2"* ]]; then pass "$3"; else fail "$3 (output unexpectedly contains '$2')"; fi
}

assert_matches() { # haystack extended-regex message
    if printf '%s' "$1" | strip_ansi | grep -qE -- "$2"; then
        pass "$3"
    else
        fail "$3 (no line matches /$2/)"
        printf '%s\n' "$1" | strip_ansi | sed 's/^/    | /' >&2
    fi
}

assert_count() { # haystack fixed-string expected-count message
    local n
    n=$(printf '%s' "$1" | strip_ansi | grep -cF -- "$2")
    assert_eq "$3" "$n" "$4"
}

assert_file() { if [[ -f "$1" ]]; then pass "${2:-file exists: $1}"; else fail "${2:-file exists: $1}"; fi; }
assert_no_file() { if [[ ! -e "$1" ]]; then pass "${2:-no file: $1}"; else fail "${2:-no file: $1}"; fi; }
assert_symlink() { if [[ -L "$1" ]]; then pass "${2:-symlink: $1}"; else fail "${2:-symlink: $1}"; fi; }
assert_no_symlink() { if [[ ! -L "$1" ]]; then pass "${2:-no symlink: $1}"; else fail "${2:-no symlink: $1}"; fi; }

assert_mode() { # path mode message
    assert_eq "$2" "$(stat -c %a "$1" 2>/dev/null)" "${3:-mode of $1}"
}

# Evaluates a jq boolean expression against sites.json.
assert_db() { # jq-expression message
    if jq -e "$1" "$MANAGER_DIR/sites.json" >/dev/null 2>&1; then
        pass "$2"
    else
        fail "$2 (jq '$1' false; db: $(tr -d '\n ' < "$MANAGER_DIR/sites.json" 2>/dev/null))"
    fi
}

assert_called() { # pattern message  (fixed-string match against the mock log)
    if grep -qF -- "$1" "$MOCK_LOG" 2>/dev/null; then pass "$2"; else fail "$2 (no mock call '$1')"; fi
}

assert_not_called() {
    if ! grep -qF -- "$1" "$MOCK_LOG" 2>/dev/null; then pass "$2"; else fail "$2 (unexpected mock call '$1')"; fi
}

# Compares a file to tests/golden/<name>. The actual file is always copied to
# tests/.out/golden/ so a missing or changed golden can be inspected.
golden_compare() { # golden-name actual-file
    mkdir -p "$OUT_DIR/golden"
    cp "$2" "$OUT_DIR/golden/$1"
    if [[ ! -f "$GOLDEN_DIR/$1" ]]; then
        fail "golden $1 missing (captured to tests/.out/golden/$1)"
    elif diff -u "$GOLDEN_DIR/$1" "$2" >&2; then
        pass "golden $1 matches"
    else
        fail "golden $1 differs (diff in test log)"
    fi
}

# ==========================================================
# MOCKS
# ==========================================================
install_mocks() {
    rm -rf "$MOCK_BIN"
    mkdir -p "$MOCK_BIN" "$MOCK_RC"
    local m
    for m in systemctl certbot apt apt-get clear; do
        cp /src/tests/mocks/generic "$MOCK_BIN/$m"
        chmod 755 "$MOCK_BIN/$m"
    done
}

# Opt-in mocks that shadow real binaries present in the image.
use_mock() {
    cp "/src/tests/mocks/$1" "$MOCK_BIN/$1"
    chmod 755 "$MOCK_BIN/$1"
}

remove_mock() { rm -f "$MOCK_BIN/$1"; }

# Installs the gum mock (tests/mocks/gum) with the given answers, one
# "<rc> <output>" line per gum call. See the mock for the format.
use_gum() { # answer...
    use_mock gum
    printf '%s\n' "$@" > /tmp/gum-script
    : > /tmp/gum-calls.log
}

gum_calls() { cat /tmp/gum-calls.log 2>/dev/null; }

mock_rc() { echo "$2" > "$MOCK_RC/$1"; }

# ==========================================================
# STATE
# ==========================================================
# Self-signed wildcard cert standing in for Let's Encrypt (once per container).
create_test_cert() {
    [[ -f "$CERT_LIVE/fullchain.pem" ]] && return
    mkdir -p "$CERT_LIVE"
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -days 30 -subj "/CN=lan.example.com" \
        -addext "subjectAltName=DNS:*.lan.example.com,DNS:lan.example.com" \
        -keyout "$CERT_LIVE/privkey.pem" -out "$CERT_LIVE/fullchain.pem" >/dev/null 2>&1
}

reset_state() {
    rm -rf "$MANAGER_DIR" /var/log/nginx-manager /run/lock/nginx-manager.lock \
        "$MOCK_RC" "$MOCK_LOG" /tmp/pwned* /tmp/nginx-manager.sh \
        /etc/victim.conf /usr/local/bin/nginx-manager /tmp/bounded.out \
        /etc/letsencrypt/live/soon.example.com \
        /tmp/nm-plugins* /tmp/plugin-calls.log /usr/local/lib/nginx-manager \
        /tmp/gum-script /tmp/gum-calls.log /tmp/gum-version /tmp/gum-version-rc \
        /tmp/mock-gh /tmp/mock-curl-hook /tmp/nm-release \
        /tmp/nm-root /tmp/nm-src /usr/local/bin/.nginx-manager.new.*
    rm -f "$SITES_AVAILABLE"/*.conf "$SITES_ENABLED"/*.conf \
        /etc/nginx/snippets/proxy-common.conf /etc/nginx/snippets/tls-common.conf
    [[ -e /usr/bin/jq.off ]] && mv /usr/bin/jq.off /usr/bin/jq
    install_mocks
    : > "$MOCK_LOG"
}

fixture_configured() {
    mkdir -p "$MANAGER_DIR"
    cat > "$MANAGER_DIR/config.conf" <<EOF
DOMAIN=lan.example.com
CERT_NAME=lan.example.com
CERTBOT_EMAIL=admin@example.com
DEFAULT_TLS=https
SETUP_DONE=true
EOF
}

fixture_sites_v3() {
    mkdir -p "$MANAGER_DIR"
    cp "$FIXTURES/sites-v3.json" "$MANAGER_DIR/sites.json"
    chmod 600 "$MANAGER_DIR/sites.json"
}

fixture_cloudflare() {
    mkdir -p "$MANAGER_DIR/secrets"
    chmod 700 "$MANAGER_DIR/secrets"
    echo "dns_cloudflare_api_token = test-token" > "$MANAGER_DIR/secrets/cloudflare.ini"
    chmod 600 "$MANAGER_DIR/secrets/cloudflare.ini"
}

# ==========================================================
# APP
# ==========================================================
# Loads the application's functions into the current shell (NM_NO_MAIN=1:
# no root check, lock or menu), then runs the start-up initialisation steps
# the tests rely on. A fixture must provide a finished config first, or
# first-run setup would block reading stdin.
load_app() {
    if ! NM_NO_MAIN=1 source "$APP" </dev/null >/dev/null 2>&1; then
        fail "load_app: sourcing $APP failed"
        return 1
    fi
    {
        init_directories
        create_default_config
        first_run_setup
        create_database
        create_snippets
    } </dev/null >/dev/null 2>&1
}

# Builds the single-file script (tools/bundle.sh) at the given path.
build_bundle() { # output
    bash /src/tools/bundle.sh "$1" >/dev/null
}

# Runs the full application as a separate process with the given stdin.
run_app() { # input
    printf '%b' "$1" | timeout 20 bash "$APP" 2>&1
}

# Prepares state for a run_app test by evaluating $1 with the app loaded in
# a subshell, then clears the mock call log.
seed() { # shell-code
    ( load_app && eval "$1" ) >/dev/null 2>&1
    : > "$MOCK_LOG"
}

# Runs the app with bounded time and output size, for input that may make it
# loop. Output goes to /tmp/bounded.out; returns the app's exit status
# (124 = timeout, 153 = output limit hit).
run_app_bounded() { # input seconds
    (
        ulimit -f 4096
        printf '%b' "$1" | timeout "$2" bash "$APP" > /tmp/bounded.out 2>&1
    )
}

# Self-signed cert with a custom lifetime under /etc/letsencrypt/live/<name>.
create_cert() { # name days
    mkdir -p "/etc/letsencrypt/live/$1"
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -days "$2" -subj "/CN=$1" -addext "subjectAltName=DNS:*.$1,DNS:$1" \
        -keyout "/etc/letsencrypt/live/$1/privkey.pem" \
        -out "/etc/letsencrypt/live/$1/fullchain.pem" >/dev/null 2>&1
}

# Creates a site through the application's own functions (app must be loaded).
new_site() { # name tls [domain] [backend]
    local name="$1" tls="$2"
    db_save "$name" "${3:-$name.lan.example.com}" "${4:-127.0.0.1:8080}" "$tls" false >/dev/null 2>&1
    generate_site "$name" >/dev/null 2>&1
}
