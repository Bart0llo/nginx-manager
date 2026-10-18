#!/bin/bash
# Plugin system (lib/plugins.sh): discovery, enable/disable, the hook
# contract, settings, secrets, per-site data and the example plugin.
# Test plugins live in $TP; their plugin.sh logs every call to $CALLS.

TP=/tmp/nm-plugins
CALLS=/tmp/plugin-calls.log
ALL_HOOKS="validate-site server-directives location-directives site-applied site-deleted"

# The spy plugin: logs "<id> <hook> <site>", saves its NM_* environment to
# <dir>/<hook>.env and anything it could read from stdin to <dir>/stdin-read.
# Optional per hook: <hook>.sleep seconds, <hook>.out printed, <hook>.rc exit.
spy_plugin() { # dir
    cat > "$1/plugin.sh" <<'EOF'
#!/bin/bash
echo "$NM_PLUGIN_ID $1 $2" >> /tmp/plugin-calls.log
env | grep '^NM_' | grep -v '^NM_TEST' | LC_ALL=C sort > "$NM_PLUGIN_DIR/$1.env"
read -r line && echo "$line" > "$NM_PLUGIN_DIR/stdin-read"
[[ -f "$NM_PLUGIN_DIR/$1.sleep" ]] && sleep "$(cat "$NM_PLUGIN_DIR/$1.sleep")"
[[ -f "$NM_PLUGIN_DIR/$1.out" ]] && cat "$NM_PLUGIN_DIR/$1.out"
exit "$(cat "$NM_PLUGIN_DIR/$1.rc" 2>/dev/null || echo 0)"
EOF
}

make_plugin() { # id hooks [extra manifest lines...]
    local id="$1" hooks="$2"
    shift 2
    mkdir -p "$TP/$id"
    printf '%s\n' "ID=$id" "NAME=Test $id" "VERSION=1.0.0" "API=1" "HOOKS=$hooks" "$@" \
        > "$TP/$id/manifest.conf"
    spy_plugin "$TP/$id"
}

# Writes a plugin directory with exactly the given manifest lines.
raw_plugin() { # dir-name manifest-lines...
    local dir="$TP/$1"
    shift
    mkdir -p "$dir"
    printf '%s\n' "$@" > "$dir/manifest.conf"
    spy_plugin "$dir"
}

load_app_tp() { load_app && PLUGIN_DIR="$TP"; }
calls() { cat "$CALLS" 2>/dev/null; }
enabled_ids() { grep -v '^#' "$MANAGER_DIR/plugins.enabled" 2>/dev/null; }
db_snapshot() { cat "$MANAGER_DIR/sites.json"; }
temp_files() { ls -A "$1" | grep -E '^(tmp\.|\.)'; }

# ==========================================================
# Discovery and manifests
# ==========================================================
t_discovery_valid() {
    make_plugin beta ""
    make_plugin alpha "validate-site site-applied" "DESCRIPTION=First plugin"
    mkdir -p "$TP/Bad Dir"
    touch "$TP/notadir"
    fixture_configured; load_app_tp
    plugins_load
    assert_eq "alpha beta" "${PLUGIN_IDS[*]}" "valid plugins discovered, sorted"
    assert_eq "alpha beta" "${PLUGIN_ORDER[*]}" "both available"
    assert_eq "Test alpha|1.0.0|First plugin|validate-site site-applied" \
        "${PLUGIN_NAME[alpha]}|${PLUGIN_VERSION[alpha]}|${PLUGIN_DESC[alpha]}|${PLUGIN_HOOKS[alpha]}" "manifest fields read"
    local out
    out=$(plugins_list)
    assert_matches "$out" 'alpha +○ DISABLED +1\.0\.0 +Test alpha' "listed as disabled"
    assert_contains "$out" "First plugin" "description shown"
    assert_contains "$out" "Ignored $TP/Bad\\ Dir: not a valid plugin ID" "bad directory name reported"
    assert_not_contains "$out" "notadir" "plain files ignored"
    assert_eq "" "$(calls)" "discovery and listing run no plugin code"
    assert_no_file "$MANAGER_DIR/plugins.enabled" "nothing enabled by discovery"
}

t_discovery_no_plugin_dir() {
    fixture_configured; load_app
    PLUGIN_DIR=/nonexistent
    assert_contains "$(plugins_list)" "No plugins installed in /nonexistent" "empty state shown"
    local out rc
    out=$(site_create web web.lan.example.com 127.0.0.1:3000 http 2>&1 </dev/null); rc=$?
    assert_eq 0 "$rc" "sites work without plugins"
    golden_compare http.conf "$SITES_AVAILABLE/web.conf"
}

t_manifest_invalid() {
    local -A expect=()
    mkdir -p "$TP/nomanifest"; expect[nomanifest]="missing manifest.conf"
    raw_plugin noid "NAME=x" "VERSION=1.0.0" "API=1"; expect[noid]="ID is missing"
    raw_plugin mismatch "ID=other" "NAME=x" "VERSION=1.0.0" "API=1"
    expect[mismatch]="ID 'other' does not match the directory name 'mismatch'"
    raw_plugin noname "ID=noname" "VERSION=1.0.0" "API=1"; expect[noname]="NAME is missing"
    raw_plugin badversion "ID=badversion" "NAME=x" "VERSION=1.0" "API=1"
    expect[badversion]="VERSION must be MAJOR.MINOR.PATCH"
    raw_plugin noapi "ID=noapi" "NAME=x" "VERSION=1.0.0"; expect[noapi]="API is missing"
    raw_plugin api2 "ID=api2" "NAME=x" "VERSION=1.0.0" "API=2"
    expect[api2]="unsupported API version '2' (this manager supports 1)"
    raw_plugin unknownkey "ID=unknownkey" "NAME=x" "VERSION=1.0.0" "API=1" "FOO=1"
    expect[unknownkey]="manifest.conf: unknown key FOO"
    raw_plugin dupkey "ID=dupkey" "NAME=x" "NAME=y" "VERSION=1.0.0" "API=1"
    expect[dupkey]="manifest.conf line 3: NAME repeated"
    raw_plugin shell "ID=shell" "touch /tmp/pwned" "NAME=x" "VERSION=1.0.0" "API=1"
    expect[shell]="manifest.conf line 2: expected KEY=VALUE"
    raw_plugin exported "export ID=exported" "NAME=x" "VERSION=1.0.0" "API=1"
    expect[exported]="manifest.conf line 1: expected KEY=VALUE"
    raw_plugin spaced "ID = spaced" "NAME=x" "VERSION=1.0.0" "API=1"
    expect[spaced]="manifest.conf line 1: expected KEY=VALUE"
    raw_plugin ctrl "ID=ctrl" $'NAME=a\033[2Jb' "VERSION=1.0.0" "API=1"
    expect[ctrl]="manifest.conf line 2: control character in NAME"
    raw_plugin badhook "ID=badhook" "NAME=x" "VERSION=1.0.0" "API=1" "HOOKS=pre-delete"
    expect[badhook]="HOOKS: unknown hook 'pre-delete'"
    raw_plugin duphook "ID=duphook" "NAME=x" "VERSION=1.0.0" "API=1" "HOOKS=validate-site validate-site"
    expect[duphook]="HOOKS: 'validate-site' listed twice"
    raw_plugin nocode "ID=nocode" "NAME=x" "VERSION=1.0.0" "API=1" "HOOKS=validate-site"
    rm "$TP/nocode/plugin.sh"; expect[nocode]="declares hooks but has no plugin.sh"
    raw_plugin baddep "ID=baddep" "NAME=x" "VERSION=1.0.0" "API=1" "DEPENDS=../x"
    expect[baddep]="DEPENDS: invalid plugin ID '../x'"
    raw_plugin selfdep "ID=selfdep" "NAME=x" "VERSION=1.0.0" "API=1" "DEPENDS=selfdep"
    expect[selfdep]="DEPENDS: a plugin cannot depend on itself"
    raw_plugin longname "ID=longname" "NAME=$(printf 'n%.0s' {1..65})" "VERSION=1.0.0" "API=1"
    expect[longname]="NAME is longer than 64 characters"
    make_plugin good "$ALL_HOOKS"

    fixture_configured; load_app_tp
    plugins_load
    local id out rc list
    list=$(plugins_list)
    for id in "${!expect[@]}"; do
        assert_eq "${expect[$id]}" "${PLUGIN_ERROR[$id]}" "$id: rejected with reason"
        assert_contains "$list" "${expect[$id]}" "$id: reason listed"
        out=$(plugin_enable "$id" 2>&1); rc=$?
        assert_eq 1 "$rc" "$id: cannot be enabled"
        assert_contains "$out" "Plugin '$id' cannot be enabled: ${expect[$id]}" "$id: enable refusal explained"
    done
    assert_eq "good" "${PLUGIN_ORDER[*]}" "only the valid plugin is available"
    assert_matches "$list" 'api2 +✗ INVALID' "invalid status shown"
    assert_no_file "$MANAGER_DIR/plugins.enabled" "nothing enabled"
    assert_no_file /tmp/pwned "manifest never executed"
    assert_eq "" "$(calls)" "no plugin code ran"
}

# Shell syntax in manifest values is kept as text.
t_manifest_values_are_data() {
    raw_plugin data "ID=data" 'NAME=$(touch /tmp/pwned)' 'DESCRIPTION=`touch /tmp/pwned2`; x' \
        "VERSION='1.2.3'" 'API="1"' "# a comment" "" "  HOOKS=validate-site  "
    fixture_configured; load_app_tp
    plugins_load
    assert_eq "" "${PLUGIN_ERROR[data]}" "valid"
    assert_eq '$(touch /tmp/pwned)' "${PLUGIN_NAME[data]}" "name taken literally"
    assert_eq '`touch /tmp/pwned2`; x' "${PLUGIN_DESC[data]}" "description taken literally"
    assert_eq "1.2.3" "${PLUGIN_VERSION[data]}" "quotes removed"
    assert_contains "$(plugins_list)" '$(touch /tmp/pwned)' "listed literally"
    assert_no_file /tmp/pwned "no command substitution"
    assert_no_file /tmp/pwned2 "no backticks"
}

# The directory name is the ID: a copy claiming another plugin's ID is refused.
t_duplicate_id() {
    make_plugin good "validate-site"
    raw_plugin copy "ID=good" "NAME=Copy" "VERSION=1.0.0" "API=1" "HOOKS=validate-site"
    fixture_configured; load_app_tp
    plugins_load
    assert_eq "duplicate ID 'good' (already used by $TP/good)" "${PLUGIN_ERROR[copy]}" "duplicate refused"
    assert_eq "good" "${PLUGIN_ORDER[*]}" "original stays available"
    plugin_enable copy >/dev/null 2>&1; assert_eq 1 $? "duplicate cannot be enabled"
    plugin_enable good >/dev/null 2>&1; assert_eq 0 $? "original can be enabled"
    site_create web web.lan.example.com 127.0.0.1:8080 http >/dev/null 2>&1 </dev/null
    assert_eq "good validate-site web" "$(calls)" "only the original runs"
}

t_invalid_ids_rejected() {
    make_plugin good "$ALL_HOOKS"
    mkdir -p /tmp/nm-plugins-evil
    printf '%s\n' "ID=evil" "NAME=x" "VERSION=1.0.0" "API=1" > /tmp/nm-plugins-evil/manifest.conf
    fixture_configured; load_app_tp
    new_site app http
    local before id out rc
    before=$(db_snapshot)
    for id in "" "../nm-plugins-evil" "../../tmp/nm-plugins-evil" "a/b" ".." "." "Good" "-x" "x y" \
        "good;rm" "$(printf 'a%.0s' {1..33})"; do
        out=$(plugin_enable "$id" 2>&1); rc=$?
        assert_eq 2 "$rc" "enable '$id' rejected"
        assert_contains "$out" "Invalid plugin ID: '$id'" "enable '$id' reported"
        plugin_disable "$id" >/dev/null 2>&1; assert_eq 2 $? "disable '$id' rejected"
        printf 'v' | plugin_secret_set "$id" token >/dev/null 2>&1; assert_eq 2 $? "secret for '$id' rejected"
        plugin_site_set app "$id" '{"x":1}' >/dev/null 2>&1; assert_eq 2 $? "site data for '$id' rejected"
    done
    out=$(plugin_enable missing 2>&1); rc=$?
    assert_eq 2 "$rc" "unknown plugin rejected"
    assert_contains "$out" "Plugin 'missing' not found in $TP" "unknown plugin reported"
    assert_no_file "$MANAGER_DIR/plugins.enabled" "nothing enabled"
    assert_no_file "$MANAGER_DIR/secrets" "no secret directories created"
    assert_eq "$before" "$(db_snapshot)" "db unchanged"
    assert_eq "" "$(calls)" "no plugin code ran"
}

# A plugins.enabled line that is not an ID stops every hook, not just that line.
t_corrupt_enabled_list() {
    make_plugin good "validate-site"
    fixture_configured; load_app_tp
    printf '%s\n' good ../nm-plugins-evil > "$MANAGER_DIR/plugins.enabled"
    local out rc
    out=$(site_create web web.lan.example.com 127.0.0.1:8080 http 2>&1 </dev/null); rc=$?
    assert_eq 2 "$rc" "site_create refused"
    assert_contains "$out" "Invalid $MANAGER_DIR/plugins.enabled (line 2: not a plugin ID); plugin hooks cannot run" "reason shown"
    assert_db 'has("web") | not' "nothing saved"
    assert_eq "" "$(calls)" "no plugin ran"
    assert_contains "$(plugins_list)" "line 2: not a plugin ID" "listing shows the problem"
    out=$(plugin_enable good 2>&1); rc=$?
    assert_eq 1 "$rc" "enable refused until fixed"
}

# ==========================================================
# Enable / disable
# ==========================================================
t_enable_disable_persistence() {
    make_plugin a "$ALL_HOOKS"; make_plugin b "$ALL_HOOKS"; make_plugin c "$ALL_HOOKS"
    fixture_configured; load_app_tp
    new_site web http; enable_site web >/dev/null 2>&1
    local nginx_before out rc
    nginx_before=$(ls -l --time-style=full-iso "$SITES_AVAILABLE" "$SITES_ENABLED"; cat "$SITES_AVAILABLE"/*.conf)
    : > "$MOCK_LOG"; rm -f "$CALLS"

    out=$(plugin_enable b 2>&1); rc=$?
    assert_eq 0 "$rc" "enable returns 0"
    assert_contains "$out" "Plugin 'b' enabled" "reported"
    assert_contains "$out" "Existing site configurations are unchanged" "explains no config change"
    plugin_enable a >/dev/null 2>&1
    assert_eq $'a\nb' "$(enabled_ids)" "both persisted, sorted"
    out=$(plugin_enable a 2>&1); rc=$?
    assert_eq 0 "$rc" "enabling twice is fine"
    assert_contains "$out" "already enabled" "reported"
    assert_eq $'a\nb' "$(enabled_ids)" "no duplicate entry"

    plugin_disable a >/dev/null 2>&1; assert_eq 0 $? "disable returns 0"
    assert_eq "b" "$(enabled_ids)" "other plugin kept on disable"
    plugin_enable c >/dev/null 2>&1; plugin_disable b >/dev/null 2>&1
    assert_eq "c" "$(enabled_ids)" "toggling keeps the rest"
    out=$(plugin_disable a 2>&1); rc=$?
    assert_eq 2 "$rc" "disabling a disabled plugin rejected"
    assert_contains "$out" "Plugin 'a' is not enabled" "reported"

    load_app_tp
    plugins_load; plugins_read_enabled
    plugin_is_active c; assert_eq 0 $? "state survives a restart"
    plugin_is_active a; assert_eq 1 $? "disabled plugin inactive"
    assert_mode "$MANAGER_DIR/plugins.enabled" 600
    assert_eq "" "$(temp_files "$MANAGER_DIR")" "no temp files left"
    assert_eq "$nginx_before" "$(ls -l --time-style=full-iso "$SITES_AVAILABLE" "$SITES_ENABLED"; cat "$SITES_AVAILABLE"/*.conf)" \
        "nginx files untouched by enable/disable"
    assert_not_called "systemctl reload" "no reload"
    assert_eq "" "$(calls)" "no plugin code ran"
    assert_contains "$(cat /var/log/nginx-manager/manager.log)" "Plugin enabled: b" "logged"
}

# An enabled plugin that disappeared blocks hooks but can still be disabled.
t_enabled_but_uninstalled() {
    make_plugin a "validate-site"
    fixture_configured; load_app_tp
    plugin_enable a >/dev/null 2>&1
    rm -rf "$TP/a"
    local out rc
    out=$(site_create web web.lan.example.com 127.0.0.1:8080 http 2>&1 </dev/null); rc=$?
    assert_eq 2 "$rc" "site_create refused"
    assert_contains "$out" "Plugin 'a' is enabled but not installed in $TP" "reason shown"
    assert_contains "$out" "Fix the plugin, or disable it in the Plugins menu." "remedy shown"
    assert_matches "$(plugins_list)" 'a +✗ BROKEN' "listed as broken"
    out=$(plugin_disable a 2>&1); rc=$?
    assert_eq 0 "$rc" "can be disabled"
    site_create web web.lan.example.com 127.0.0.1:8080 http >/dev/null 2>&1 </dev/null
    assert_eq 0 $? "site_create works again"
}

# ==========================================================
# Hooks
# ==========================================================
# Every hook runs at its documented point, only for the enabled plugin.
t_disabled_plugins_never_execute() {
    make_plugin on "$ALL_HOOKS"; make_plugin off "$ALL_HOOKS"
    fixture_configured; load_app_tp
    plugin_enable on >/dev/null 2>&1
    {
        site_create web web.lan.example.com 127.0.0.1:3000 http
        enable_site web
        site_update web web.lan.example.com 127.0.0.1:3000 http
        disable_site web
        regenerate_site_safe web
        site_delete web
    } </dev/null >/dev/null 2>&1
    assert_eq "on validate-site web
on server-directives web
on location-directives web
on site-applied web
on site-applied web
on validate-site web
on server-directives web
on location-directives web
on site-applied web
on site-applied web
on server-directives web
on location-directives web
on site-deleted web" "$(calls)" "hooks called in order, disabled plugin never"
    assert_no_file "$TP/off/validate-site.env" "disabled plugin never ran"
}

# Plugins that output nothing leave the generated configs byte-identical.
t_silent_plugins_keep_golden_configs() {
    make_plugin quiet "$ALL_HOOKS"
    fixture_configured; load_app_tp
    plugin_enable quiet >/dev/null 2>&1
    site_create web web.lan.example.com 127.0.0.1:3000 http </dev/null >/dev/null 2>&1
    golden_compare http.conf "$SITES_AVAILABLE/web.conf"
    site_create app app.lan.example.com 127.0.0.1:8080 https </dev/null >/dev/null 2>&1
    golden_compare https.conf "$SITES_AVAILABLE/app.conf"
    site_create mix mix.lan.example.com 10.0.0.7:9000 both </dev/null >/dev/null 2>&1
    golden_compare both.conf "$SITES_AVAILABLE/mix.conf"
    assert_count "$(calls)" "location-directives" 3 "plugin did run"
}

t_hook_order_deterministic() {
    make_plugin zeta "validate-site"
    make_plugin alpha "validate-site"
    make_plugin mid "validate-site" "DEPENDS=zeta"
    make_plugin beta "validate-site" "DEPENDS=mid"
    fixture_configured; load_app_tp
    local id
    for id in zeta mid beta alpha; do plugin_enable "$id" >/dev/null 2>&1; done
    plugins_load
    assert_eq "alpha zeta mid beta" "${PLUGIN_ORDER[*]}" "dependencies first, then by ID"
    site_create one one.lan.example.com 127.0.0.1:8080 http </dev/null >/dev/null 2>&1
    site_create two two.lan.example.com 127.0.0.1:8080 http </dev/null >/dev/null 2>&1
    assert_eq "alpha validate-site one
zeta validate-site one
mid validate-site one
beta validate-site one
alpha validate-site two
zeta validate-site two
mid validate-site two
beta validate-site two" "$(calls)" "same order every time"
}

t_validate_failure_blocks() {
    make_plugin a "validate-site"; make_plugin b "validate-site"
    echo 1 > "$TP/a/validate-site.rc"
    echo "a: this domain is not allowed" > "$TP/a/validate-site.out"
    fixture_configured; load_app_tp
    new_site app http
    plugin_enable a >/dev/null 2>&1; plugin_enable b >/dev/null 2>&1
    local before out rc
    before=$(db_snapshot)

    out=$(site_create web web.lan.example.com 127.0.0.1:8080 http 2>&1 </dev/null); rc=$?
    assert_eq 2 "$rc" "site_create rejected"
    assert_contains "$out" "a: this domain is not allowed" "plugin's reason shown"
    assert_contains "$out" "Plugin 'a' failed in validate-site for 'web' (exit 1)" "failure reported"
    assert_contains "$out" "Site rejected by a plugin; nothing was changed" "result explained"
    assert_not_contains "$out" "✓" "nothing reported as success"
    assert_db 'has("web") | not' "nothing saved"
    assert_no_file "$SITES_AVAILABLE/web.conf" "no config written"
    assert_eq "a validate-site web" "$(calls)" "blocking hook stops at the first failure"

    out=$(site_update app app.lan.example.com 127.0.0.1:9090 http 2>&1 </dev/null); rc=$?
    assert_eq 2 "$rc" "site_update rejected"
    assert_contains "$out" "Change rejected by a plugin; nothing was changed" "result explained"
    assert_eq "$before" "$(db_snapshot)" "db unchanged"
    assert_eq 0 "$(ls "$MANAGER_DIR/backups" | wc -l)" "nothing regenerated"
    assert_contains "$(cat /var/log/nginx-manager/manager.log)" "Plugin a failed in validate-site for web (exit 1)" "logged"
}

t_directives_failure_keeps_config() {
    make_plugin d "location-directives"
    fixture_configured; load_app_tp
    new_site app http; enable_site app >/dev/null 2>&1
    plugin_enable d >/dev/null 2>&1
    echo 3 > "$TP/d/location-directives.rc"
    local original out rc
    original=$(cat "$SITES_AVAILABLE/app.conf")
    : > "$MOCK_LOG"

    out=$(site_update app app.lan.example.com 127.0.0.1:9090 http 2>&1 </dev/null); rc=$?
    assert_eq 1 "$rc" "site_update fails"
    assert_contains "$out" "Plugin 'd' failed in location-directives for 'app' (exit 3)" "failure reported"
    assert_contains "$out" "Configuration for app not generated: a plugin failed" "result explained"
    assert_eq "$original" "$(cat "$SITES_AVAILABLE/app.conf")" "config untouched"
    assert_db '.app.backend == "127.0.0.1:8080"' "db restored"

    regenerate_site_safe app </dev/null >/dev/null 2>&1; assert_eq 1 $? "regenerate fails"
    assert_eq "$original" "$(cat "$SITES_AVAILABLE/app.conf")" "config still untouched"
    assert_eq 0 "$(ls "$MANAGER_DIR/backups" | wc -l)" "nothing backed up or replaced"
    assert_not_called "systemctl reload" "no reload after a refused generation"

    out=$(site_create web web.lan.example.com 127.0.0.1:8080 http 2>&1 </dev/null); rc=$?
    assert_eq 1 "$rc" "site_create fails"
    assert_db 'has("web") | not' "db entry rolled back"
    assert_no_file "$SITES_AVAILABLE/web.conf" "no config written"
    assert_eq "" "$(temp_files "$SITES_AVAILABLE")" "no temp files left"
}

# Informational hooks run every plugin; a failure is reported, the
# operation's result stands.
t_informational_failure_reported() {
    make_plugin m "site-applied site-deleted"; make_plugin n "site-applied site-deleted"
    echo 1 > "$TP/m/site-applied.rc"; echo 4 > "$TP/n/site-deleted.rc"
    fixture_configured; load_app_tp
    plugin_enable m >/dev/null 2>&1; plugin_enable n >/dev/null 2>&1
    local out rc

    out=$(site_create web web.lan.example.com 127.0.0.1:8080 http 2>&1 </dev/null); rc=$?
    assert_eq 0 "$rc" "site still created"
    assert_db 'has("web")' "saved"
    assert_contains "$out" "Plugin 'm' failed in site-applied for 'web' (exit 1)" "failure reported"
    assert_contains "$out" "Plugin hook site-applied failed for 'web'; the site changes reported above stand" "outcome explained"
    assert_eq $'m site-applied web\nn site-applied web' "$(calls)" "later plugins still notified"

    rm -f "$CALLS"
    out=$(site_delete web 2>&1 </dev/null); rc=$?
    assert_eq 0 "$rc" "site still deleted"
    assert_db 'has("web") | not' "removed"
    assert_contains "$out" "Plugin 'n' failed in site-deleted for 'web' (exit 4)" "failure reported"
    assert_eq $'m site-deleted web\nn site-deleted web' "$(calls)" "every plugin notified"
    assert_contains "$(cat /var/log/nginx-manager/manager.log)" "Plugin n failed in site-deleted for web (exit 4)" "logged"
}

# Regenerate-all runs the directive hooks once for every site.
t_regenerate_all_with_plugins() {
    make_plugin dir "server-directives location-directives"
    fixture_configured; load_app_tp
    new_site one http; new_site two http; new_site three http
    plugin_enable dir >/dev/null 2>&1
    local out
    out=$(regenerate_all <<< $'y\n\n' 2>&1)
    assert_contains "$out" "3 succeeded, 0 failed" "every site regenerated"
    assert_count "$(calls)" "location-directives" 3 "hook ran once per site"
}

t_hook_timeout() {
    make_plugin slow "validate-site"
    echo 10 > "$TP/slow/validate-site.sleep"
    fixture_configured; load_app_tp
    plugin_enable slow >/dev/null 2>&1
    PLUGIN_HOOK_TIMEOUT=1
    local out rc start
    start=$SECONDS
    out=$(site_create web web.lan.example.com 127.0.0.1:8080 http 2>&1 </dev/null); rc=$?
    assert_eq 2 "$rc" "rejected"
    assert_contains "$out" "Plugin 'slow' timed out in validate-site for 'web' (limit 1s)" "timeout reported"
    assert_eq 1 "$(( SECONDS - start < 5 ))" "did not wait for the plugin"
}

# Plugins get documented data in NM_*, never the manager's stdin.
t_hook_environment() {
    make_plugin envp "validate-site site-deleted"; make_plugin other ""
    fixture_configured; load_app_tp
    new_site app http
    plugin_site_set app envp '{"k":"v"}' >/dev/null 2>&1
    plugin_site_set app other '{"private":1}' >/dev/null 2>&1
    plugin_enable envp >/dev/null 2>&1
    local rest
    rest=$( { site_update app app.lan.example.com 127.0.0.1:9090 http >/dev/null 2>&1; cat; } <<< "UNREAD" )
    assert_eq UNREAD "$rest" "manager stdin left unread"
    assert_no_file "$TP/envp/stdin-read" "plugin got no stdin"
    assert_eq "NM_API=1
NM_HOOK=validate-site
NM_PLUGIN_CONFIG=$MANAGER_DIR/plugins/envp.conf
NM_PLUGIN_DIR=$TP/envp
NM_PLUGIN_ID=envp
NM_PLUGIN_SECRETS=$MANAGER_DIR/secrets/envp
NM_SITE=app
NM_SITE_BACKEND=127.0.0.1:9090
NM_SITE_DATA={\"k\":\"v\"}
NM_SITE_DOMAIN=app.lan.example.com
NM_SITE_ENABLED=false
NM_SITE_TLS=http" "$(cat "$TP/envp/validate-site.env")" "validate-site sees the proposed values and its own data only"

    site_delete app </dev/null >/dev/null 2>&1
    assert_contains "$(cat "$TP/envp/site-deleted.env")" 'NM_SITE_DATA={"k":"v"}' "site-deleted still gets the removed site's data"
    assert_contains "$(cat "$TP/envp/site-deleted.env")" "NM_SITE_DOMAIN=app.lan.example.com" "and its fields"
}

t_directives_rendered() {
    make_plugin dir "server-directives location-directives"
    printf '%s\n' 'location = /plugin-check {' '    return 204;' '}' > "$TP/dir/server-directives.out"
    printf '%s\n' '' 'proxy_set_header X-Plugin "on";' '' > "$TP/dir/location-directives.out"
    fixture_configured; load_app_tp
    plugin_enable dir >/dev/null 2>&1
    site_create mix mix.lan.example.com 10.0.0.7:9000 both </dev/null >/dev/null 2>&1
    assert_eq 0 $? "site created"
    assert_eq '# NGINX_MANAGER_TLS=both
server {
    listen 80;
    server_name mix.lan.example.com;
    # plugin: dir
    location = /plugin-check {
        return 204;
    }
    location / {
        proxy_pass http://10.0.0.7:9000;
        include snippets/proxy-common.conf;
        # plugin: dir
        proxy_set_header X-Plugin "on";
    }
}
server {
    listen 443 ssl http2;
    server_name mix.lan.example.com;
    ssl_certificate /etc/letsencrypt/live/lan.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/lan.example.com/privkey.pem;
    include snippets/tls-common.conf;
    # plugin: dir
    location = /plugin-check {
        return 204;
    }
    location / {
        proxy_pass http://10.0.0.7:9000;
        include snippets/proxy-common.conf;
        # plugin: dir
        proxy_set_header X-Plugin "on";
    }
}' "$(cat "$SITES_AVAILABLE/mix.conf")" "directives placed in both proxying server blocks"
    enable_site mix </dev/null >/dev/null 2>&1; assert_eq 0 $? "nginx -t accepts it"

    site_create app app.lan.example.com 127.0.0.1:8080 https </dev/null >/dev/null 2>&1
    assert_count "$(cat "$SITES_AVAILABLE/app.conf")" "location = /plugin-check" 1 "https: not in the redirect block"
}

t_directives_invalid_output_refused() {
    make_plugin dir "location-directives"
    fixture_configured; load_app_tp
    new_site app http
    plugin_enable dir >/dev/null 2>&1
    local original out rc text expected
    original=$(cat "$SITES_AVAILABLE/app.conf")
    local -a cases=(
        '}|line 1: '"'"'}'"'"' without a matching '"'"'{'"'"
        '} location / {|line 1: '"'"'}'"'"' without a matching '"'"'{'"'"
        'if ($x) {|line end: '"'"'{'"'"' not closed'
        'add_header X 1; # }|line 1: '"'"'#'"'"' is not allowed'
        $'proxy_set_header X "\033[2J";|line 1: control character'
    )
    for text in "${cases[@]}"; do
        expected="${text#*|}"
        printf '%s\n' "${text%%|*}" > "$TP/dir/location-directives.out"
        out=$(site_update app app.lan.example.com 127.0.0.1:9090 http 2>&1 </dev/null); rc=$?
        assert_eq 1 "$rc" "refused: ${expected}"
        assert_contains "$out" "Plugin 'dir' produced invalid location-directives output ($expected)" "reason: $expected"
        assert_eq "$original" "$(cat "$SITES_AVAILABLE/app.conf")" "config untouched: $expected"
    done
    assert_db '.app.backend == "127.0.0.1:8080"' "db restored"
}

# ==========================================================
# Dependencies
# ==========================================================
t_dependencies() {
    make_plugin base ""; make_plugin mid "validate-site" "DEPENDS=base"; make_plugin top "" "DEPENDS=mid"
    make_plugin orphan "" "DEPENDS=ghost"; make_plugin onorphan "" "DEPENDS=orphan"
    make_plugin cyc-a "" "DEPENDS=cyc-b"; make_plugin cyc-b "" "DEPENDS=cyc-a"; make_plugin oncyc "" "DEPENDS=cyc-a"
    fixture_configured; load_app_tp
    plugins_load
    assert_eq "base mid top" "${PLUGIN_ORDER[*]}" "resolvable plugins ordered"
    assert_eq "missing dependency 'ghost'" "${PLUGIN_ERROR[orphan]}" "missing dependency"
    assert_eq "dependency 'orphan' is unavailable" "${PLUGIN_ERROR[onorphan]}" "unavailable dependency propagates"
    assert_eq "dependency cycle (unresolved: cyc-a cyc-b oncyc)" "${PLUGIN_ERROR[cyc-a]}" "cycle detected"
    assert_eq "${PLUGIN_ERROR[cyc-a]}" "${PLUGIN_ERROR[cyc-b]}" "both cycle members refused"
    assert_eq "${PLUGIN_ERROR[cyc-a]}" "${PLUGIN_ERROR[oncyc]}" "plugin waiting on a cycle refused"

    local out rc
    out=$(plugin_enable top 2>&1); rc=$?
    assert_eq 1 "$rc" "dependency not enabled: refused"
    assert_contains "$out" "Plugin 'top' requires 'mid': enable 'mid' first" "reason shown"
    plugin_enable cyc-a >/dev/null 2>&1; assert_eq 1 $? "cycle member cannot be enabled"
    plugin_enable base >/dev/null 2>&1; plugin_enable mid >/dev/null 2>&1; plugin_enable top >/dev/null 2>&1
    assert_eq $'base\nmid\ntop' "$(enabled_ids)" "chain enabled in order"
    out=$(plugin_disable mid 2>&1); rc=$?
    assert_eq 1 "$rc" "disabling a needed plugin refused"
    assert_contains "$out" "Plugin 'top' depends on 'mid': disable 'top' first" "reason shown"
    assert_eq $'base\nmid\ntop' "$(enabled_ids)" "nothing changed"

    # Hand-edited list: a dependency that is not enabled stops the hooks.
    printf '%s\n' mid > "$MANAGER_DIR/plugins.enabled"
    out=$(site_create web web.lan.example.com 127.0.0.1:8080 http 2>&1 </dev/null); rc=$?
    assert_eq 2 "$rc" "site_create refused"
    assert_contains "$out" "Plugin 'mid' is enabled but its dependencies are not: base" "reason shown"

    # A dependency removed from disk.
    printf '%s\n' base mid > "$MANAGER_DIR/plugins.enabled"
    rm -rf "$TP/base"
    out=$(site_create web web.lan.example.com 127.0.0.1:8080 http 2>&1 </dev/null); rc=$?
    assert_eq 2 "$rc" "site_create refused"
    assert_contains "$out" "Plugin 'base' is enabled but not installed" "missing plugin reported"
    assert_contains "$out" "Plugin 'mid' is enabled but unavailable: missing dependency 'base'" "dependent reported"
    assert_eq "" "$(calls)" "no plugin ran"
}

# ==========================================================
# Settings and secrets
# ==========================================================
t_settings_parsed_as_data() {
    make_plugin s "validate-site"
    fixture_configured; load_app_tp
    plugin_enable s >/dev/null 2>&1
    mkdir -p "$MANAGER_DIR/plugins"
    cat > "$MANAGER_DIR/plugins/s.conf" <<'EOF'
# settings for s
GREETING="hello world"
CMD=$(touch /tmp/pwned)
TICK=`touch /tmp/pwned2`
SEMI=a; touch /tmp/pwned3
QUOTE='say "hi"'
EMPTY=
EOF
    site_create web web.lan.example.com 127.0.0.1:8080 http </dev/null >/dev/null 2>&1
    assert_eq 0 $? "site created"
    local env
    env=$(cat "$TP/s/validate-site.env")
    assert_contains "$env" "NM_SETTING_GREETING=hello world" "quoted value"
    assert_contains "$env" 'NM_SETTING_CMD=$(touch /tmp/pwned)' "command substitution kept as text"
    assert_contains "$env" 'NM_SETTING_TICK=`touch /tmp/pwned2`' "backticks kept as text"
    assert_contains "$env" 'NM_SETTING_SEMI=a; touch /tmp/pwned3' "semicolon kept as text"
    assert_contains "$env" 'NM_SETTING_QUOTE=say "hi"' "inner quotes kept"
    assert_contains "$env" "NM_SETTING_EMPTY=" "empty value"
    assert_no_file /tmp/pwned "settings never executed"
    assert_no_file /tmp/pwned2 "settings never executed (backticks)"
    assert_no_file /tmp/pwned3 "settings never executed (;)"
}

t_settings_invalid_refused() {
    make_plugin s "validate-site"
    fixture_configured; load_app_tp
    plugin_enable s >/dev/null 2>&1
    mkdir -p "$MANAGER_DIR/plugins"
    local content expected out rc
    local -a cases=(
        'export TOKEN=TOPSECRET|line 1: expected KEY=VALUE'
        'token=TOPSECRET|line 1: expected KEY=VALUE'
        'TOKEN = TOPSECRET|line 1: expected KEY=VALUE'
        $'# c\nTOKEN=TOPSECRET\nTOKEN=TOPSECRET|line 3: TOKEN repeated'
        $'TOKEN=TOP\033SECRET|line 1: control character in TOKEN'
    )
    for content in "${cases[@]}"; do
        expected="${content#*|}"
        printf '%s\n' "${content%%|*}" > "$MANAGER_DIR/plugins/s.conf"
        rm -f "$CALLS"
        out=$(site_create web web.lan.example.com 127.0.0.1:8080 http 2>&1 </dev/null); rc=$?
        assert_eq 2 "$rc" "refused: $expected"
        assert_contains "$out" "Plugin 's' not run: invalid settings $MANAGER_DIR/plugins/s.conf ($expected)" "reason: $expected"
        assert_not_contains "$out" "SECRET" "value not shown: $expected"
        assert_eq "" "$(calls)" "plugin not run: $expected"
    done
    assert_not_contains "$(cat /var/log/nginx-manager/manager.log)" "SECRET" "value not logged"
}

t_secret_permissions() {
    make_plugin sec "validate-site"
    fixture_configured; load_app_tp
    local out rc
    out=$(printf 's3cret-value' | plugin_secret_set sec token 2>&1); rc=$?
    assert_eq 0 "$rc" "saved"
    assert_contains "$out" "Secret 'token' saved for plugin 'sec'" "reported"
    assert_not_contains "$out" "s3cret" "value not printed"
    assert_mode "$MANAGER_DIR/secrets" 700
    assert_mode "$MANAGER_DIR/secrets/sec" 700
    assert_mode "$MANAGER_DIR/secrets/sec/token" 600
    assert_eq "s3cret-value" "$(cat "$MANAGER_DIR/secrets/sec/token")" "value stored exactly"

    ( umask 000; printf 'new-value' | plugin_secret_set sec token >/dev/null 2>&1 )
    assert_eq "new-value" "$(cat "$MANAGER_DIR/secrets/sec/token")" "overwritten"
    assert_mode "$MANAGER_DIR/secrets/sec/token" 600 "mode 600 even with umask 000"
    assert_eq "token" "$(ls -A "$MANAGER_DIR/secrets/sec")" "no temp files left"

    local name
    for name in ../x .hidden a/b "" "with space"; do
        printf 'v' | plugin_secret_set sec "$name" >/dev/null 2>&1
        assert_eq 2 $? "secret name '$name' rejected"
    done
    printf '' | plugin_secret_set sec empty >/dev/null 2>&1; assert_eq 2 $? "empty value rejected"
    assert_eq "token" "$(ls -A "$MANAGER_DIR/secrets/sec")" "nothing else created"
    printf 'v' | plugin_secret_set nope token >/dev/null 2>&1; assert_eq 2 $? "unknown plugin rejected"
    mkdir -p /tmp/nm-plugins-elsewhere; ln -s /tmp/nm-plugins-elsewhere "$MANAGER_DIR/secrets/link"
    make_plugin link ""
    printf 'v' | plugin_secret_set link token >/dev/null 2>&1; assert_eq 1 $? "symlinked secret directory refused"
    assert_eq "" "$(ls -A /tmp/nm-plugins-elsewhere)" "nothing written through the symlink"

    plugin_enable sec >/dev/null 2>&1
    site_create web web.lan.example.com 127.0.0.1:8080 http </dev/null >/dev/null 2>&1
    assert_contains "$(cat "$TP/sec/validate-site.env")" "NM_PLUGIN_SECRETS=$MANAGER_DIR/secrets/sec" "plugin gets the directory"
    assert_not_contains "$(cat "$TP/sec/validate-site.env")" "new-value" "value not in the environment"
    assert_not_contains "$(cat /var/log/nginx-manager/manager.log)" "-value" "value not logged"
}

# ==========================================================
# Per-site plugin data
# ==========================================================
t_site_data_preserved() {
    make_plugin a ""; make_plugin b ""
    fixture_configured; load_app_tp
    new_site app http; new_site other http; enable_site app >/dev/null 2>&1
    db_write test app '.app.created = "2025-01-01T00:00:00Z" | .app.note = "hand-added"'
    plugin_site_set app a '{"k":[1,{"deep":true}]}' >/dev/null 2>&1; assert_eq 0 $? "saved"
    plugin_site_set app b '{"z":1}' >/dev/null 2>&1
    plugin_site_set other a '{"o":1}' >/dev/null 2>&1
    local keep='.app.created == "2025-01-01T00:00:00Z" and .app.note == "hand-added"
        and .app.plugins == {"a":{"k":[1,{"deep":true}]},"b":{"z":1}} and .other.plugins == {"a":{"o":1}}'
    assert_db "$keep" "stored per site and plugin"

    site_update app app.lan.example.com 127.0.0.1:9090 http </dev/null >/dev/null 2>&1
    assert_db "$keep and .app.backend == \"127.0.0.1:9090\"" "kept by edit"
    site_update app app.lan.example.com nonexistent.invalid:80 http </dev/null >/dev/null 2>&1
    assert_db "$keep and .app.backend == \"127.0.0.1:9090\"" "kept by edit rollback"
    disable_site app </dev/null >/dev/null 2>&1; enable_site app </dev/null >/dev/null 2>&1
    assert_db "$keep and .app.enabled == true" "kept by disable/enable"
    regenerate_site_safe app </dev/null >/dev/null 2>&1
    assert_db "$keep" "kept by regenerate"

    plugin_site_set app a '{"k":2}' >/dev/null 2>&1
    assert_db '.app.plugins == {"a":{"k":2},"b":{"z":1}} and .app.created == "2025-01-01T00:00:00Z" and .app.note == "hand-added"' \
        "update replaces only that plugin's data"
    assert_eq '{"k":2}' "$(plugin_site_get app a)" "read back"
    plugin_site_set app a '{}' >/dev/null 2>&1
    assert_db '.app.plugins == {"b":{"z":1}}' "{} removes only that plugin's data"
    assert_eq '{}' "$(plugin_site_get app a)" "absent data reads as {}"

    local before data
    before=$(db_snapshot)
    for data in '[1]' '"x"' 'nope' '{} {}' '' 'null'; do
        plugin_site_set app b "$data" >/dev/null 2>&1; assert_eq 2 $? "'$data' rejected"
    done
    plugin_site_set nope a '{}' >/dev/null 2>&1; assert_eq 2 $? "unknown site rejected"
    plugin_site_set ../app a '{}' >/dev/null 2>&1; assert_eq 2 $? "invalid site name rejected"
    plugin_site_set app ghost '{"x":1}' >/dev/null 2>&1; assert_eq 2 $? "data for an unknown plugin rejected"
    assert_eq "$before" "$(db_snapshot)" "db unchanged by rejected input"
}

# ==========================================================
# Example plugin (plugins/example)
# ==========================================================
t_example_plugin() {
    fixture_configured; load_app
    PLUGIN_DIR=/src/plugins
    plugins_load
    assert_eq "" "${PLUGIN_ERROR[example]}" "example manifest valid"
    assert_eq "location-directives" "${PLUGIN_HOOKS[example]}" "declares one hook"

    new_site app https; new_site web http web.lan.example.com 127.0.0.1:3000
    golden_compare https.conf "$SITES_AVAILABLE/app.conf"
    plugin_enable example >/dev/null 2>&1; assert_eq 0 $? "enabled"
    golden_compare https.conf "$SITES_AVAILABLE/app.conf"
    regenerate_site_safe app </dev/null >/dev/null 2>&1
    golden_compare https.conf "$SITES_AVAILABLE/app.conf"
    regenerate_site_safe web </dev/null >/dev/null 2>&1
    golden_compare http.conf "$SITES_AVAILABLE/web.conf"

    plugin_site_set app example '{"header": true}' >/dev/null 2>&1
    enable_site app </dev/null >/dev/null 2>&1
    regenerate_site_safe app </dev/null >/dev/null 2>&1; assert_eq 0 $? "opted-in site regenerated, nginx -t passes"
    local conf
    conf=$(cat "$SITES_AVAILABLE/app.conf")
    assert_contains "$conf" $'        include snippets/proxy-common.conf;\n        # plugin: example\n        proxy_set_header X-Example-Greeting "hello";\n    }' \
        "header added inside location /"
    assert_eq "$(cat /src/tests/golden/https.conf)" "$(grep -v -e '# plugin: example' -e 'X-Example-Greeting' <<< "$conf")" \
        "nothing else changed"

    mkdir -p "$MANAGER_DIR/plugins"
    echo 'GREETING="hi there"' > "$MANAGER_DIR/plugins/example.conf"
    regenerate_site_safe app </dev/null >/dev/null 2>&1
    assert_contains "$(cat "$SITES_AVAILABLE/app.conf")" 'proxy_set_header X-Example-Greeting "hi there";' "setting used"

    echo "GREETING='a\"b'" > "$MANAGER_DIR/plugins/example.conf"
    local out rc
    out=$(regenerate_site_safe app 2>&1 </dev/null); rc=$?
    assert_eq 1 "$rc" "invalid setting refused"
    assert_contains "$out" "example: GREETING in $MANAGER_DIR/plugins/example.conf must be" "plugin explains"
    assert_contains "$(cat "$SITES_AVAILABLE/app.conf")" '"hi there"' "previous config kept"

    plugin_disable example >/dev/null 2>&1
    regenerate_site_safe app </dev/null >/dev/null 2>&1
    golden_compare https.conf "$SITES_AVAILABLE/app.conf"
}

t_plugin_dir_default() {
    load_app
    if [[ "$APP" == /src/nginx-site.sh ]]; then
        assert_eq /src/plugins "$PLUGIN_DIR" "checkout uses its plugins/ directory"
    else
        assert_eq /usr/local/lib/nginx-manager/plugins "$PLUGIN_DIR" "bundle uses the installed directory"
    fi
}

# ==========================================================
# CLI
# ==========================================================
t_plugins_menu() {
    make_plugin a ""
    fixture_configured; load_app_tp
    new_site app http
    local out
    out=$(plugins_menu <<< $'e\na\n\nq\n' 2>&1)
    assert_contains "$out" "Plugin 'a' enabled" "enabled from the menu"
    assert_matches "$out" 'a +● ENABLED' "listed as enabled"
    assert_eq "a" "$(enabled_ids)" "persisted"
    out=$(plugins_menu <<< $'d\na\n\nq\n' 2>&1)
    assert_contains "$out" "Plugin 'a' disabled" "disabled from the menu"
    assert_eq "" "$(enabled_ids)" "persisted"

    out=$(plugins_menu <<< $'s\na\ntoken\ns3cret\n\nq\n' 2>&1)
    assert_eq "s3cret" "$(cat "$MANAGER_DIR/secrets/a/token")" "secret saved from the menu"
    assert_not_contains "$out" "s3cret" "secret not echoed"

    plugins_menu <<< $'p\n1\na\n{"x":1}\n\nq\n' >/dev/null 2>&1
    assert_db '.app.plugins.a == {"x":1}' "site data saved from the menu"

    plugins_menu </dev/null >/dev/null 2>&1; pass "closed input leaves the menu"

    out=$(run_app '5\nq\nq\n')
    assert_contains "$out" "[5] Plugins" "main menu entry"
    assert_contains "$out" "[E] Enable" "plugins menu opens"
}

# ==========================================================
# Review regressions
# ==========================================================
# A directive hook that leaves a background process holding its stdout must
# not keep the manager waiting for that output to close.
t_directives_background_child_does_not_hang() {
    mkdir -p "$TP/bg"
    printf '%s\n' "ID=bg" "NAME=bg" "VERSION=1.0.0" "API=1" "HOOKS=location-directives" > "$TP/bg/manifest.conf"
    cat > "$TP/bg/plugin.sh" <<'PLUGIN'
#!/bin/bash
sleep 25 2>/dev/null &
echo 'proxy_set_header X-Bg "1";'
PLUGIN
    fixture_configured; load_app_tp
    plugin_enable bg >/dev/null 2>&1
    local start=$SECONDS rc
    site_create web web.lan.example.com 127.0.0.1:8080 http </dev/null >/tmp/nm-plugins-out 2>&1; rc=$?
    assert_eq 0 "$rc" "site created"
    assert_eq 1 "$(( SECONDS - start < 10 ))" "returned without waiting for the background process"
    assert_contains "$(cat "$SITES_AVAILABLE/web.conf")" 'proxy_set_header X-Bg "1";' "output still collected"
    assert_eq "" "$(ls -A /tmp | grep '^nm-hook\.')" "capture file removed"
}

# A plugin that ignores SIGTERM is killed shortly after the time limit.
t_hook_timeout_term_ignored() {
    make_plugin stubborn "validate-site"
    cat > "$TP/stubborn/plugin.sh" <<'PLUGIN'
#!/bin/bash
trap '' TERM
sleep 30
PLUGIN
    fixture_configured; load_app_tp
    plugin_enable stubborn >/dev/null 2>&1
    PLUGIN_HOOK_TIMEOUT=1
    local out rc start=$SECONDS
    out=$(site_create web web.lan.example.com 127.0.0.1:8080 http 2>&1 </dev/null); rc=$?
    assert_eq 2 "$rc" "rejected"
    assert_eq 1 "$(( SECONDS - start < 15 ))" "killed instead of waited for"
    assert_contains "$out" "Plugin 'stubborn' timed out in validate-site for 'web' (limit 1s)" "reported as a time-out"
    assert_db 'has("web") | not' "nothing saved"
}

# A dependency cycle among enabled plugins (e.g. after an update) must not
# leave both impossible to disable.
t_disable_enabled_cycle() {
    make_plugin a ""; make_plugin b "" "DEPENDS=a"
    fixture_configured; load_app_tp
    plugin_enable a >/dev/null 2>&1; plugin_enable b >/dev/null 2>&1
    make_plugin a "" "DEPENDS=b"
    local out rc
    out=$(plugin_disable a 2>&1); rc=$?
    assert_eq 0 "$rc" "cycle member can be disabled"
    plugin_disable b >/dev/null 2>&1; assert_eq 0 $? "and the other one"
    assert_eq "" "$(enabled_ids)" "both disabled"

    # A dependent that can still run keeps its dependency enabled.
    make_plugin a ""
    plugin_enable a >/dev/null 2>&1; plugin_enable b >/dev/null 2>&1
    out=$(plugin_disable a 2>&1); rc=$?
    assert_eq 1 "$rc" "working dependent still protects its dependency"
}

# NM_SITE_ENABLED follows the sites-enabled symlink, not a stale db flag.
t_enabled_state_from_symlink() {
    make_plugin st "validate-site site-applied"
    fixture_configured; load_app_tp
    new_site app http
    db_update_enabled app true >/dev/null 2>&1
    plugin_enable st >/dev/null 2>&1
    site_update app app.lan.example.com 127.0.0.1:9090 http </dev/null >/dev/null 2>&1
    assert_contains "$(cat "$TP/st/validate-site.env")" "NM_SITE_ENABLED=false" "stale db flag not passed on"
    enable_site app </dev/null >/dev/null 2>&1
    assert_contains "$(cat "$TP/st/site-applied.env")" "NM_SITE_ENABLED=true" "enabled site reported enabled"
}

# validate-site sees the proposed values even when the db cannot be read.
t_validate_sees_proposal_with_broken_db() {
    make_plugin v "validate-site"
    fixture_configured; load_app_tp
    plugin_enable v >/dev/null 2>&1
    echo '{broken' > "$MANAGER_DIR/sites.json"
    site_create web web.lan.example.com 127.0.0.1:8080 http </dev/null >/dev/null 2>&1
    assert_contains "$(cat "$TP/v/validate-site.env")" "NM_SITE_DOMAIN=web.lan.example.com" "proposed domain passed"
    assert_eq '{broken' "$(db_snapshot)" "db untouched"
}

# Data of a plugin that is no longer installed can still be removed.
t_orphaned_site_data_removable() {
    make_plugin gone ""
    fixture_configured; load_app_tp
    new_site app http
    plugin_site_set app gone '{"x":1}' >/dev/null 2>&1
    rm -rf "$TP/gone"
    plugin_site_set app gone '{"y":1}' >/dev/null 2>&1; assert_eq 2 $? "new data for a missing plugin rejected"
    plugin_site_set app gone '{}' >/dev/null 2>&1; assert_eq 0 $? "its data can be removed"
    assert_db '.app.plugins | has("gone") | not' "removed"
}

# Every failure message tells the administrator what to do next.
t_failure_messages_give_recovery() {
    make_plugin m "site-applied site-deleted"
    echo 1 > "$TP/m/site-deleted.rc"
    fixture_configured; load_app_tp
    new_site app http
    plugin_enable m >/dev/null 2>&1
    echo 'server { this_is_not_a_directive; }' > "$SITES_ENABLED/broken.conf"
    local out
    out=$(site_delete app 2>&1 </dev/null)
    assert_contains "$out" "Site 'app' was only partly deleted" "partial delete reported"
    assert_not_contains "$out" "was applied" "plugin warning does not claim a complete change"
    assert_contains "$out" "Plugin hook site-deleted failed for 'app'; the site changes reported above stand" "plugin warning is neutral"
    rm -f "$SITES_ENABLED/broken.conf"

    printf '%s\n' '../x' > "$MANAGER_DIR/plugins.enabled"
    out=$(site_create web web.lan.example.com 127.0.0.1:8080 http 2>&1 </dev/null)
    assert_contains "$out" "fix or remove $MANAGER_DIR/plugins.enabled" "invalid list: recovery shown"
}
