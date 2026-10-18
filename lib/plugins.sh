#!/bin/bash
# ==========================================================
# NGINX Manager Pro - plugins
# Sourced by nginx-site.sh: defines state and functions only.
#
# A plugin is a directory $PLUGIN_DIR/<id>/ with a manifest.conf (read as
# data, never executed) and, if it declares hooks, a plugin.sh that the
# core runs as a separate bash process for each hook. Plugins are trusted
# local code running with the manager's privileges: this is not a sandbox.
# docs/PLUGINS.md documents the format and the hook contract.
# ==========================================================

# Contract version this manager implements (manifest API=).
PLUGIN_API=1
# Hooks of API 1. Blocking hooks stop the operation when a plugin fails;
# informational ones only report the failure.
PLUGIN_HOOKS_BLOCKING="validate-site server-directives location-directives"
PLUGIN_HOOKS_INFO="site-applied site-deleted"
PLUGIN_HOOK_TIMEOUT=30
PLUGIN_HOOK_KILL_AFTER=5

# Filled by plugins_load:
#   PLUGIN_IDS        plugin directories with a valid ID as name, sorted
#   PLUGIN_BAD_DIRS   other directory names found in $PLUGIN_DIR
#   PLUGIN_ERROR[id]  why the plugin is unavailable (unset: available)
#   PLUGIN_NAME/VERSION/DESC/DEPENDS/HOOKS[id]   manifest fields
#   PLUGIN_ORDER      available plugins in hook execution order
PLUGIN_IDS=() PLUGIN_BAD_DIRS=() PLUGIN_ORDER=()
declare -gA PLUGIN_ERROR=() PLUGIN_NAME=() PLUGIN_VERSION=() PLUGIN_DESC=() \
    PLUGIN_DEPENDS=() PLUGIN_HOOKS=()
# Filled by plugins_read_enabled: enabled IDs, sorted.
PLUGINS_ON=()
PLUGINS_ENABLED_ERROR=""
# Directives collected by the last plugin_run_hook *-directives call.
PLUGIN_OUTPUT=""
PLUGIN_KV_ERROR=""

# ==========================================================
# MANIFESTS AND SETTINGS
# ==========================================================
# plugin_read_kv <file> <assoc-array-name>
# Reads a manifest or settings file as data - it is never executed - into
# the named associative array. Format, one per line:
#   KEY=VALUE   KEY matches [A-Z][A-Z0-9_]*; VALUE may be empty, or wrapped
#               in one pair of '...' or "..." (taken literally, no escapes);
#               whitespace around the line is ignored
#   # comment   blank lines and lines starting with # are skipped
# Anything else, a repeated key, or a control character in a value rejects
# the file: returns 1 with PLUGIN_KV_ERROR = "line N: reason". Values never
# appear in the error.
plugin_read_kv() {
    local file="$1" line key value n=0
    local -n __kv_out="$2"
    __kv_out=()
    PLUGIN_KV_ERROR=""
    if [[ ! -f "$file" ]]; then
        PLUGIN_KV_ERROR="not a regular file"
        return 1
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((n++))
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue

        if [[ ! "$line" =~ ^[[:space:]]*([A-Z][A-Z0-9_]*)=(.*[^[:space:]])?[[:space:]]*$ ]]; then
            PLUGIN_KV_ERROR="line $n: expected KEY=VALUE"
            return 1
        fi
        key="${BASH_REMATCH[1]}" value="${BASH_REMATCH[2]}"
        if [[ "$value" =~ ^\"([^\"]*)\"$ || "$value" =~ ^\'([^\']*)\'$ ]]; then
            value="${BASH_REMATCH[1]}"
        fi
        if [[ "${value//$'\t'/ }" =~ [[:cntrl:]] ]]; then
            PLUGIN_KV_ERROR="line $n: control character in $key"
            return 1
        fi
        if [[ -n "${__kv_out[$key]+set}" ]]; then
            PLUGIN_KV_ERROR="line $n: $key repeated"
            return 1
        fi
        __kv_out[$key]="$value"
    done < "$file"
}

# Prints the keys of the named associative array, sorted.
plugin_sorted_keys() {
    local -n __keys_of="$1"
    ((${#__keys_of[@]})) || return 0
    printf '%s\n' "${!__keys_of[@]}" | LC_ALL=C sort
}

# Validates $PLUGIN_DIR/<id>/manifest.conf and records its fields, or the
# reason in PLUGIN_ERROR[<id>].
plugin_load_manifest() {
    local id="$1" dir="$PLUGIN_DIR/$1" key word err=""
    local -A manifest=() seen=()
    local words=()

    if [[ ! -f "$dir/manifest.conf" ]]; then
        PLUGIN_ERROR[$id]="missing manifest.conf"
        return
    fi
    if ! plugin_read_kv "$dir/manifest.conf" manifest; then
        PLUGIN_ERROR[$id]="manifest.conf $PLUGIN_KV_ERROR"
        return
    fi

    while IFS= read -r key; do
        case "$key" in
            ID|NAME|VERSION|API|DESCRIPTION|DEPENDS|HOOKS) ;;
            *) PLUGIN_ERROR[$id]="manifest.conf: unknown key $key"; return ;;
        esac
    done < <(plugin_sorted_keys manifest)

    if [[ -z "${manifest[ID]}" ]]; then
        err="ID is missing"
    elif [[ "${manifest[ID]}" != "$id" ]]; then
        # The directory name is the ID, so two plugins can never share one:
        # a copy that still claims another plugin's ID is refused.
        if validate_plugin_id "${manifest[ID]}" && [[ -d "$PLUGIN_DIR/${manifest[ID]}" ]]; then
            err="duplicate ID '${manifest[ID]}' (already used by $PLUGIN_DIR/${manifest[ID]})"
        else
            err="ID '${manifest[ID]}' does not match the directory name '$id'"
        fi
    elif [[ -z "${manifest[NAME]}" ]]; then
        err="NAME is missing"
    elif ((${#manifest[NAME]} > 64)); then
        err="NAME is longer than 64 characters"
    elif [[ ! "${manifest[VERSION]}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        err="VERSION must be MAJOR.MINOR.PATCH"
    elif [[ -z "${manifest[API]}" ]]; then
        err="API is missing"
    elif [[ "${manifest[API]}" != "$PLUGIN_API" ]]; then
        err="unsupported API version '${manifest[API]}' (this manager supports $PLUGIN_API)"
    elif ((${#manifest[DESCRIPTION]} > 200)); then
        err="DESCRIPTION is longer than 200 characters"
    fi
    if [[ -n "$err" ]]; then
        PLUGIN_ERROR[$id]="$err"
        return
    fi

    read -ra words <<< "${manifest[DEPENDS]}"
    for word in "${words[@]}"; do
        if ! validate_plugin_id "$word"; then
            err="DEPENDS: invalid plugin ID '$word'"
        elif [[ "$word" == "$id" ]]; then
            err="DEPENDS: a plugin cannot depend on itself"
        elif [[ -n "${seen[$word]}" ]]; then
            err="DEPENDS: '$word' listed twice"
        fi
        [[ -n "$err" ]] && break
        seen[$word]=1
    done
    PLUGIN_DEPENDS[$id]="${words[*]}"

    seen=()
    read -ra words <<< "${manifest[HOOKS]}"
    for word in "${words[@]}"; do
        [[ -n "$err" ]] && break
        if [[ " $PLUGIN_HOOKS_BLOCKING $PLUGIN_HOOKS_INFO " != *" $word "* ]]; then
            err="HOOKS: unknown hook '$word'"
        elif [[ -n "${seen[$word]}" ]]; then
            err="HOOKS: '$word' listed twice"
        fi
        seen[$word]=1
    done
    if [[ -z "$err" ]] && ((${#words[@]})) && [[ ! -f "$dir/plugin.sh" ]]; then
        err="declares hooks but has no plugin.sh"
    fi
    if [[ -n "$err" ]]; then
        PLUGIN_ERROR[$id]="$err"
        return
    fi

    PLUGIN_NAME[$id]="${manifest[NAME]}"
    PLUGIN_VERSION[$id]="${manifest[VERSION]}"
    PLUGIN_DESC[$id]="${manifest[DESCRIPTION]}"
    PLUGIN_HOOKS[$id]="${words[*]}"
}

# ==========================================================
# DISCOVERY
# ==========================================================
# Scans $PLUGIN_DIR. Only manifests are read; no plugin code runs. A plugin
# is available when its manifest is valid and so are all its dependencies,
# without cycles. PLUGIN_ORDER lists the available plugins so that each comes
# after its dependencies, otherwise by ID (C collation).
plugins_load() {
    PLUGIN_IDS=() PLUGIN_BAD_DIRS=() PLUGIN_ORDER=()
    PLUGIN_ERROR=() PLUGIN_NAME=() PLUGIN_VERSION=() PLUGIN_DESC=() PLUGIN_DEPENDS=() PLUGIN_HOOKS=()
    [[ -d "$PLUGIN_DIR" ]] || return 0

    local path name id dep deps
    for path in "$PLUGIN_DIR"/*/; do
        [[ -d "$path" ]] || continue
        name="$(basename "$path")"
        if validate_plugin_id "$name"; then
            PLUGIN_IDS+=("$name")
        else
            PLUGIN_BAD_DIRS+=("$name")
        fi
    done
    ((${#PLUGIN_IDS[@]})) || return 0
    mapfile -t PLUGIN_IDS < <(printf '%s\n' "${PLUGIN_IDS[@]}" | LC_ALL=C sort)

    for id in "${PLUGIN_IDS[@]}"; do
        plugin_load_manifest "$id"
    done

    # A plugin is unavailable when one of its dependencies is (repeat until
    # nothing changes, so this follows chains).
    local changed=1
    while ((changed)); do
        changed=0
        for id in "${PLUGIN_IDS[@]}"; do
            [[ -n "${PLUGIN_ERROR[$id]}" ]] && continue
            read -ra deps <<< "${PLUGIN_DEPENDS[$id]}"
            for dep in "${deps[@]}"; do
                if ! plugin_found "$dep"; then
                    PLUGIN_ERROR[$id]="missing dependency '$dep'"
                elif [[ -n "${PLUGIN_ERROR[$dep]}" ]]; then
                    PLUGIN_ERROR[$id]="dependency '$dep' is unavailable"
                else
                    continue
                fi
                changed=1
                break
            done
        done
    done

    # Order: repeatedly take the first plugin (by ID) whose dependencies are
    # all placed. Whatever cannot be placed is part of, or waits on, a cycle.
    local remaining=() i ready progress
    local -A placed=()
    for id in "${PLUGIN_IDS[@]}"; do
        [[ -z "${PLUGIN_ERROR[$id]}" ]] && remaining+=("$id")
    done
    while ((${#remaining[@]})); do
        progress=0
        for i in "${!remaining[@]}"; do
            id="${remaining[i]}" ready=1
            read -ra deps <<< "${PLUGIN_DEPENDS[$id]}"
            for dep in "${deps[@]}"; do
                [[ -n "${placed[$dep]}" ]] || { ready=0; break; }
            done
            if ((ready)); then
                PLUGIN_ORDER+=("$id")
                placed[$id]=1
                unset 'remaining[i]'
                progress=1
                break
            fi
        done
        ((progress)) || break
    done
    for id in "${remaining[@]}"; do
        PLUGIN_ERROR[$id]="dependency cycle (unresolved: ${remaining[*]})"
    done
}

plugin_found() { [[ " ${PLUGIN_IDS[*]} " == *" $1 "* ]]; }

# ==========================================================
# ENABLED LIST
# ==========================================================
# Reads plugins.enabled (one plugin ID per line, # comments and blank lines
# allowed) into PLUGINS_ON. A missing file means nothing is enabled. Any
# other line rejects the file: returns 1, PLUGINS_ON empty and
# PLUGINS_ENABLED_ERROR = "line N: reason".
plugins_read_enabled() {
    PLUGINS_ON=()
    PLUGINS_ENABLED_ERROR=""
    [[ -e "$PLUGINS_ENABLED" ]] || return 0
    if [[ ! -f "$PLUGINS_ENABLED" ]]; then
        PLUGINS_ENABLED_ERROR="not a regular file"
        return 1
    fi

    local line n=0 ids=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((n++))
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        if ! validate_plugin_id "$line"; then
            PLUGINS_ENABLED_ERROR="line $n: not a plugin ID"
            return 1
        fi
        ids+=("$line")
    done < "$PLUGINS_ENABLED"
    ((${#ids[@]})) || return 0
    mapfile -t PLUGINS_ON < <(printf '%s\n' "${ids[@]}" | LC_ALL=C sort -u)
}

plugin_is_enabled() { [[ " ${PLUGINS_ON[*]} " == *" $1 "* ]]; }

# Atomically replaces plugins.enabled with the given IDs.
plugins_write_enabled() {
    local tmp
    tmp=$(mktemp -p "$MANAGER_DIR") || {
        msg_error "Failed to create temporary file for $PLUGINS_ENABLED"
        return 1
    }
    if ! {
        echo "# Enabled NGINX Manager plugins, one ID per line"
        if (($#)); then printf '%s\n' "$@" | LC_ALL=C sort -u; fi
    } > "$tmp" || ! mv -f "$tmp" "$PLUGINS_ENABLED"; then
        rm -f "$tmp"
        msg_error "Failed to write $PLUGINS_ENABLED"
        log "Plugin list not updated: could not write $PLUGINS_ENABLED"
        return 1
    fi
}

# plugin_enable <id>
# Adds an available plugin to plugins.enabled; its dependencies must be
# enabled first. Nothing else changes: no plugin code runs and no nginx
# configuration is touched until a site is next created, edited or
# regenerated.
# Returns 0 enabled (or already was), 1 refused or failed, 2 invalid/unknown ID.
plugin_enable() {
    local id="$1" dep deps
    if ! validate_plugin_id "$id"; then
        msg_error "Invalid plugin ID: '$id'"
        return 2
    fi
    plugins_load
    if ! plugin_found "$id"; then
        msg_error "Plugin '$id' not found in $PLUGIN_DIR"
        return 2
    fi
    if [[ -n "${PLUGIN_ERROR[$id]}" ]]; then
        msg_error "Plugin '$id' cannot be enabled: ${PLUGIN_ERROR[$id]}"
        return 1
    fi
    if ! plugins_read_enabled; then
        msg_error "Invalid $PLUGINS_ENABLED ($PLUGINS_ENABLED_ERROR); fix or remove it first"
        return 1
    fi
    if plugin_is_enabled "$id"; then
        msg_success "Plugin '$id' is already enabled"
        return 0
    fi
    read -ra deps <<< "${PLUGIN_DEPENDS[$id]}"
    for dep in "${deps[@]}"; do
        if ! plugin_is_enabled "$dep"; then
            msg_error "Plugin '$id' requires '$dep': enable '$dep' first"
            return 1
        fi
    done

    plugins_write_enabled "${PLUGINS_ON[@]}" "$id" || return 1
    msg_success "Plugin '$id' enabled"
    echo "Existing site configurations are unchanged until a site is edited or regenerated."
    log "Plugin enabled: $id"
}

# plugin_disable <id>
# Removes a plugin from plugins.enabled, also when it is no longer installed
# or valid. Refused while an enabled plugin that can run depends on it (a
# dependent that cannot run anyway, e.g. in a cycle, does not hold it). No
# plugin code runs and no nginx configuration is touched.
# Returns 0 disabled, 1 refused or failed, 2 invalid ID or not enabled.
plugin_disable() {
    local id="$1" other deps
    if ! validate_plugin_id "$id"; then
        msg_error "Invalid plugin ID: '$id'"
        return 2
    fi
    if ! plugins_read_enabled; then
        msg_error "Invalid $PLUGINS_ENABLED ($PLUGINS_ENABLED_ERROR); fix or remove it first"
        return 1
    fi
    if ! plugin_is_enabled "$id"; then
        msg_error "Plugin '$id' is not enabled"
        return 2
    fi
    plugins_load
    local keep=()
    for other in "${PLUGINS_ON[@]}"; do
        [[ "$other" == "$id" ]] && continue
        keep+=("$other")
        read -ra deps <<< "${PLUGIN_DEPENDS[$other]}"
        if [[ " ${deps[*]} " == *" $id "* ]] && plugin_is_active "$other"; then
            msg_error "Plugin '$other' depends on '$id': disable '$other' first"
            return 1
        fi
    done

    plugins_write_enabled "${keep[@]}" || return 1
    msg_success "Plugin '$id' disabled"
    echo "Existing site configurations are unchanged until a site is edited or regenerated."
    log "Plugin disabled: $id"
}

# Whether a plugin is enabled and able to run (call plugins_load and
# plugins_read_enabled first).
plugin_is_active() {
    local id="$1" dep deps
    plugin_is_enabled "$id" && plugin_found "$id" && [[ -z "${PLUGIN_ERROR[$id]}" ]] || return 1
    read -ra deps <<< "${PLUGIN_DEPENDS[$id]}"
    for dep in "${deps[@]}"; do
        plugin_is_enabled "$dep" || return 1
    done
}

# Reports every enabled plugin that cannot run. Returns 1 if there is one.
plugins_check_enabled() {
    local id rc=0
    for id in "${PLUGINS_ON[@]}"; do
        plugin_is_active "$id" && continue
        rc=1
        if ! plugin_found "$id"; then
            msg_error "Plugin '$id' is enabled but not installed in $PLUGIN_DIR"
        elif [[ -n "${PLUGIN_ERROR[$id]}" ]]; then
            msg_error "Plugin '$id' is enabled but unavailable: ${PLUGIN_ERROR[$id]}"
        else
            msg_error "Plugin '$id' is enabled but its dependencies are not: ${PLUGIN_DEPENDS[$id]}"
        fi
        log "Plugin $id is enabled but cannot run"
    done
    ((rc)) && echo "Fix the plugin, or disable it in the Plugins menu."
    return $rc
}

# ==========================================================
# HOOKS
# ==========================================================
# plugin_site_entry <site> [<domain> <backend> <tls>]
# Prints the site's database entry as compact JSON ({} if there is none),
# with the given values in place of the stored ones (a proposed change).
# "enabled" is taken from the sites-enabled symlink, not the db flag. If the
# db cannot be read, a proposal still carries its values.
plugin_site_entry() {
    local enabled=false
    [[ -L "$NGINX_ENABLED/$1.conf" ]] && enabled=true
    if (($# >= 4)); then
        local args=(--arg n "$1" --arg d "$2" --arg b "$3" --arg t "$4" --argjson e "$enabled")
        jq -c "${args[@]}" '(.[$n] // {}) + {domain:$d,backend:$b,tls:$t,enabled:$e}' "$SITES_DB" 2>/dev/null \
            || jq -nc "${args[@]}" '{domain:$d,backend:$b,tls:$t,enabled:$e}'
    else
        jq -c --arg n "$1" --argjson e "$enabled" '(.[$n] // {}) + {enabled:$e}' "$SITES_DB" 2>/dev/null \
            || echo '{}'
    fi
}

# plugin_run_hook <hook> <site> <site-entry-json>
# Runs <hook> for every enabled plugin that declares it, in PLUGIN_ORDER.
# With nothing enabled it does nothing. If an enabled plugin cannot run, no
# plugin runs and it fails: a hook is never silently skipped. Blocking hooks
# stop at the first failing plugin; informational ones run every plugin.
# The *-directives output is collected, checked and indented in
# PLUGIN_OUTPUT. Returns 1 if any plugin failed.
plugin_run_hook() {
    local hook="$1" site="$2" entry="$3" id rc=0
    [[ -n "$entry" ]] || entry='{}'
    PLUGIN_OUTPUT=""
    if ! plugins_read_enabled; then
        msg_error "Invalid $PLUGINS_ENABLED ($PLUGINS_ENABLED_ERROR); plugin hooks cannot run - fix or remove $PLUGINS_ENABLED"
        log "Plugin hook $hook not run for $site: invalid $PLUGINS_ENABLED"
        return 1
    fi
    ((${#PLUGINS_ON[@]})) || return 0
    plugins_load
    plugins_check_enabled || return 1

    for id in "${PLUGIN_ORDER[@]}"; do
        plugin_is_enabled "$id" || continue
        [[ " ${PLUGIN_HOOKS[$id]} " == *" $hook "* ]] || continue
        if ! plugin_exec "$id" "$hook" "$site" "$entry"; then
            rc=1
            [[ " $PLUGIN_HOOKS_BLOCKING " == *" $hook "* ]] && break
        fi
    done
    return $rc
}

# plugin_exec <id> <hook> <site> <site-entry-json>
# Runs "bash $PLUGIN_DIR/<id>/plugin.sh <hook> <site>" with stdin closed, a
# timeout, and the documented NM_* environment; settings are passed as
# NM_SETTING_<KEY>, secrets only as a directory path.
plugin_exec() {
    local id="$1" hook="$2" site="$3" entry="$4"
    local conf="$PLUGIN_CONF_DIR/$id.conf" key out status
    local -A settings=()

    if [[ -e "$conf" || -L "$conf" ]] && ! plugin_read_kv "$conf" settings; then
        msg_error "Plugin '$id' not run: invalid settings $conf ($PLUGIN_KV_ERROR)"
        log "Plugin $id not run for $hook: invalid settings $conf ($PLUGIN_KV_ERROR)"
        return 1
    fi

    local env=(
        NM_API="$PLUGIN_API" NM_HOOK="$hook" NM_PLUGIN_ID="$id"
        NM_PLUGIN_DIR="$PLUGIN_DIR/$id" NM_PLUGIN_CONFIG="$conf"
        NM_PLUGIN_SECRETS="$PLUGIN_SECRETS_DIR/$id" NM_SITE="$site"
        NM_SITE_DOMAIN="$(jq -r '.domain // ""' <<< "$entry")"
        NM_SITE_BACKEND="$(jq -r '.backend // ""' <<< "$entry")"
        NM_SITE_TLS="$(jq -r '.tls // ""' <<< "$entry")"
        NM_SITE_ENABLED="$(jq -r '.enabled == true' <<< "$entry")"
        NM_SITE_DATA="$(jq -c --arg p "$id" '.plugins[$p]? // {}' <<< "$entry")"
    )
    while IFS= read -r key; do
        env+=("NM_SETTING_$key=${settings[$key]}")
    done < <(plugin_sorted_keys settings)

    # A plugin that ignores SIGTERM is killed PLUGIN_HOOK_KILL_AFTER later.
    local run=(timeout -k "$PLUGIN_HOOK_KILL_AFTER" "$PLUGIN_HOOK_TIMEOUT"
        env "${env[@]}" bash "$PLUGIN_DIR/$id/plugin.sh" "$hook" "$site")
    local start=$SECONDS
    if [[ "$hook" == *-directives ]]; then
        # Captured through a file, not a pipe: a background process that kept
        # the plugin's stdout open would otherwise hold the manager up.
        local capture
        if ! capture=$(mktemp -t nm-hook.XXXXXX); then
            msg_error "Plugin '$id' not run: could not create a temporary file"
            return 1
        fi
        "${run[@]}" </dev/null > "$capture"
        status=$?
        out=$(cat "$capture")
        rm -f "$capture"
    else
        "${run[@]}" </dev/null
        status=$?
    fi

    if ((status == 124 || (status == 137 && SECONDS - start >= PLUGIN_HOOK_TIMEOUT))); then
        msg_error "Plugin '$id' timed out in $hook for '$site' (limit ${PLUGIN_HOOK_TIMEOUT}s)"
    elif ((status != 0)); then
        msg_error "Plugin '$id' failed in $hook for '$site' (exit $status)"
    fi
    if ((status != 0)); then
        log "Plugin $id failed in $hook for $site (exit $status)"
        return 1
    fi

    case "$hook" in
        server-directives) plugin_add_directives "$id" "$hook" "    " "$out" ;;
        location-directives) plugin_add_directives "$id" "$hook" "        " "$out" ;;
    esac
}

# plugin_add_directives <id> <hook> <indent> <output>
# Appends a plugin's directives to PLUGIN_OUTPUT, indented, under a
# "# plugin: <id>" line; no output adds nothing. The text goes into an nginx
# config, never into shell code. It is refused if it has control characters,
# a "#" (comments could hide braces), or braces that do not balance (it could
# close the block it is placed in). nginx -t still checks the directives.
plugin_add_directives() {
    local id="$1" hook="$2" indent="$3" text="$4"
    local line braces chunk="" err="" n=0 depth=0 i
    while IFS= read -r line; do
        ((n++))
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        if [[ "${line//$'\t'/ }" =~ [[:cntrl:]] ]]; then
            err="control character"
        elif [[ "$line" == *"#"* ]]; then
            err="'#' is not allowed"
        else
            braces="${line//[^\{\}]/}"
            for ((i = 0; i < ${#braces}; i++)); do
                if [[ "${braces:i:1}" == "{" ]]; then
                    ((depth += 1))
                elif ((--depth < 0)); then
                    err="'}' without a matching '{'"
                    break
                fi
            done
        fi
        [[ -n "$err" ]] && break
        chunk+="$indent$line"$'\n'
    done <<< "$text"
    if [[ -z "$err" ]] && ((depth > 0)); then
        n="end" err="'{' not closed"
    fi
    if [[ -n "$err" ]]; then
        msg_error "Plugin '$id' produced invalid $hook output (line $n: $err)"
        log "Plugin $id produced invalid $hook output (line $n: $err)"
        return 1
    fi
    [[ -n "$chunk" ]] && PLUGIN_OUTPUT+="$indent# plugin: $id"$'\n'"$chunk"
    return 0
}

# plugin_notify <hook> <site> [<site-entry-json>]
# Runs an informational hook once the core change is done. A failure is
# reported, but neither undoes nor re-labels that change.
plugin_notify() {
    local entry="${3:-$(plugin_site_entry "$2")}"
    plugin_run_hook "$1" "$2" "$entry" && return 0
    msg_warning "Plugin hook $1 failed for '$2'; the site changes reported above stand"
    return 0
}

# ==========================================================
# PER-SITE DATA AND SECRETS
# ==========================================================
# Prints a plugin's data for a site (compact JSON, {} if none).
plugin_site_get() { # site id
    jq -c --arg n "$1" --arg p "$2" '.[$n].plugins[$p]? // {}' "$SITES_DB"
}

# plugin_site_set <site> <id> <json-object>
# Stores a plugin's data under the site's "plugins" object; {} removes it.
# Every other field of the site and the other plugins' data are kept.
# Returns 0 saved, 1 failed, 2 invalid input.
plugin_site_set() {
    local site="$1" id="$2" data="$3"
    require_site "$site" || return 2
    if ! validate_plugin_id "$id"; then
        msg_error "Invalid plugin ID: '$id'"
        return 2
    fi
    if ! jq -ne --argjson d "$data" '$d | type == "object"' >/dev/null 2>&1; then
        msg_error "Plugin data must be one JSON object"
        return 2
    fi
    # Data of a plugin that is no longer installed can only be removed.
    plugins_load
    if ! plugin_found "$id" && ! jq -ne --argjson d "$data" '$d == {}' >/dev/null; then
        msg_error "Plugin '$id' not found in $PLUGIN_DIR (its data can only be removed, with {})"
        return 2
    fi
    db_write plugin_site_set "$site" --arg n "$site" --arg p "$id" --argjson d "$data" '
        if $d == {} then (if .[$n].plugins | type == "object" then del(.[$n].plugins[$p]) else . end)
        else .[$n].plugins = ((.[$n].plugins // {}) + {($p): $d}) end' || return 1
    log "Plugin data updated: $id for site $site"
}

# plugin_secret_set <id> <name>   (value on stdin)
# Stores one secret as $PLUGIN_SECRETS_DIR/<id>/<name>. The directories are
# 0700 and the file is 0600 before the value is written, then atomically
# moved into place. The value is never printed or logged.
# Returns 0 saved, 1 failed, 2 invalid input.
plugin_secret_set() {
    local id="$1" name="$2" dir="$PLUGIN_SECRETS_DIR/$1" tmp
    if ! validate_plugin_id "$id"; then
        msg_error "Invalid plugin ID: '$id'"
        return 2
    fi
    plugins_load
    if ! plugin_found "$id"; then
        msg_error "Plugin '$id' not found in $PLUGIN_DIR"
        return 2
    fi
    if [[ ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
        msg_error "Invalid secret name: '$name' (letters, numbers, . _ - ; not starting with .)"
        return 2
    fi
    if [[ -L "$dir" || ( -e "$dir" && ! -d "$dir" ) ]]; then
        msg_error "$dir is not a directory; secret not saved"
        return 1
    fi
    if ! mkdir -p -m 700 "$PLUGIN_SECRETS_DIR" "$dir" || ! chmod 700 "$PLUGIN_SECRETS_DIR" "$dir"; then
        msg_error "Failed to create $dir"
        return 1
    fi

    if ! tmp=$(mktemp -p "$dir") || ! chmod 600 "$tmp" || ! cat > "$tmp"; then
        [[ -n "$tmp" ]] && rm -f "$tmp"
        msg_error "Failed to write secret '$name' for plugin '$id'"
        log "Plugin secret not saved: $id/$name (write failed)"
        return 1
    fi
    if [[ ! -s "$tmp" ]]; then
        rm -f "$tmp"
        msg_error "Secret value cannot be empty"
        return 2
    fi
    if ! mv -fT "$tmp" "$dir/$name"; then
        rm -f "$tmp"
        msg_error "Failed to write secret '$name' for plugin '$id'"
        log "Plugin secret not saved: $id/$name (move failed)"
        return 1
    fi
    msg_success "Secret '$name' saved for plugin '$id'"
    log "Plugin secret saved: $id/$name"
}

# ==========================================================
# PLUGINS MENU
# ==========================================================
plugins_list() {
    plugins_load
    if ! plugins_read_enabled; then
        msg_error "Invalid $PLUGINS_ENABLED ($PLUGINS_ENABLED_ERROR): no plugin can run"
        echo
    fi

    local id status_plain status_colored name
    if ((${#PLUGIN_IDS[@]} == 0 && ${#PLUGINS_ON[@]} == 0 && ${#PLUGIN_BAD_DIRS[@]} == 0)); then
        echo "  No plugins installed in $PLUGIN_DIR"
        return
    fi

    printf "  %-20s %-11s %-8s %s\n" "ID" "STATUS" "VERSION" "NAME"
    local -A listed=()
    # Installed plugins, then enabled IDs that are not installed.
    for id in "${PLUGIN_IDS[@]}" "${PLUGINS_ON[@]}"; do
        [[ -n "${listed[$id]}" ]] && continue
        listed[$id]=1

        if plugin_is_active "$id"; then
            status_plain="● ENABLED" status_colored="${GREEN}● ENABLED${NC}"
        elif plugin_is_enabled "$id"; then
            status_plain="✗ BROKEN" status_colored="${RED}✗ BROKEN${NC}"
        elif [[ -n "${PLUGIN_ERROR[$id]}" ]]; then
            status_plain="✗ INVALID" status_colored="${RED}✗ INVALID${NC}"
        else
            status_plain="○ DISABLED" status_colored="${GRAY}○ DISABLED${NC}"
        fi
        name="${PLUGIN_NAME[$id]:-—}"
        printf "  %-20s " "$id"
        pad_colored "$status_colored" "$status_plain" 11
        printf " %-8s %s\n" "${PLUGIN_VERSION[$id]:-—}" "$(truncate_field "$name" 40)"

        if ! plugin_found "$id"; then
            echo -e "  ${YELLOW}    enabled, but not installed in $PLUGIN_DIR${NC}"
        elif [[ -n "${PLUGIN_ERROR[$id]}" ]]; then
            echo -e "  ${YELLOW}    ${PLUGIN_ERROR[$id]}${NC}"
        elif plugin_is_enabled "$id" && ! plugin_is_active "$id"; then
            echo -e "  ${YELLOW}    needs enabled: ${PLUGIN_DEPENDS[$id]}${NC}"
        elif [[ -n "${PLUGIN_DESC[$id]}" ]]; then
            echo -e "  ${GRAY}    ${PLUGIN_DESC[$id]}${NC}"
        fi
    done
    for name in "${PLUGIN_BAD_DIRS[@]}"; do
        echo -e "  ${YELLOW}! Ignored $(printf '%q' "$PLUGIN_DIR/$name"): not a valid plugin ID${NC}"
    done
}

plugins_menu() {
    while true; do
        header
        echo -e "${BOLD}PLUGINS${NC}"
        echo "──────────────────────────────────────────────────────"
        echo
        plugins_list
        echo
        echo "──────────────────────────────────────────────────────"
        echo
        echo "  [E] Enable    [D] Disable   [S] Set secret   [P] Site data"
        echo "  [Q] Back"
        echo

        local choice id
        read_input choice "Select action: " || return
        choice="${choice,,}"
        case "$choice" in
            ""|q) return ;;
            e)
                read_input id "Plugin ID to enable: " || { input_closed; return; }
                echo
                plugin_enable "$id"
                pause
                ;;
            d)
                read_input id "Plugin ID to disable: " || { input_closed; return; }
                echo
                plugin_disable "$id"
                pause
                ;;
            s) plugin_secret_prompt ;;
            p) plugin_site_data_prompt ;;
            *) msg_error "Invalid option"; pause ;;
        esac
    done
}

plugin_secret_prompt() {
    local id name value
    echo
    read_input id "Plugin ID: " || { input_closed; return; }
    read_input name "Secret name: " || { input_closed; return; }
    if ! read -rsp "Value (not shown): " value && [[ -z "$value" ]]; then
        input_closed
        return
    fi
    echo
    echo
    # printf is a builtin: the value never appears in a process list.
    printf '%s' "$value" | plugin_secret_set "$id" "$name"
    pause
}

plugin_site_data_prompt() {
    local site id data
    site=$(select_site "Select site") || return
    read_input id "Plugin ID: " || { input_closed; return; }
    if ! validate_plugin_id "$id"; then
        msg_error "Invalid plugin ID: '$id'"
        pause
        return
    fi
    echo "Current data: $(plugin_site_get "$site" "$id")"
    read_input data "New data (one JSON object, {} removes it): " || { input_closed; return; }
    echo
    if plugin_site_set "$site" "$id" "$data"; then
        msg_success "Plugin data saved for '$site'"
        echo "Edit or regenerate the site to apply it to its nginx configuration."
    fi
    pause
}
