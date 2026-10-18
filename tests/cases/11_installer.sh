#!/bin/bash
# install.sh in isolation: apt-get and curl are mocked, the "download" is a
# local file chosen via MOCK_CURL_FILE. No network is used.
# The served file is the tools/bundle.sh output, as hosted on the gist.

INSTALLER=/src/install.sh
TARGET=/usr/local/bin/nginx-manager
BUNDLE=/tmp/nm-install-bundle.sh
INSTALL_TMP=/tmp/nm-install-tmp   # TMPDIR for the installer: must end up empty

run_installer() { # file-to-serve [installer args...]
    local file="$1"
    shift
    build_bundle "$BUNDLE"
    use_mock curl
    rm -rf "$INSTALL_TMP"; mkdir -p "$INSTALL_TMP"
    MOCK_CURL_FILE="$file" TMPDIR="$INSTALL_TMP" timeout 30 bash "$INSTALLER" "$@" 2>&1
}

assert_temp_cleaned() {
    assert_eq "" "$(ls -A "$INSTALL_TMP")" "temp directory removed"
}

t_fresh_install() {
    local out rc
    out=$(run_installer "$BUNDLE"); rc=$?
    assert_eq 0 "$rc" "installer exits 0"
    assert_contains "$out" "Installation completed successfully" "success message"
    assert_eq "$(sha256sum < "$BUNDLE")" "$(sha256sum < "$TARGET")" "installed file identical to source"
    assert_mode "$TARGET" 755
    assert_temp_cleaned
    assert_no_file /tmp/nginx-manager.sh "fixed temp path not used"
    assert_called "curl -fsSL https://gist.githubusercontent.com/Bart0llo/e746ec66324473d20a72f13588f9d3b3/raw/nginx-site.sh -o $INSTALL_TMP/" \
        "downloads from the gist into a private temp directory"
    assert_called "apt-get update" "apt-get update"
}

# D10: certbot and the Cloudflare plugin are optional (TLS Manager can add
# them later); --with-certbot or NM_WITH_CERTBOT=1 installs them up front.
t_certbot_optional() {
    local out
    out=$(run_installer "$BUNDLE")
    assert_called "apt-get install -y curl jq nginx openssl" "core packages"
    assert_not_called "certbot" "certbot not installed by default"
    assert_contains "$out" "--with-certbot" "says how to get certbot"

    : > "$MOCK_LOG"
    run_installer "$BUNDLE" --with-certbot >/dev/null
    assert_called "apt-get install -y curl jq nginx openssl certbot python3-certbot-dns-cloudflare" "--with-certbot adds certbot"

    : > "$MOCK_LOG"
    NM_WITH_CERTBOT=1 run_installer "$BUNDLE" >/dev/null
    assert_called "apt-get install -y curl jq nginx openssl certbot python3-certbot-dns-cloudflare" "NM_WITH_CERTBOT=1 adds certbot"
}

t_unknown_option_rejected() {
    echo old > "$TARGET"
    local out rc
    out=$(run_installer "$BUNDLE" --bogus); rc=$?
    assert_eq 1 "$rc" "exits 1"
    assert_contains "$out" "Unknown option: --bogus" "reason shown"
    assert_not_called "apt-get" "nothing installed"
    assert_eq old "$(cat "$TARGET")" "existing install untouched"
}

t_installed_app_runs() {
    run_installer "$BUNDLE" >/dev/null
    fixture_configured
    local out rc
    out=$(printf 'q\n' | timeout 20 "$TARGET" 2>&1); rc=$?
    assert_eq 0 "$rc" "installed nginx-manager starts and quits"
    assert_contains "$out" "NGINX MANAGER PRO" "shows the dashboard"
}

t_update_preserves_data() {
    fixture_configured; fixture_sites_v3; fixture_cloudflare
    mkdir -p "$MANAGER_DIR/backups"; echo old > "$MANAGER_DIR/backups/app.conf_1.bak"
    echo "#!/bin/bash
echo old version" > "$TARGET"; chmod 755 "$TARGET"
    local before
    before=$(cd "$MANAGER_DIR" && find . -type f -exec sha256sum {} + | sort)
    run_installer "$BUNDLE" >/dev/null
    assert_eq 0 $? "update exits 0"
    assert_eq "$before" "$(cd "$MANAGER_DIR" && find . -type f -exec sha256sum {} + | sort)" \
        "config, sites.json, secrets and backups untouched"
    assert_eq "$(sha256sum < "$BUNDLE")" "$(sha256sum < "$TARGET")" "binary replaced"
}

t_download_failure() {
    echo old > "$TARGET"
    mock_rc curl 22
    local out rc
    out=$(run_installer "$BUNDLE"); rc=$?
    assert_eq 22 "$rc" "installer fails with curl's status"
    assert_not_contains "$out" "Installation completed" "no success message"
    assert_eq old "$(cat "$TARGET")" "existing install untouched"
    assert_temp_cleaned
}

t_invalid_syntax_rejected() {
    echo old > "$TARGET"
    printf '#!/bin/bash\nif then fi\n' > /tmp/broken-download.sh
    local out rc
    out=$(run_installer /tmp/broken-download.sh); rc=$?
    rm -f /tmp/broken-download.sh
    assert_eq 1 "$rc" "installer exits 1"
    assert_contains "$out" "downloaded script has invalid Bash syntax" "reason shown"
    assert_eq old "$(cat "$TARGET")" "existing install untouched"
    assert_temp_cleaned
}

t_apt_failure_aborts() {
    mock_rc apt-get-install 100
    local out rc
    out=$(run_installer "$BUNDLE"); rc=$?
    assert_eq 100 "$rc" "installer aborts (set -e)"
    assert_no_file "$TARGET" "nothing installed"
    assert_temp_cleaned
}

t_requires_root() {
    local out rc
    out=$(setpriv --reuid=65534 --regid=65534 --clear-groups bash "$INSTALLER" 2>&1); rc=$?
    assert_eq 1 "$rc" "exits 1"
    assert_contains "$out" "Please run this installer with sudo." "message"
}

# D10: the old fixed /tmp/nginx-manager.sh could be pre-planted (e.g. as a
# symlink) by another local user; a private mktemp -d directory cannot.
t_planted_temp_path_ignored() {
    echo keep > /etc/victim.conf
    ln -s /etc/victim.conf /tmp/nginx-manager.sh
    run_installer "$BUNDLE" >/dev/null
    assert_eq 0 $? "installer exits 0"
    assert_eq keep "$(cat /etc/victim.conf)" "symlink target not overwritten"
    assert_eq "$(sha256sum < "$BUNDLE")" "$(sha256sum < "$TARGET")" "installed the real download"
}

# D10: with NM_SHA256 (an expected hash obtained from a trusted channel,
# not from the gist) the download is verified before it is installed.
# Without it the installer says plainly that nothing was verified.
t_download_checksum() {
    build_bundle "$BUNDLE"
    local sum out rc
    sum=$(sha256sum "$BUNDLE" | cut -d' ' -f1)

    out=$(run_installer "$BUNDLE"); rc=$?
    assert_eq 0 "$rc" "no checksum given: installs"
    assert_contains "$out" "not verified against a checksum" "says it is unverified"
    assert_not_contains "$out" "Checksum verified" "no authenticity claimed"

    out=$(NM_SHA256="${sum^^}" run_installer "$BUNDLE"); rc=$?
    assert_eq 0 "$rc" "matching checksum: installs"
    assert_contains "$out" "Checksum verified" "verification reported"

    echo old > "$TARGET"
    out=$(NM_SHA256="$(printf '0%.0s' {1..64})" run_installer "$BUNDLE"); rc=$?
    assert_eq 1 "$rc" "mismatch: exits 1"
    assert_contains "$out" "checksum mismatch" "mismatch reported"
    assert_eq old "$(cat "$TARGET")" "existing install untouched"
    assert_temp_cleaned

    out=$(NM_SHA256=abc run_installer "$BUNDLE"); rc=$?
    assert_eq 1 "$rc" "malformed checksum: exits 1"
    assert_contains "$out" "NM_SHA256 must be 64 hex characters" "reason shown"
    assert_eq old "$(cat "$TARGET")" "existing install untouched"
}
