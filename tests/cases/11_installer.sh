#!/bin/bash
# install.sh in isolation. apt-get and curl (public GitHub: the releases
# API and the release download URLs) are mocked; releases are built with
# tools/release.sh and served from /tmp/mock-gh, so no network is used.
# See tests/mocks/curl.

INSTALLER=/src/install.sh
TARGET=/usr/local/bin/nginx-manager
LIB=/usr/local/lib/nginx-manager
PREVIOUS=$LIB/nginx-manager.previous
BUNDLE=/tmp/nm-install-bundle.sh
INSTALL_TMP=/tmp/nm-install-tmp   # TMPDIR for the installer: must end up empty
REPO=acme/nginx-manager
REL=/tmp/nm-release
API=/tmp/mock-gh/api/repos/$REPO/releases
DL=/tmp/mock-gh/web/$REPO/releases/download

run_installer() { # [installer args...]
    use_mock curl
    rm -rf "$INSTALL_TMP"; mkdir -p "$INSTALL_TMP"
    TMPDIR="$INSTALL_TMP" timeout 30 bash "$INSTALLER" "$@" </dev/null 2>&1
}

# Serves the files in <dir> as public release <tag>: release data from the
# API, files from the download URLs. "latest" also makes it the latest.
serve() { # tag dir [latest]
    local tag="$1" dir="$2" name assets=()
    mkdir -p "$API/tags" "$DL/$tag"
    for name in nginx-site.sh install.sh SHA256SUMS; do
        [[ -f "$dir/$name" ]] || continue
        cp "$dir/$name" "$DL/$tag/"
        assets+=("{\"name\":\"$name\"}")
    done
    local IFS=,
    printf '{"tag_name":"%s","assets":[%s]}\n' "$tag" "${assets[*]}" > "$API/tags/$tag"
    if [[ "${3:-}" == latest ]]; then
        cp "$API/tags/$tag" "$API/latest"
    fi
}

# Builds release <tag> with tools/release.sh into $REL/<tag> and serves it.
publish() { # tag [latest]
    bash /src/tools/release.sh "$1" "$REPO" "$REL/$1" >/dev/null || fail "release.sh $1 failed"
    serve "$1" "$REL/$1" "${2:-}"
}

# Release v4.0.0 as the latest.
with_release() {
    publish v4.0.0 latest
    export NM_REPO="$REPO"
}

same_file() { # expected actual message
    assert_eq "$(sha256sum < "$1")" "$(sha256sum < "$2" 2>/dev/null)" "$3"
}

assert_temp_cleaned() {
    assert_eq "" "$(ls -A "$INSTALL_TMP")" "temp directory removed"
}

assert_no_leftovers() {
    assert_eq "" "$(ls -A /usr/local/bin "$LIB" 2>/dev/null | grep -E '^\.(nginx-manager\.new|previous)\.')" \
        "no staging files left"
}

# Everything an update must not touch, with modes and owners.
snapshot() {
    (cd / && find etc/nginx-manager usr/local/lib/nginx-manager/plugins -printf '%m %u %p\n' | sort &&
        find etc/nginx-manager usr/local/lib/nginx-manager/plugins -type f -exec sha256sum {} + | sort)
}

as_nobody() { setpriv --reuid=65534 --regid=65534 --clear-groups "$@"; }

# ==========================================================
# INSTALL
# ==========================================================
t_fresh_install() {
    with_release
    local out rc
    out=$(run_installer); rc=$?
    assert_eq 0 "$rc" "installer exits 0"
    assert_contains "$out" "Installation completed successfully" "success message"
    assert_contains "$out" "Downloaded release v4.0.0 of $REPO." "release named"
    assert_contains "$out" "SHA-256 matches SHA256SUMS" "checksum verified"
    assert_contains "$out" "does not prove who published the release" "no authenticity claimed"
    assert_contains "$out" "Installed version v4.0.0 as $TARGET" "version reported"
    same_file "$REL/v4.0.0/nginx-site.sh" "$TARGET" "installed file identical to the release asset"
    assert_mode "$TARGET" 755
    assert_mode "$LIB" 755
    assert_mode "$LIB/plugins" 755
    assert_eq "" "$(ls -A "$LIB/plugins")" "plugin directory created, no plugins installed"
    assert_no_file "$PREVIOUS" "nothing to keep on a fresh install"
    assert_temp_cleaned
    assert_no_leftovers
    assert_no_file /tmp/nginx-manager.sh "fixed temp path not used"
    assert_called "https://api.github.com/repos/$REPO/releases/latest" "latest release resolved through the API"
    assert_called "https://github.com/$REPO/releases/download/v4.0.0/nginx-site.sh" "bundle from the release download URL"
    assert_called "https://github.com/$REPO/releases/download/v4.0.0/SHA256SUMS" "checksums from the release download URL"
    assert_eq 3 "$(grep -c '^curl ' "$MOCK_LOG")" "three requests (one API call)"
    assert_called "--proto =https --proto-redir =https" "HTTPS only, also after redirects"
    assert_not_called "gist.githubusercontent.com" "no gist download"
    assert_not_called "credentials" "no credentials sent"
    assert_called "apt-get update" "apt-get update"
}

t_local_bundle_install() {
    build_bundle "$BUNDLE"
    local out rc
    out=$(run_installer --bundle "$BUNDLE"); rc=$?
    assert_eq 0 "$rc" "local bundle installs"
    assert_contains "$out" "Local bundle: $BUNDLE" "source named"
    assert_contains "$out" "not verified against a checksum" "says it is unverified"
    assert_contains "$out" "Installed version dev" "checkout build is version dev"
    same_file "$BUNDLE" "$TARGET" "installed file identical to the bundle"
    assert_not_called "curl -sS" "nothing downloaded"

    publish v4.0.0
    out=$(run_installer --bundle "$REL/v4.0.0/nginx-site.sh" --sha256sums "$REL/v4.0.0/SHA256SUMS"); rc=$?
    assert_eq 0 "$rc" "downloaded release files install"
    assert_contains "$out" "SHA-256 matches SHA256SUMS" "verified against SHA256SUMS"
    assert_contains "$out" "Updated dev -> v4.0.0." "update reported"

    out=$(run_installer --bundle "$BUNDLE" --sha256sums "$REL/v4.0.0/SHA256SUMS"); rc=$?
    assert_eq 1 "$rc" "bundle not matching SHA256SUMS: exits 1"
    assert_contains "$out" "checksum mismatch against SHA256SUMS" "mismatch reported"
    same_file "$REL/v4.0.0/nginx-site.sh" "$TARGET" "installed version kept"

    out=$(run_installer --sha256sums "$REL/v4.0.0/SHA256SUMS"); rc=$?
    assert_eq 1 "$rc" "--sha256sums without --bundle: exits 1"
    assert_contains "$out" "--sha256sums only applies to --bundle" "reason shown"
}

# D10: certbot and the Cloudflare plugin are optional (TLS Manager can add
# them later); --with-certbot or NM_WITH_CERTBOT=1 installs them up front.
t_certbot_optional() {
    with_release
    local out
    out=$(run_installer)
    assert_called "apt-get install -y curl jq nginx openssl" "core packages"
    assert_not_called "certbot" "certbot not installed by default"
    assert_contains "$out" "--with-certbot" "says how to get certbot"

    : > "$MOCK_LOG"
    run_installer --with-certbot >/dev/null
    assert_called "apt-get install -y curl jq nginx openssl certbot python3-certbot-dns-cloudflare" "--with-certbot adds certbot"

    : > "$MOCK_LOG"
    NM_WITH_CERTBOT=1 run_installer >/dev/null
    assert_called "apt-get install -y curl jq nginx openssl certbot python3-certbot-dns-cloudflare" "NM_WITH_CERTBOT=1 adds certbot"
}

t_unknown_option_rejected() {
    echo old > "$TARGET"
    local out rc
    out=$(run_installer --bogus); rc=$?
    assert_eq 1 "$rc" "exits 1"
    assert_contains "$out" "Unknown option: --bogus" "reason shown"
    assert_not_called "apt-get" "nothing installed"
    assert_eq old "$(cat "$TARGET")" "existing install untouched"

    out=$(run_installer --release); rc=$?
    assert_eq 1 "$rc" "option without its value: exits 1"
    assert_contains "$out" "Option --release needs a value" "reason shown"
}

t_installed_app_runs() {
    with_release
    run_installer >/dev/null
    fixture_configured
    local out rc
    out=$(printf 'q\n' | timeout 20 "$TARGET" 2>&1); rc=$?
    assert_eq 0 "$rc" "installed nginx-manager starts and quits"
    assert_contains "$out" "NGINX Manager Pro" "shows the dashboard"
    out=$(as_nobody "$TARGET" --version 2>&1); rc=$?
    assert_eq 0 "$rc" "--version works without root"
    assert_eq "nginx-manager v4.0.0" "$out" "--version shows the release"
}

t_repeated_install() {
    with_release
    run_installer >/dev/null
    local inode out rc
    inode=$(stat -c %i "$TARGET")
    out=$(run_installer); rc=$?
    assert_eq 0 "$rc" "rerun exits 0"
    assert_contains "$out" "Version v4.0.0 was already installed; nothing was replaced." "rerun reported"
    assert_eq "$inode" "$(stat -c %i "$TARGET")" "file not rewritten"
    assert_no_file "$PREVIOUS" "no previous copy of the same version"
    assert_temp_cleaned
}

# ==========================================================
# UPDATE
# ==========================================================
t_update_preserves_data() {
    with_release
    run_installer >/dev/null
    fixture_configured; fixture_sites_v3; fixture_cloudflare
    mkdir -p "$MANAGER_DIR/backups"; echo old > "$MANAGER_DIR/backups/app.conf_1.bak"
    cp -r /src/plugins/example "$LIB/plugins/example"
    echo example > "$MANAGER_DIR/plugins.enabled"
    mkdir -p "$MANAGER_DIR/plugins"; echo "GREETING=hi" > "$MANAGER_DIR/plugins/example.conf"
    mkdir -p -m 700 "$MANAGER_DIR/secrets/example"
    (umask 077; echo secret > "$MANAGER_DIR/secrets/example/key")
    local before out rc
    before=$(snapshot)

    publish v4.1.0 latest
    out=$(run_installer); rc=$?
    assert_eq 0 "$rc" "update exits 0"
    assert_contains "$out" "Updated v4.0.0 -> v4.1.0." "versions reported"
    assert_contains "$out" "The replaced version is saved as $PREVIOUS" "previous copy reported"
    assert_eq "$before" "$(snapshot)" \
        "config, sites, secrets, backups, plugins, plugin settings and enabled list untouched (content and modes)"
    same_file "$REL/v4.1.0/nginx-site.sh" "$TARGET" "new version installed"
    same_file "$REL/v4.0.0/nginx-site.sh" "$PREVIOUS" "old version kept"
    assert_mode "$PREVIOUS" 755
    assert_mode "$TARGET" 755
    assert_no_leftovers
}

# The new file is renamed over the old one, never written into it: a
# manager that is running (bash reads its script as it goes) keeps reading
# the complete old version.
t_running_manager_keeps_old_file() {
    with_release
    run_installer >/dev/null
    publish v4.1.0 latest
    exec 4< "$TARGET"
    run_installer >/dev/null
    assert_eq "$(sha256sum < "$REL/v4.0.0/nginx-site.sh")" "$(sha256sum <&4)" "an open handle still reads the old version"
    exec 4<&-
    same_file "$REL/v4.1.0/nginx-site.sh" "$TARGET" "new version installed"
}

t_update_from_unversioned_install() {
    with_release
    printf '#!/bin/bash\necho old version\n' > "$TARGET"; chmod 755 "$TARGET"
    local out rc
    out=$(run_installer); rc=$?
    assert_eq 0 "$rc" "update exits 0"
    assert_contains "$out" "Updated unknown (installed before versioned releases) -> v4.0.0." "old install has no version"
    assert_eq "echo old version" "$(tail -n 1 "$PREVIOUS")" "gist-era version kept"
}

t_specific_release() {
    with_release
    publish v4.1.0 latest
    local out rc
    out=$(run_installer --release v4.0.0); rc=$?
    assert_eq 0 "$rc" "--release installs that release"
    assert_called "https://api.github.com/repos/$REPO/releases/tags/v4.0.0" "release looked up by tag"
    same_file "$REL/v4.0.0/nginx-site.sh" "$TARGET" "older release installed"

    out=$(run_installer --release v9.9.9); rc=$?
    assert_eq 1 "$rc" "unknown release: exits 1"
    assert_contains "$out" "release v9.9.9 of $REPO not found" "reason shown"
    same_file "$REL/v4.0.0/nginx-site.sh" "$TARGET" "installed version kept"

    out=$(run_installer --release ../x); rc=$?
    assert_eq 1 "$rc" "malformed tag: exits 1"
    assert_contains "$out" "invalid release tag" "reason shown"
}

t_release_installer_knows_repo() {
    with_release
    unset NM_REPO
    local out rc
    out=$(INSTALLER="$REL/v4.0.0/install.sh" run_installer); rc=$?
    assert_eq 0 "$rc" "release install.sh needs no --repo"
    assert_contains "$out" "Downloaded release v4.0.0 of $REPO" "uses its own repository"

    out=$(run_installer); rc=$?
    assert_eq 1 "$rc" "checkout install.sh without a repository: exits 1"
    assert_contains "$out" "no repository configured" "reason shown"
    out=$(run_installer --repo "not a repo"); rc=$?
    assert_contains "$out" "--repo must be OWNER/NAME" "malformed --repo rejected"
    out=$(run_installer --repo "$REPO"); rc=$?
    assert_eq 0 "$rc" "--repo works"
}

t_check() {
    with_release
    publish v4.1.0 latest
    local out rc
    out=$(run_installer --check); rc=$?
    assert_eq 0 "$rc" "--check exits 0"
    assert_contains "$out" "Installed: not installed" "nothing installed"
    assert_contains "$out" "Latest release of $REPO: v4.1.0" "latest shown"
    assert_contains "$out" "To install v4.1.0: sudo bash install.sh" "next step"
    assert_no_file "$TARGET" "--check installs nothing"
    assert_not_called "apt-get" "--check installs no packages"

    run_installer --release v4.0.0 >/dev/null
    rm -rf "$INSTALL_TMP"; mkdir -m 1777 "$INSTALL_TMP"
    chmod 666 "$MOCK_LOG"
    out=$(as_nobody env TMPDIR="$INSTALL_TMP" bash "$INSTALLER" --check </dev/null 2>&1); rc=$?
    assert_eq 0 "$rc" "--check works without root"
    assert_contains "$out" "Installed: v4.0.0" "installed version read"
    assert_contains "$out" "To install v4.1.0" "update offered"
    same_file "$REL/v4.0.0/nginx-site.sh" "$TARGET" "--check changes nothing"

    run_installer >/dev/null
    out=$(run_installer --check)
    assert_contains "$out" "Up to date." "up to date"
    out=$(run_installer --check --release v4.0.0)
    assert_contains "$out" "The installed version is newer than v4.0.0." "older release recognised"
}

# ==========================================================
# PUBLIC GITHUB: NO CREDENTIALS, NO gh
# ==========================================================
# Credentials in the environment and a gh binary are both ignored.
t_no_credentials_or_gh() {
    with_release
    assert_eq "" "$(command -v gh)" "no gh in the test image"
    printf '#!/bin/bash\necho "gh $*" >> /tmp/mock-calls.log\nexit 1\n' > "$MOCK_BIN/gh"
    chmod 755 "$MOCK_BIN/gh"
    local out rc
    out=$(GH_TOKEN=ghp_mockToken GITHUB_TOKEN=ghp_mockToken run_installer); rc=$?
    assert_eq 0 "$rc" "installs"
    out+=$(GH_TOKEN=ghp_mockToken run_installer --check); rc=$?
    assert_eq 0 "$rc" "--check works"
    assert_not_called "gh " "gh never run"
    assert_not_called "credentials" "no credentials sent"
    assert_not_called "ghp_mockToken" "token from the environment not used"
    assert_not_contains "$out" "token" "no mention of tokens"
    same_file "$REL/v4.0.0/nginx-site.sh" "$TARGET" "release installed"
}

# curl must not read ~/.curlrc (root's, or the user's when sudo keeps
# HOME): an "insecure" or "header" line there would undo the HTTPS-only,
# no-credentials guarantees. -q only has that effect as the first argument.
t_curl_ignores_curlrc() {
    with_release
    publish v4.1.0
    run_installer >/dev/null
    run_installer --check >/dev/null
    run_installer --release v4.1.0 >/dev/null
    local calls
    calls=$(grep -c '^curl ' "$MOCK_LOG")
    assert_eq 7 "$calls" "install, --check and update made 7 requests"
    assert_eq "$calls" "$(grep -c '^curl -q ' "$MOCK_LOG")" "every curl call starts with -q"
    # curl as a command: at the start of a line, after $( or after a pipe.
    local cmds
    cmds=$(grep -oE '(^[[:space:]]*|\$\(|\|[[:space:]]*)curl [^ ]+' "$INSTALLER" | sed 's/^.*curl /curl /')
    assert_eq "curl -q" "$cmds" "install.sh runs curl in one place, with -q first"
}

# The install.sh asset of a release knows its repository and works piped
# into bash (curl ... | sudo bash -s -- ARGS), even when a command it runs
# (here apt-get) reads all of stdin.
t_piped_install() {
    with_release
    unset NM_REPO
    printf '#!/bin/bash\necho "apt-get $*" >> /tmp/mock-calls.log\ncat > /dev/null\n' > "$MOCK_BIN/apt-get"
    chmod 755 "$MOCK_BIN/apt-get"
    use_mock curl
    rm -rf "$INSTALL_TMP"; mkdir -p "$INSTALL_TMP"
    local out rc
    out=$(cat "$DL/v4.0.0/install.sh" | TMPDIR="$INSTALL_TMP" timeout 30 bash -s -- --release v4.0.0 2>&1); rc=$?
    assert_eq 0 "$rc" "piped install exits 0"
    assert_contains "$out" "Installation completed successfully" "success message"
    assert_called "apt-get install -y curl jq nginx openssl" "packages installed"
    same_file "$REL/v4.0.0/nginx-site.sh" "$TARGET" "release installed"
    assert_temp_cleaned
}

t_rate_limited() {
    with_release
    echo old > "$TARGET"
    echo 403 > /tmp/mock-gh/status
    printf '%s\n' "x-ratelimit-limit: 60" "x-ratelimit-remaining: 0" > /tmp/mock-gh/headers
    local out rc
    out=$(run_installer); rc=$?
    assert_eq 1 "$rc" "exits 1"
    assert_contains "$out" "API rate limit for requests without credentials is used up (60 per hour per IP address)" "rate limit named"
    assert_contains "$out" "use --bundle" "way out shown"
    assert_not_contains "$out" "Installation completed" "no success message"
    assert_eq old "$(cat "$TARGET")" "existing install untouched"
    assert_temp_cleaned

    chmod 666 "$MOCK_LOG"
    out=$(as_nobody env TMPDIR=/tmp bash "$INSTALLER" --check </dev/null 2>&1); rc=$?
    assert_eq 1 "$rc" "--check: exits 1"
    assert_contains "$out" "rate limit" "--check: rate limit named"

    echo 429 > /tmp/mock-gh/status
    out=$(run_installer --check); rc=$?
    assert_contains "$out" "rate limit" "429 with no requests left: rate limit"

    printf '%s\n' "x-ratelimit-remaining: 42" > /tmp/mock-gh/headers
    echo 403 > /tmp/mock-gh/status
    out=$(run_installer --check); rc=$?
    assert_eq 1 "$rc" "other 403: exits 1"
    assert_contains "$out" "GitHub refused the request for release latest of $REPO (HTTP 403)" "plain 403 reported"
    assert_not_contains "$out" "rate limit" "not called a rate limit"
}

t_http_and_network_errors() {
    with_release
    echo old > "$TARGET"
    local out rc
    echo 502 > /tmp/mock-gh/status
    out=$(run_installer); rc=$?
    assert_eq 1 "$rc" "HTTP 502: exits 1"
    assert_contains "$out" "GitHub answered HTTP 502 for release latest of $REPO" "status reported"
    rm /tmp/mock-gh/status

    mock_rc curl 6
    out=$(run_installer); rc=$?
    assert_eq 6 "$rc" "network failure: exits with curl's status"
    assert_contains "$out" "could not download release latest of $REPO from GitHub (curl exit status 6; network or DNS problem?)" "reason shown"
    out=$(run_installer --check); rc=$?
    assert_eq 6 "$rc" "--check network failure: exits with curl's status"
    assert_not_contains "$out" "Up to date" "no version claimed"
    assert_eq old "$(cat "$TARGET")" "existing install untouched"
    assert_temp_cleaned
}

t_missing_release_or_repository() {
    with_release
    local out rc
    out=$(NM_REPO=acme/other run_installer); rc=$?
    assert_eq 1 "$rc" "unknown or private repository: exits 1"
    assert_contains "$out" "release latest of acme/other not found (does acme/other exist, is it public, and does the release exist?)" "reason shown"

    rm "$API/latest"
    out=$(run_installer --check); rc=$?
    assert_eq 1 "$rc" "no release published: --check exits 1"
    assert_contains "$out" "release latest of $REPO not found" "reason shown"
    assert_no_file "$TARGET" "nothing installed"
}

t_malformed_release_data() {
    with_release
    echo old > "$TARGET"
    local body out rc n=0
    for body in 'not json' '[]' '{"message":"x"}' '{"tag_name":5}' '{"tag_name":"../../x"}'; do
        n=$((n + 1))
        printf '%s\n' "$body" > "$API/latest"
        out=$(run_installer); rc=$?
        assert_eq 1 "$rc" "response $n: exits 1"
        assert_contains "$out" "unexpected" "response $n: reported as unexpected"
        assert_not_called "releases/download" "response $n: nothing downloaded"
        out=$(run_installer --check); rc=$?
        assert_eq 1 "$rc" "response $n: --check exits 1"
    done
    publish v4.1.0
    cp "$API/tags/v4.1.0" "$API/tags/v4.0.0"
    out=$(run_installer --release v4.0.0); rc=$?
    assert_eq 1 "$rc" "different tag than requested: exits 1"
    assert_contains "$out" "GitHub returned release v4.1.0 for v4.0.0" "reason shown"
    assert_eq old "$(cat "$TARGET")" "existing install untouched"
}

# The release lists the asset, but its download fails.
t_asset_download_fails() {
    with_release
    echo old > "$TARGET"
    rm "$DL/v4.0.0/SHA256SUMS"
    local out rc
    out=$(run_installer); rc=$?
    assert_eq 1 "$rc" "exits 1"
    assert_contains "$out" "SHA256SUMS of v4.0.0 not found" "reason shown"
    assert_eq old "$(cat "$TARGET")" "existing install untouched"
    assert_temp_cleaned
}

# ==========================================================
# VERIFICATION
# ==========================================================
t_invalid_bundles_rejected() {
    build_bundle "$BUNDLE"
    local d=$REL/bad c out rc
    mkdir -p "$d"
    : > "$d/empty"
    tail -n +2 "$BUNDLE" > "$d/noshebang"
    printf '#!/bin/bash\nif then fi\n' > "$d/syntax"
    cp /src/nginx-site.sh "$d/modular"
    head -n -1 "$BUNDLE" > "$d/truncated"
    grep -vx '# @nm-module tls.sh' "$BUNDLE" > "$d/nomodule"
    grep -v '^NM_VERSION=' "$BUNDLE" > "$d/noversion"
    local -A expect=(
        [empty]="the bundle is empty"
        [noshebang]="the first line is not #!/bin/bash"
        [syntax]="the bundle has invalid Bash syntax"
        [modular]="this is nginx-site.sh from a checkout"
        [truncated]="the bundle is incomplete (no end marker; truncated download?)"
        [nomodule]="the bundle is incomplete (module tls.sh missing)"
        [noversion]="the bundle has no version line"
    )
    echo old > "$TARGET"
    for c in empty noshebang syntax modular truncated nomodule noversion; do
        out=$(run_installer --no-deps --bundle "$d/$c"); rc=$?
        assert_eq 1 "$rc" "$c: exits 1"
        assert_contains "$out" "${expect[$c]}" "$c: reason shown"
        assert_not_contains "$out" "Installation completed" "$c: no success message"
        assert_eq old "$(cat "$TARGET")" "$c: existing install untouched"
        assert_temp_cleaned
    done
    assert_no_file "$PREVIOUS" "nothing saved as previous"
    assert_no_leftovers
}

t_corrupt_release_rejected() {
    with_release
    run_installer >/dev/null
    local out rc dir=$REL/v4.0.1
    publish v4.1.0 latest
    echo "# tampered" >> "$DL/v4.1.0/nginx-site.sh"
    out=$(run_installer); rc=$?
    assert_eq 1 "$rc" "damaged download: exits 1"
    assert_contains "$out" "checksum mismatch against SHA256SUMS" "mismatch reported"
    same_file "$REL/v4.0.0/nginx-site.sh" "$TARGET" "installed version kept"

    # A truncated bundle published with a matching checksum.
    bash /src/tools/release.sh v4.0.1 "$REPO" "$dir" >/dev/null
    head -n -1 "$dir/nginx-site.sh" > "$dir/cut" && mv "$dir/cut" "$dir/nginx-site.sh"
    (cd "$dir" && sha256sum nginx-site.sh install.sh > SHA256SUMS)
    serve v4.0.1 "$dir" latest
    out=$(run_installer); rc=$?
    assert_eq 1 "$rc" "incomplete release: exits 1"
    assert_contains "$out" "no end marker" "reason shown"
    same_file "$REL/v4.0.0/nginx-site.sh" "$TARGET" "installed version kept"
    assert_temp_cleaned
    assert_no_leftovers
}

t_release_version_mismatch() {
    with_release
    bash /src/tools/release.sh v4.1.0 "$REPO" "$REL/mislabelled" >/dev/null
    serve v4.2.0 "$REL/mislabelled" latest
    local out rc
    out=$(run_installer); rc=$?
    assert_eq 1 "$rc" "exits 1"
    assert_contains "$out" "the bundle says version v4.1.0, but release v4.2.0 was downloaded" "reason shown"
    assert_no_file "$TARGET" "nothing installed"
}

t_release_without_checksums() {
    with_release
    bash /src/tools/release.sh v4.1.0 "$REPO" "$REL/nosums" >/dev/null
    rm "$REL/nosums/SHA256SUMS"
    serve v4.1.0 "$REL/nosums" latest
    local out rc
    out=$(run_installer); rc=$?
    assert_eq 1 "$rc" "exits 1"
    assert_contains "$out" "release v4.1.0 has no SHA256SUMS asset; nothing installed" "reason shown"
    assert_not_called "releases/download" "nothing downloaded"
    assert_no_file "$TARGET" "unverified download not installed"
}

t_download_failure() {
    with_release
    echo old > "$TARGET"
    mock_rc curl 22
    local out rc
    out=$(run_installer); rc=$?
    assert_eq 22 "$rc" "installer fails with curl's status"
    assert_contains "$out" "curl exit status 22" "reason shown"
    assert_not_contains "$out" "Installation completed" "no success message"
    assert_eq old "$(cat "$TARGET")" "existing install untouched"
    assert_temp_cleaned
}

# D10, extended: NM_SHA256 is an expected hash from a channel the user
# trusts; it is checked in addition to the release's SHA256SUMS.
t_download_checksum() {
    build_bundle "$BUNDLE"
    local sum out rc
    sum=$(sha256sum "$BUNDLE" | cut -d' ' -f1)

    out=$(run_installer --bundle "$BUNDLE"); rc=$?
    assert_eq 0 "$rc" "no checksum given: installs"
    assert_contains "$out" "not verified against a checksum" "says it is unverified"
    assert_not_contains "$out" "Checksum verified" "no authenticity claimed"

    out=$(NM_SHA256="${sum^^}" run_installer --bundle "$BUNDLE"); rc=$?
    assert_eq 0 "$rc" "matching checksum: installs"
    assert_contains "$out" "Checksum verified" "verification reported"

    echo old > "$TARGET"
    out=$(NM_SHA256="$(printf '0%.0s' {1..64})" run_installer --bundle "$BUNDLE"); rc=$?
    assert_eq 1 "$rc" "mismatch: exits 1"
    assert_contains "$out" "checksum mismatch" "mismatch reported"
    assert_eq old "$(cat "$TARGET")" "existing install untouched"
    assert_temp_cleaned

    out=$(NM_SHA256=abc run_installer --bundle "$BUNDLE"); rc=$?
    assert_eq 1 "$rc" "malformed checksum: exits 1"
    assert_contains "$out" "NM_SHA256 must be 64 hex characters" "reason shown"
    assert_eq old "$(cat "$TARGET")" "existing install untouched"

    with_release
    sum=$(sha256sum "$REL/v4.0.0/nginx-site.sh" | cut -d' ' -f1)
    out=$(NM_SHA256="$sum" run_installer); rc=$?
    assert_eq 0 "$rc" "release with NM_SHA256: installs"
    assert_contains "$out" "SHA-256 matches SHA256SUMS" "release checksum checked"
    assert_contains "$out" "Checksum verified (SHA-256 matches NM_SHA256)" "trusted checksum checked too"
}

# ==========================================================
# FAILURES AND RECOVERY
# ==========================================================
t_apt_failure_aborts() {
    with_release
    mock_rc apt-get-install 100
    local out rc
    out=$(run_installer); rc=$?
    assert_eq 100 "$rc" "installer exits with apt-get's status"
    assert_contains "$out" "apt-get install failed" "reason shown"
    assert_no_file "$TARGET" "nothing installed"
    assert_temp_cleaned
}

t_no_deps() {
    build_bundle "$BUNDLE"
    local out rc
    out=$(run_installer --no-deps --bundle "$BUNDLE"); rc=$?
    assert_eq 0 "$rc" "--no-deps installs"
    assert_contains "$out" "Skipped (--no-deps)." "skip reported"
    assert_not_called "apt-get" "no packages installed"

    mv /usr/bin/jq /usr/bin/jq.off
    out=$(run_installer --no-deps --bundle "$BUNDLE"); rc=$?
    mv /usr/bin/jq.off /usr/bin/jq
    assert_eq 0 "$rc" "missing jq does not stop the install"
    assert_contains "$out" "nginx-manager needs jq to start (apt-get install jq)" "missing dependency named"

    out=$(run_installer --no-deps --with-certbot --bundle "$BUNDLE"); rc=$?
    assert_eq 1 "$rc" "--with-certbot with --no-deps: exits 1"
    assert_contains "$out" "--with-certbot installs packages" "reason shown"
}

t_noninteractive() {
    with_release
    local out rc
    # stdin is a FIFO that stays open but never delivers anything: a
    # prompt would hang until the timeout (exit 124).
    mkfifo "$REL/stdin"
    exec 3<>"$REL/stdin"
    use_mock curl
    rm -rf "$INSTALL_TMP"; mkdir -p "$INSTALL_TMP"
    out=$(TMPDIR="$INSTALL_TMP" timeout 20 bash "$INSTALLER" <&3 2>&1); rc=$?
    exec 3>&-
    assert_eq 0 "$rc" "completes without reading input"
    assert_called "apt-get install -y" "apt-get runs with -y"
}

t_failed_replacement_keeps_old() {
    with_release
    run_installer >/dev/null
    publish v4.1.0 latest
    cat > "$MOCK_BIN/mv" <<'EOF'
#!/bin/bash
for a; do last="$a"; done
[[ "$last" == /usr/local/bin/nginx-manager ]] && { echo "mv: simulated failure" >&2; exit 1; }
exec /usr/bin/mv "$@"
EOF
    chmod 755 "$MOCK_BIN/mv"
    local out rc
    out=$(run_installer); rc=$?
    assert_eq 1 "$rc" "exits 1"
    assert_contains "$out" "could not move the new version into place; $TARGET is unchanged" "reason shown"
    assert_not_contains "$out" "Installation completed" "no success message"
    same_file "$REL/v4.0.0/nginx-site.sh" "$TARGET" "installed version kept"
    assert_temp_cleaned
    assert_no_leftovers

    rm "$MOCK_BIN/mv"
    out=$(run_installer); rc=$?
    assert_eq 0 "$rc" "rerun after the failure succeeds"
    same_file "$REL/v4.1.0/nginx-site.sh" "$TARGET" "new version installed"
    same_file "$REL/v4.0.0/nginx-site.sh" "$PREVIOUS" "old version kept"
}

t_failed_previous_copy_keeps_old() {
    with_release
    run_installer >/dev/null
    publish v4.1.0 latest
    mkdir -p "$PREVIOUS/blocker"
    local out rc
    out=$(run_installer); rc=$?
    assert_eq 1 "$rc" "exits 1"
    assert_contains "$out" "could not save the current version as $PREVIOUS; $TARGET is unchanged" "reason shown"
    same_file "$REL/v4.0.0/nginx-site.sh" "$TARGET" "installed version kept"
    assert_no_leftovers
}

t_rollback() {
    with_release
    run_installer >/dev/null
    publish v4.1.0 latest
    run_installer >/dev/null
    : > "$MOCK_LOG"
    local out rc
    out=$(run_installer --rollback); rc=$?
    assert_eq 0 "$rc" "--rollback exits 0"
    assert_contains "$out" "Rolled back to v4.0.0." "reported"
    assert_contains "$out" "v4.1.0 is now saved as $PREVIOUS" "swap reported"
    same_file "$REL/v4.0.0/nginx-site.sh" "$TARGET" "previous version back in place"
    same_file "$REL/v4.1.0/nginx-site.sh" "$PREVIOUS" "replaced version kept"
    assert_mode "$TARGET" 755
    assert_not_called "curl -sS" "nothing downloaded"
    assert_not_called "apt-get" "no packages installed"

    out=$(run_installer --rollback); rc=$?
    assert_eq 0 "$rc" "second --rollback exits 0"
    same_file "$REL/v4.1.0/nginx-site.sh" "$TARGET" "second --rollback undoes the first"

    printf '#!/bin/bash\nif then\n' > "$PREVIOUS"
    out=$(run_installer --rollback); rc=$?
    assert_eq 1 "$rc" "damaged previous copy: exits 1"
    assert_contains "$out" "not valid Bash" "reason shown"
    same_file "$REL/v4.1.0/nginx-site.sh" "$TARGET" "installed version kept"

    rm "$PREVIOUS"
    out=$(run_installer --rollback); rc=$?
    assert_eq 1 "$rc" "nothing to roll back to: exits 1"
    assert_contains "$out" "no previous version is saved" "reason shown"
}

t_interrupted_download_cleans_up() {
    with_release
    run_installer >/dev/null
    publish v4.1.0 latest
    printf '%s\n' '[[ "$url" == */releases/download/* ]] && { touch /tmp/nm-release/started; sleep 20; }' > /tmp/mock-curl-hook
    rm -rf "$INSTALL_TMP"; mkdir -p "$INSTALL_TMP"
    TMPDIR="$INSTALL_TMP" setsid bash "$INSTALLER" </dev/null > "$REL/out" 2>&1 &
    local pid=$! i rc
    for i in {1..100}; do [[ -f "$REL/started" ]] && break; sleep 0.1; done
    kill -TERM -- "-$pid"
    wait "$pid"; rc=$?
    assert_eq 143 "$rc" "terminated installer exits 143"
    assert_contains "$(cat "$REL/out")" "Error: terminated" "interruption reported"
    assert_not_contains "$(cat "$REL/out")" "Installation completed" "no success message"
    same_file "$REL/v4.0.0/nginx-site.sh" "$TARGET" "installed version kept"
    assert_temp_cleaned
    assert_no_leftovers
}

# A killed run (SIGKILL, power loss) can leave its staging files behind;
# the next run removes them.
t_stale_files_removed() {
    with_release
    mkdir -p "$LIB"
    touch /usr/local/bin/.nginx-manager.new.AbC123 "$LIB/.previous.XyZ789"
    run_installer >/dev/null
    assert_no_file /usr/local/bin/.nginx-manager.new.AbC123 "stale staging file removed"
    assert_no_file "$LIB/.previous.XyZ789" "stale copy removed"
}

t_concurrent_install_refused() {
    with_release
    mkdir -p "$LIB"
    flock "$LIB/.install.lock" sleep 15 &
    local holder=$! i out rc
    for i in {1..50}; do flock -n "$LIB/.install.lock" true || break; sleep 0.1; done
    out=$(run_installer); rc=$?
    kill "$holder" 2>/dev/null
    assert_eq 1 "$rc" "exits 1"
    assert_contains "$out" "another install.sh is running" "reason shown"
    assert_no_file "$TARGET" "nothing installed"
}

t_symlink_target_refused() {
    with_release
    echo keep > "$REL/checkout.sh"
    ln -s "$REL/checkout.sh" "$TARGET"
    local out rc
    out=$(run_installer); rc=$?
    assert_eq 1 "$rc" "exits 1"
    assert_contains "$out" "$TARGET is a symbolic link" "reason shown"
    assert_symlink "$TARGET" "symlink kept"
    assert_eq keep "$(cat "$REL/checkout.sh")" "link target untouched"
}

# Installing below a temporary root needs no root privileges.
t_unprivileged_temp_root() {
    build_bundle "$BUNDLE"
    publish v4.0.0
    mkdir -p /tmp/nm-root/tmp
    chown -R 65534:65534 /tmp/nm-root
    chmod 644 "$BUNDLE"
    local out rc root=/tmp/nm-root
    run_root() { as_nobody env TMPDIR=$root/tmp NM_INSTALL_ROOT=$root timeout 30 bash "$INSTALLER" "$@" </dev/null 2>&1; }

    out=$(run_root --bundle "$BUNDLE"); rc=$?
    assert_eq 0 "$rc" "installs as an unprivileged user"
    assert_contains "$out" "Skipped (NM_INSTALL_ROOT is set)." "no packages"
    same_file "$BUNDLE" "$root/usr/local/bin/nginx-manager" "installed below the root"
    assert_mode "$root/usr/local/bin/nginx-manager" 755
    assert_mode "$root/usr/local/lib/nginx-manager/plugins" 755
    assert_no_file "$TARGET" "real path untouched"
    assert_not_called "apt-get" "no packages installed"
    assert_eq "" "$(ls -A $root/tmp)" "temp directory removed"

    chmod 555 "$root/usr/local/bin"
    out=$(run_root --bundle "$REL/v4.0.0/nginx-site.sh" --sha256sums "$REL/v4.0.0/SHA256SUMS"); rc=$?
    assert_eq 1 "$rc" "unwritable directory: exits 1"
    assert_contains "$out" "could not write the new version to $root/usr/local/bin; nothing changed" "reason shown"
    same_file "$BUNDLE" "$root/usr/local/bin/nginx-manager" "installed version kept"
    assert_no_file "$root/usr/local/lib/nginx-manager/nginx-manager.previous" "nothing saved"

    out=$(run_root --bundle "$BUNDLE" --with-certbot); rc=$?
    assert_eq 1 "$rc" "--with-certbot below a root: exits 1"
}

t_requires_root() {
    local out rc
    out=$(as_nobody bash "$INSTALLER" 2>&1); rc=$?
    assert_eq 1 "$rc" "exits 1"
    assert_contains "$out" "Please run this installer with sudo." "message"
    out=$(as_nobody bash "$INSTALLER" --help 2>&1); rc=$?
    assert_eq 0 "$rc" "--help works without root"
    assert_contains "$out" "Usage: install.sh [options]" "usage shown"
}

# D10: the old fixed /tmp/nginx-manager.sh could be pre-planted (e.g. as a
# symlink) by another local user; a private mktemp -d directory cannot.
t_planted_temp_path_ignored() {
    with_release
    echo keep > /etc/victim.conf
    ln -s /etc/victim.conf /tmp/nginx-manager.sh
    run_installer >/dev/null
    assert_eq 0 $? "installer exits 0"
    assert_eq keep "$(cat /etc/victim.conf)" "symlink target not overwritten"
    same_file "$REL/v4.0.0/nginx-site.sh" "$TARGET" "installed the real download"
}

# ==========================================================
# GUM AND PLUGINS
# ==========================================================
t_gum_optional() {
    with_release
    local out rc
    assert_eq "" "$(command -v gum)" "no gum in the test image"
    out=$(run_installer); rc=$?
    assert_eq 0 "$rc" "installs without gum"
    assert_contains "$out" "without it the" "fallback explained"
    assert_contains "$out" "built-in text menus are used" "fallback explained"
    assert_contains "$out" "never installs gum" "gum not installed"

    use_gum
    publish v4.1.0 latest
    out=$(run_installer); rc=$?
    assert_eq 0 "$rc" "installs with gum present"
    assert_eq "" "$(gum_calls)" "installer never runs gum"
}

t_installed_plugin_discovery() {
    with_release
    run_installer >/dev/null
    cp -r /src/plugins/example "$LIB/plugins/"
    local out
    out=$(NM_NO_MAIN=1 bash -c 'source "$1"; plugins_load
        echo "dir=$PLUGIN_DIR ids=${PLUGIN_IDS[*]} error=${PLUGIN_ERROR[example]:-none}"' _ "$TARGET" 2>&1)
    assert_eq "dir=$LIB/plugins ids=example error=none" "$out" "installed bundle finds plugins in $LIB/plugins"
}
