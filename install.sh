#!/bin/bash
# ==========================================================
# NGINX Manager Pro - installer and updater
#
#   sudo bash install.sh            install or update to the latest release
#   bash install.sh --check         compare the installed and latest version
#   bash install.sh --help          all options
#
# Installs /usr/local/bin/nginx-manager from a GitHub Release of the
# project's public repository (no credentials are used), or from a local
# bundle (--bundle). Nothing downloaded is executed: the bundle is checked
# (checksums, Bash syntax, structure, version) and then renamed into
# place, so the command is
# always either the old or the new file, never a partial one. The version
# it replaces is kept as /usr/local/lib/nginx-manager/nginx-manager.previous
# (--rollback puts it back).
#
# The installer never reads or writes /etc/nginx-manager (configuration,
# sites, secrets, backups, plugin settings) and never changes what is in
# the plugin directory. It never prompts, so it can run unattended.
# ==========================================================
set -uo pipefail   # no -e: every step checks and reports its own failure

# tools/release.sh sets this to the repository a release is published from.
NM_REPO_DEFAULT=""

# NM_INSTALL_ROOT installs below another directory instead of / (staging
# and tests): root is not required and no packages are installed.
ROOT="${NM_INSTALL_ROOT:-}"
BIN_DIR="$ROOT/usr/local/bin"
TARGET="$BIN_DIR/nginx-manager"
LIB_DIR="$ROOT/usr/local/lib/nginx-manager"
PLUGIN_DIR="$LIB_DIR/plugins"
PREVIOUS="$LIB_DIR/nginx-manager.previous"
LOCK_FILE="$LIB_DIR/.install.lock"
GITHUB_API="https://api.github.com"
GITHUB_WEB="https://github.com"
ASSET="nginx-site.sh"
SUMS_ASSET="SHA256SUMS"
TAG_RE='^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$'

MODE=install
REPO="${NM_REPO:-$NM_REPO_DEFAULT}"
RELEASE=""   # tag to install; empty: the latest release
BUNDLE="" SUMS_FILE=""
WITH_CERTBOT="${NM_WITH_CERTBOT:-0}"
INSTALL_DEPS=1
# NM_SHA256: expected SHA-256 of the bundle, taken from a channel you
# trust. Unlike SHA256SUMS, which comes from the same release as the
# bundle, it can show that the file is the one you meant to install.
EXPECTED_SHA256="${NM_SHA256:-}"

TMP_DIR="" STAGED="" PREV_TMP="" RELEASE_JSON=""
BUNDLE_VERSION="" REPLACED=""

say() { printf '%s\n' "$*"; }
err() { printf 'Error: %s\n' "$*" >&2; }
die() { err "$1"; exit "${2:-1}"; }

usage() {
    cat <<EOF
Usage: install.sh [options]

Installs or updates nginx-manager. Without --bundle it downloads a GitHub
Release of ${REPO:-OWNER/NAME} over HTTPS, without credentials. It never
prompts.

  --release TAG       install this release instead of the latest one
  --repo OWNER/NAME   repository to download from (also NM_REPO)
  --bundle FILE       install a local bundle; nothing is downloaded
  --sha256sums FILE   verify --bundle against this SHA256SUMS file
  --check             show the installed and the latest version; no changes
  --rollback          put back the version replaced by the last update
  --no-deps           do not install packages with apt-get
  --with-certbot      also install certbot and the Cloudflare DNS plugin
                      (also NM_WITH_CERTBOT=1)
  -h, --help          show this help
EOF
}

cleanup() {
    if [[ -n "$STAGED" ]]; then rm -f "$STAGED"; fi
    if [[ -n "$PREV_TMP" ]]; then rm -f "$PREV_TMP"; fi
    if [[ -n "$TMP_DIR" ]]; then rm -rf "$TMP_DIR"; fi
}
trap cleanup EXIT
trap 'echo >&2; err "interrupted"; exit 130' INT
trap 'err "terminated"; exit 143' TERM HUP

need() { # command...
    local c
    for c; do
        command -v "$c" >/dev/null 2>&1 || { err "$c is required (apt-get install $c)"; return 1; }
    done
}

# ==========================================================
# VERSIONS AND BUNDLE CHECKS (nothing here runs the bundle)
# ==========================================================
bundle_version() { # file
    local v
    v=$(sed -n 's/^NM_VERSION="\([A-Za-z0-9._+-]*\)"$/\1/p' "$1" 2>/dev/null)
    [[ -n "$v" && "$v" != *$'\n'* ]] && printf '%s\n' "$v"
}

installed_version() {
    if [[ ! -e "$TARGET" ]]; then
        echo "not installed"
    else
        bundle_version "$TARGET" || echo "unknown (installed before versioned releases)"
    fi
}

# vMAJOR.MINOR.PATCH $1 is later than $2.
newer() { # a b
    local re='^v[0-9]+\.[0-9]+\.[0-9]+$'
    [[ "$1" =~ $re && "$2" =~ $re && "$1" != "$2" ]] &&
        [[ "$(printf '%s\n' "$1" "$2" | sort -V | tail -n 1)" == "$1" ]]
}

# A complete bundle starts with #!/bin/bash, is valid Bash, contains every
# module its last line ("# @nm-bundle-end modules=...") lists, and has one
# NM_VERSION line. Sets BUNDLE_VERSION.
validate_bundle() { # file [expected-version]
    local file="$1" want="${2:-}" first last module
    BUNDLE_VERSION=""
    if [[ ! -s "$file" ]]; then
        err "the bundle is empty"
        return 1
    fi
    IFS= read -r first < "$file"
    if [[ "$first" != "#!/bin/bash" ]]; then
        err "not an nginx-manager bundle (the first line is not #!/bin/bash)"
        return 1
    fi
    if ! bash -n "$file" 2>/dev/null; then
        err "the bundle has invalid Bash syntax"
        return 1
    fi
    if grep -q 'NM_LIB_DIR' "$file"; then
        err "this is nginx-site.sh from a checkout, which needs its lib/ directory; build the bundle with tools/bundle.sh"
        return 1
    fi
    last=$(tail -n 1 "$file")
    if [[ ! "$last" =~ ^"# @nm-bundle-end modules="([a-z_. ]+)$ ]]; then
        err "the bundle is incomplete (no end marker; truncated download?)"
        return 1
    fi
    for module in ${BASH_REMATCH[1]}; do
        if [[ $(grep -cxF "# @nm-module $module" "$file") != 1 ]]; then
            err "the bundle is incomplete (module $module missing)"
            return 1
        fi
    done
    if ! BUNDLE_VERSION=$(bundle_version "$file"); then
        err "the bundle has no version line"
        return 1
    fi
    if [[ -n "$want" && "$BUNDLE_VERSION" != "$want" ]]; then
        err "the bundle says version $BUNDLE_VERSION, but release $want was downloaded"
        return 1
    fi
}

# Prints the hash listed for $ASSET in a sha256sum-format file; fails if
# there is no entry, more than one, or a malformed one.
sums_lookup() { # file
    local hash name found=""
    while read -r hash name; do
        name="${name#\*}"
        [[ "$name" == "$ASSET" ]] || continue
        [[ -z "$found" && "$hash" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
        found="${hash,,}"
    done < "$1"
    [[ -n "$found" ]] && echo "$found"
}

verify_checksums() { # file sums-file-or-empty
    local actual expected
    actual=$(sha256sum "$1" | cut -d' ' -f1)
    if [[ -n "$2" ]]; then
        if ! expected=$(sums_lookup "$2"); then
            err "$2 has no valid entry for $ASSET"
            return 1
        fi
        if [[ "$actual" != "$expected" ]]; then
            err "checksum mismatch against $SUMS_ASSET."
            say "  expected $expected" >&2
            say "  got      $actual" >&2
            return 1
        fi
        say "SHA-256 matches $SUMS_ASSET (this detects a damaged download; it does not prove who published the release)."
    fi
    if [[ -n "$EXPECTED_SHA256" ]]; then
        if [[ "$actual" != "${EXPECTED_SHA256,,}" ]]; then
            err "checksum mismatch."
            say "  expected $EXPECTED_SHA256" >&2
            say "  got      $actual" >&2
            return 1
        fi
        say "Checksum verified (SHA-256 matches NM_SHA256)."
    fi
    if [[ -z "$2" && -z "$EXPECTED_SHA256" ]]; then
        say "Note: the bundle is not verified against a checksum (use --sha256sums or NM_SHA256)."
    fi
}

# ==========================================================
# GITHUB
# ==========================================================
# GET <url> into <output> and print the HTTP status. No credentials are
# sent: the repository is public. Response headers go to <output>.headers
# (rate-limit detection). stdin is closed so nothing reads a piped script.
# -q must come first: it stops curl from reading ~/.curlrc, which could
# otherwise add options such as --insecure or an Authorization header.
http_get() { # url accept output
    curl -q -sS -L --proto '=https' --proto-redir '=https' --connect-timeout 20 --max-time 300 \
        -H "Accept: $2" -D "$3.headers" -o "$3" -w '%{http_code}' "$1" </dev/null
}

http_fetch() { # url accept output what
    local code rc
    code=$(http_get "$1" "$2" "$3")
    rc=$?
    if ((rc != 0)); then
        err "could not download $4 from GitHub (curl exit status $rc; network or DNS problem?)"
        return "$rc"
    fi
    case "$code" in
        200) return 0 ;;
        403|429)
            if grep -qi '^x-ratelimit-remaining: *0' "$3.headers" 2>/dev/null; then
                err "GitHub's API rate limit for requests without credentials is used up (60 per hour per IP address). Try again later, or download the release files elsewhere and use --bundle."
            else
                err "GitHub refused the request for $4 (HTTP $code)"
            fi
            ;;
        404) err "$4 not found (does $REPO exist, is it public, and does the release exist?)" ;;
        *) err "GitHub answered HTTP $code for $4" ;;
    esac
    return 1
}

# Sets RELEASE to the tag of the requested (or latest) release, using one
# GitHub API request. RELEASE_JSON keeps the response.
resolve_release() {
    local tag url="$GITHUB_API/repos/$REPO/releases/latest"
    need curl jq || return 1
    [[ -n "$RELEASE" ]] && url="$GITHUB_API/repos/$REPO/releases/tags/$RELEASE"
    RELEASE_JSON="$TMP_DIR/release.json"
    http_fetch "$url" application/vnd.github+json "$RELEASE_JSON" "release ${RELEASE:-latest} of $REPO" || return
    if ! tag=$(jq -er 'if type == "object" then .tag_name else empty end | strings' "$RELEASE_JSON" 2>/dev/null); then
        err "unexpected response from GitHub (no release data)"
        return 1
    fi
    if [[ ! "$tag" =~ $TAG_RE ]]; then
        err "unexpected release tag from GitHub"
        return 1
    fi
    if [[ -n "$RELEASE" && "$tag" != "$RELEASE" ]]; then
        err "GitHub returned release $tag for $RELEASE"
        return 1
    fi
    RELEASE="$tag"
}

# Downloads the bundle and SHA256SUMS of $RELEASE into <dir>, from the
# release download URLs (these do not count against the API rate limit).
download_release() { # dir
    local dir="$1" name
    for name in "$ASSET" "$SUMS_ASSET"; do
        if ! jq -e --arg n "$name" '[.assets[]? | select(.name == $n)] | length == 1' "$RELEASE_JSON" >/dev/null 2>&1; then
            err "release $RELEASE has no $name asset; nothing installed"
            return 1
        fi
    done
    for name in "$ASSET" "$SUMS_ASSET"; do
        http_fetch "$GITHUB_WEB/$REPO/releases/download/$RELEASE/$name" application/octet-stream \
            "$dir/$name" "$name of $RELEASE" || return
    done
}

# ==========================================================
# INSTALLATION
# ==========================================================
install_dependencies() {
    local c rc missing=()
    if [[ -n "$ROOT" || "$INSTALL_DEPS" == 0 ]]; then
        if [[ -n "$ROOT" ]]; then say "Skipped (NM_INSTALL_ROOT is set)."; else say "Skipped (--no-deps)."; fi
        for c in jq nginx; do
            command -v "$c" >/dev/null 2>&1 || missing+=("$c")
        done
        if ((${#missing[@]})); then
            say "Warning: nginx-manager needs ${missing[*]} to start (apt-get install ${missing[*]})." >&2
        fi
        return 0
    fi
    if ! command -v apt-get >/dev/null 2>&1; then
        err "apt-get not found: this installer supports Debian and Ubuntu. Install curl, jq, nginx and openssl, then rerun with --no-deps."
        return 1
    fi
    export DEBIAN_FRONTEND=noninteractive
    local packages=(curl jq nginx openssl)
    if [[ "$WITH_CERTBOT" == 1 ]]; then
        packages+=(certbot python3-certbot-dns-cloudflare)
    fi
    apt-get update || { rc=$?; err "apt-get update failed"; return "$rc"; }
    apt-get install -y "${packages[@]}" || { rc=$?; err "apt-get install failed"; return "$rc"; }
}

# Creates missing directories (0755). Existing ones, and everything in
# the plugin directory, are left as they are.
prepare_dirs() {
    local d
    for d in "$BIN_DIR" "$LIB_DIR" "$PLUGIN_DIR"; do
        if [[ ! -d "$d" ]] && ! install -d -m 755 "$d"; then
            err "could not create $d; nothing changed"
            return 1
        fi
    done
}

# Puts <file> at $TARGET. The new file is written next to it and renamed
# over it, which is atomic on a local filesystem: a starting nginx-manager
# finds the old or the new version, and a running one keeps the old file.
# Before that, the current file is saved as $PREVIOUS, so a new version is
# never in place without a copy of the one it replaced. Sets REPLACED to
# same, new or saved.
put_in_place() { # file
    local file="$1"
    exec 9>"$LOCK_FILE" || { err "could not open $LOCK_FILE"; return 1; }
    if ! flock -n 9; then
        err "another install.sh is running"
        return 1
    fi
    # Left behind only if an earlier run was killed (we hold the lock).
    rm -f "$BIN_DIR"/.nginx-manager.new.* "$LIB_DIR"/.previous.*

    if [[ -L "$TARGET" ]]; then
        err "$TARGET is a symbolic link (to $(readlink "$TARGET")); the installer does not replace it. Remove it and rerun."
        return 1
    fi
    if [[ -e "$TARGET" && ! -f "$TARGET" ]]; then
        err "$TARGET exists but is not a regular file; nothing changed"
        return 1
    fi
    if [[ -f "$TARGET" ]] && cmp -s "$file" "$TARGET"; then
        REPLACED=same
        return 0
    fi

    if ! STAGED=$(mktemp "$BIN_DIR/.nginx-manager.new.XXXXXX") ||
        ! cp "$file" "$STAGED" || ! chmod 755 "$STAGED" || ! cmp -s "$file" "$STAGED"; then
        err "could not write the new version to $BIN_DIR; nothing changed"
        return 1
    fi
    sync "$STAGED" 2>/dev/null

    REPLACED=new
    if [[ -f "$TARGET" ]]; then
        if ! PREV_TMP=$(mktemp "$LIB_DIR/.previous.XXXXXX") ||
            ! cp -p "$TARGET" "$PREV_TMP" || ! mv -fT "$PREV_TMP" "$PREVIOUS"; then
            err "could not save the current version as $PREVIOUS; $TARGET is unchanged"
            return 1
        fi
        PREV_TMP="" REPLACED=saved
    fi

    if ! mv -fT "$STAGED" "$TARGET"; then
        err "could not move the new version into place; $TARGET is unchanged"
        return 1
    fi
    STAGED=""
}

banner() {
    echo "======================================"
    echo " NGINX Manager Pro - Installer"
    echo "======================================"
    echo
}

finish_notes() {
    echo "Run:"
    echo "  nginx-manager"
    echo
    echo "Interface: gum, if installed, is used automatically; without it the"
    echo "built-in text menus are used (Settings and Help show which). The"
    echo "installer never installs gum."
    echo
    if [[ "$WITH_CERTBOT" != 1 ]]; then
        echo "Certbot was not installed (only needed for HTTPS certificates)."
        echo "Add it later via TLS & certificates -> Install TLS packages, or"
        echo "rerun the installer with --with-certbot."
        echo
    fi
}

run_install() {
    local candidate sums="" expect="" old
    banner
    echo "[1/4] Installing dependencies..."
    install_dependencies || exit $?

    echo
    echo "[2/4] Getting NGINX Manager Pro..."
    candidate="$TMP_DIR/$ASSET"
    if [[ -n "$BUNDLE" ]]; then
        # Work on a private copy, so the file checked is the file installed.
        cp "$BUNDLE" "$candidate" || die "could not read $BUNDLE"
        if [[ -n "$SUMS_FILE" ]]; then
            sums="$TMP_DIR/$SUMS_ASSET"
            cp "$SUMS_FILE" "$sums" || die "could not read $SUMS_FILE"
        fi
        say "Local bundle: $BUNDLE"
    else
        resolve_release || exit $?
        mkdir "$TMP_DIR/release" || die "could not create a temporary directory"
        download_release "$TMP_DIR/release" || exit $?
        mv "$TMP_DIR/release/$ASSET" "$candidate" || exit 1
        sums="$TMP_DIR/release/$SUMS_ASSET" expect="$RELEASE"
        say "Downloaded release $RELEASE of $REPO."
    fi

    echo
    echo "[3/4] Verifying..."
    verify_checksums "$candidate" "$sums" || exit 1
    validate_bundle "$candidate" "$expect" || exit 1
    say "Bundle version $BUNDLE_VERSION: complete, valid Bash."

    echo
    echo "[4/4] Installing..."
    old=$(installed_version)
    prepare_dirs || exit 1
    put_in_place "$candidate" || exit 1

    echo
    echo "======================================"
    echo " Installation completed successfully"
    echo "======================================"
    echo
    case "$REPLACED" in
        same) say "Version $BUNDLE_VERSION was already installed; nothing was replaced." ;;
        new) say "Installed version $BUNDLE_VERSION as $TARGET." ;;
        saved)
            say "Updated $old -> $BUNDLE_VERSION."
            say "The replaced version is saved as $PREVIOUS"
            say "(install.sh --rollback puts it back)."
            ;;
    esac
    say "Configuration, sites, secrets, backups and plugins were not touched."
    echo
    finish_notes
}

run_rollback() {
    local candidate="$TMP_DIR/previous" old new
    banner
    [[ -f "$PREVIOUS" ]] || die "no previous version is saved ($PREVIOUS); install a specific release with --release TAG instead"
    cp "$PREVIOUS" "$candidate" || die "could not read $PREVIOUS"
    # It was installed and ran before, possibly before bundles had markers,
    # so only check that it is still intact Bash.
    if [[ ! -s "$candidate" ]] || ! bash -n "$candidate" 2>/dev/null; then
        die "$PREVIOUS is empty or not valid Bash; reinstall a release with --release TAG"
    fi
    old=$(installed_version)
    new=$(bundle_version "$candidate") || new="unknown"
    prepare_dirs || exit 1
    put_in_place "$candidate" || exit 1
    if [[ "$REPLACED" == same ]]; then
        say "The previous version ($new) is already installed; nothing changed."
    else
        say "Rolled back to $new."
        [[ "$REPLACED" == saved ]] && say "$old is now saved as $PREVIOUS (--rollback again returns to it)."
        say "Only the program was replaced; configuration and data are unchanged."
    fi
}

run_check() {
    local installed
    installed=$(installed_version)
    say "Installed: $installed"
    resolve_release || exit $?
    if [[ -n "$RELEASE_REQUESTED" ]]; then say "Release of $REPO: $RELEASE"; else say "Latest release of $REPO: $RELEASE"; fi
    if [[ "$installed" == "$RELEASE" ]]; then
        say "Up to date."
    elif newer "$installed" "$RELEASE"; then
        say "The installed version is newer than $RELEASE."
    else
        say "To install $RELEASE: sudo bash install.sh${RELEASE_REQUESTED:+ --release $RELEASE}"
    fi
}

# ==========================================================
# MAIN
# ==========================================================
main() {
    while (($#)); do
        case "$1" in
            --release|--repo|--bundle|--sha256sums)
                if (($# < 2)); then
                    echo "Option $1 needs a value"
                    exit 1
                fi
                case "$1" in
                    --release) RELEASE="$2" ;;
                    --repo) REPO="$2" ;;
                    --bundle) BUNDLE="$2" ;;
                    --sha256sums) SUMS_FILE="$2" ;;
                esac
                shift 2
                ;;
            --check) MODE=check; shift ;;
            --rollback) MODE=rollback; shift ;;
            --no-deps) INSTALL_DEPS=0; shift ;;
            --with-certbot) WITH_CERTBOT=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) echo "Unknown option: $1"; exit 1 ;;
        esac
    done
    RELEASE_REQUESTED="$RELEASE"

    if [[ "$MODE" != check && -z "$ROOT" && $EUID -ne 0 ]]; then
        banner
        echo "Please run this installer with sudo."
        echo
        echo "Example:"
        echo "  sudo bash install.sh"
        exit 1
    fi

    if [[ -n "$EXPECTED_SHA256" && ! "$EXPECTED_SHA256" =~ ^[0-9a-fA-F]{64}$ ]]; then
        die "NM_SHA256 must be 64 hex characters."
    fi
    if [[ -n "$BUNDLE" ]]; then
        [[ "$MODE" == install ]] || die "--bundle cannot be combined with --$MODE"
        [[ -z "$RELEASE" ]] || die "--bundle installs a local file: --release does not apply"
        [[ -f "$BUNDLE" ]] || die "bundle $BUNDLE not found"
        [[ -z "$SUMS_FILE" || -f "$SUMS_FILE" ]] || die "$SUMS_FILE not found"
    elif [[ "$MODE" != rollback ]]; then
        [[ -z "$SUMS_FILE" ]] || die "--sha256sums only applies to --bundle"
        [[ -n "$REPO" ]] || die "no repository configured: use --repo OWNER/NAME or NM_REPO (or --bundle FILE to install a local file)"
        [[ "$REPO" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]] || die "--repo must be OWNER/NAME"
        [[ -z "$RELEASE" || "$RELEASE" =~ $TAG_RE ]] || die "invalid release tag '$RELEASE'"
    fi
    if [[ "$WITH_CERTBOT" == 1 && ( "$INSTALL_DEPS" == 0 || -n "$ROOT" ) ]]; then
        die "--with-certbot installs packages, which --no-deps and NM_INSTALL_ROOT skip"
    fi

    # Private (0700, unpredictable name), removed on any exit.
    TMP_DIR=$(mktemp -d) || die "could not create a temporary directory"

    case "$MODE" in
        install) run_install ;;
        rollback) run_rollback ;;
        check) run_check ;;
    esac
}

# Last line: when the script is piped into bash, all of it has been read
# before anything runs, so no command can consume the rest of it.
main "$@"
