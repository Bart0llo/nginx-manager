#!/bin/bash
# tools/bundle.sh, tools/release.sh and the release workflow: what goes
# into the distributed files. /src is mounted read-only, so the tools
# cannot change tracked files here.

OUT=/tmp/nm-release

sourced_modules() {
    sed -n 's/^source "\$NM_LIB_DIR\/\([a-z_]*\.sh\)"$/\1/p' /src/nginx-site.sh
}

t_bundle_contains_every_module() {
    mkdir -p "$OUT"
    local b=$OUT/b.sh m modules
    bash /src/tools/bundle.sh "$b" >/dev/null
    assert_eq 0 $? "bundle builds"
    modules=$(sourced_modules | tr '\n' ' ')
    assert_eq "# @nm-bundle-end modules=${modules% }" "$(tail -n 1 "$b")" "end marker lists the sourced modules in order"
    assert_eq "$(cd /src/lib && ls ./*.sh | sed 's|^\./||' | sort)" "$(sourced_modules | sort)" \
        "every lib/*.sh is sourced (and so bundled)"
    local start n
    for m in $modules; do
        assert_eq 1 "$(grep -cxF "# @nm-module $m" "$b")" "$m inlined once"
        # Everything after the module's shebang follows its marker verbatim.
        start=$(grep -nxF "# @nm-module $m" "$b" | cut -d: -f1)
        n=$(($(wc -l < "/src/lib/$m") - 1))
        assert_eq "$(tail -n +2 "/src/lib/$m" | sha256sum)" \
            "$(tail -n +$((start + 1)) "$b" | head -n "$n" | sha256sum)" "$m inlined verbatim"
    done
    assert_mode "$b" 755
    bash -n "$b"
    assert_eq 0 $? "bundle has valid syntax"
    local text
    text=$(cat "$b")
    assert_not_contains "$text" "NM_LIB_DIR" "no module directory needed"
    assert_not_contains "$text" "@bundle-begin" "build markers removed"
    assert_not_contains "$text" "MOCK_BIN" "no test harness code"
    assert_not_contains "$text" "/src/tests" "no test paths"
    assert_eq 1 "$(grep -c '^#!' "$b")" "one shebang (module shebangs dropped)"
}

t_bundle_reproducible() {
    mkdir -p "$OUT"
    bash /src/tools/bundle.sh "$OUT/1.sh" >/dev/null
    bash /src/tools/bundle.sh "$OUT/2.sh" >/dev/null
    assert_eq "$(sha256sum < "$OUT/1.sh")" "$(sha256sum < "$OUT/2.sh")" "two builds are identical"
}

t_bundle_version() {
    mkdir -p "$OUT"
    local out rc
    bash /src/tools/bundle.sh "$OUT/dev.sh" >/dev/null
    assert_eq 'NM_VERSION="dev"' "$(grep '^NM_VERSION=' "$OUT/dev.sh")" "default version dev"
    bash /src/tools/bundle.sh --version v1.2.3 "$OUT/rel.sh" >/dev/null
    assert_eq 'NM_VERSION="v1.2.3"' "$(grep '^NM_VERSION=' "$OUT/rel.sh")" "--version stamps the bundle"
    out=$(setpriv --reuid=65534 --regid=65534 --clear-groups bash "$OUT/rel.sh" --version 2>&1)
    assert_eq "nginx-manager v1.2.3" "$out" "bundle reports its version"

    out=$(bash /src/tools/bundle.sh --version 'a b' "$OUT/bad.sh" 2>&1); rc=$?
    assert_eq 1 "$rc" "invalid version: exits 1"
    assert_contains "$out" "invalid version 'a b'" "reason shown"
    assert_no_file "$OUT/bad.sh" "no output"
    out=$(bash /src/tools/bundle.sh --version 2>&1); rc=$?
    assert_eq 1 "$rc" "--version without a value: exits 1"
}

t_bundle_missing_module() {
    mkdir -p /tmp/nm-src
    cp -r /src/nginx-site.sh /src/lib /src/tools /tmp/nm-src/
    rm /tmp/nm-src/lib/tls.sh
    local out rc
    out=$(bash /tmp/nm-src/tools/bundle.sh /tmp/nm-src/out.sh 2>&1); rc=$?
    assert_eq 1 "$rc" "exits 1"
    assert_contains "$out" "lib/tls.sh not found" "reason shown"
    assert_no_file /tmp/nm-src/out.sh "no bundle written"
    assert_no_file /tmp/nm-src/out.sh.tmp "temporary file removed"
}

t_bundle_runs_without_gum() {
    mkdir -p "$OUT"
    bash /src/tools/bundle.sh "$OUT/b.sh" >/dev/null
    fixture_configured
    assert_eq "" "$(command -v gum)" "no gum in the test image"
    local out rc
    out=$(printf 'q\n' | timeout 20 bash "$OUT/b.sh" 2>&1); rc=$?
    assert_eq 0 "$rc" "bundle starts and quits without gum"
    assert_contains "$out" "NGINX Manager Pro" "dashboard shown"
    assert_contains "$out" "[Q] Quit" "built-in menu used"
}

t_app_version() {
    local out rc
    out=$(setpriv --reuid=65534 --regid=65534 --clear-groups bash "$APP" --version 2>&1); rc=$?
    assert_eq 0 "$rc" "--version exits 0 without root"
    assert_eq "nginx-manager dev" "$out" "unreleased build is dev"
}

t_release_assets() {
    local out rc d=$OUT/r
    out=$(bash /src/tools/release.sh v2.3.4 acme/tool "$d" 2>&1); rc=$?
    assert_eq 0 "$rc" "release.sh exits 0"
    assert_eq "SHA256SUMS install.sh nginx-site.sh" "$(ls "$d" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')" "three assets"
    out=$(cd "$d" && sha256sum -c SHA256SUMS 2>&1); rc=$?
    assert_eq 0 "$rc" "SHA256SUMS verifies both files"
    assert_eq 'NM_VERSION="v2.3.4"' "$(grep '^NM_VERSION=' "$d/nginx-site.sh")" "bundle stamped"
    assert_eq 'NM_REPO_DEFAULT="acme/tool"' "$(grep '^NM_REPO_DEFAULT=' "$d/install.sh")" "installer stamped"
    assert_eq 1 "$(diff /src/install.sh "$d/install.sh" | grep -c '^>')" "only that line differs"
    assert_mode "$d/nginx-site.sh" 755
    assert_mode "$d/install.sh" 755
}

t_release_rejects_bad_input() {
    local out rc
    out=$(bash /src/tools/release.sh 2.3.4 acme/tool "$OUT/a" 2>&1); rc=$?
    assert_eq 1 "$rc" "version without v: exits 1"
    assert_contains "$out" "version must look like v1.2.3" "reason shown"
    out=$(bash /src/tools/release.sh v2.3.4 acme "$OUT/a" 2>&1); rc=$?
    assert_eq 1 "$rc" "repository without owner: exits 1"
    mkdir -p "$OUT/full"; echo keep > "$OUT/full/f"
    out=$(bash /src/tools/release.sh v2.3.4 acme/tool "$OUT/full" 2>&1); rc=$?
    assert_eq 1 "$rc" "non-empty output directory: exits 1"
    assert_eq keep "$(cat "$OUT/full/f")" "existing files untouched"
}

# The workflow only runs on version tags and tests before publishing.
t_release_workflow() {
    local wf=/src/.github/workflows/release.yml text
    assert_file "$wf" "workflow present"
    text=$(cat "$wf")
    assert_contains "$text" "tags: ['v[0-9]+.[0-9]+.[0-9]+']" "version tags only"
    assert_not_contains "$text" "branches:" "not on branch pushes"
    assert_not_contains "$text" "pull_request" "not on pull requests"
    local tests_line publish_line
    tests_line=$(grep -n 'bash tests/run.sh' "$wf" | head -n 1 | cut -d: -f1)
    publish_line=$(grep -n 'gh release create' "$wf" | head -n 1 | cut -d: -f1)
    assert_eq 1 "$(( tests_line > 0 && publish_line > tests_line ))" "tests run before publishing"
    assert_contains "$text" "    needs: test" "publishing waits for the tests"
    assert_contains "$text" "tools/release.sh" "assets built with tools/release.sh"
    # Write access only in the publish job; the workflow default is read.
    assert_eq "contents: read" "$(sed -n '/^permissions:/{n;s/^ *//;p}' "$wf")" "read-only by default"
    assert_eq 1 "$(grep -c 'contents: write' "$wf")" "one job may write"
    assert_eq "permissions:" "$(sed -n '/^  publish:/,/contents: write/p' "$wf" | grep -o 'permissions:')" \
        "that job is publish"
    assert_not_contains "$text" "secrets." "no repository secrets used"
}
