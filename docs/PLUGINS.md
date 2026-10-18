# NGINX Manager plugins

Plugins add behaviour to NGINX Manager without changing its core: checking
a site before it is saved, adding nginx directives to generated
configurations, and reacting when a site changes or is deleted.

This document describes plugin API version **1**.

## Trust and security model

**Plugins are trusted local code. They run as root, with the same privileges
as the manager. This is not a sandbox.** Only install plugins you have read
or that come from a source you trust; a plugin can do anything root can.

The safeguards below protect against mistakes and malformed files. They do
not contain a hostile plugin:

* Manifests, settings and the enabled list are read as data. They are never
  `source`d or `eval`ed, and plugin code is never run to inspect a plugin.
* A disabled plugin never runs.
* Plugin IDs are checked before they are used in any path.
* A plugin runs as a separate `bash` process, with stdin closed and a
  30-second time limit, so it cannot read the menu's input or change the
  manager's own shell state.
* Plugin output is never executed as shell code. Directive output is
  checked and then written into the nginx configuration as text.
* Plugins cannot skip `nginx -t` or the reload handling: the core still
  validates and reloads exactly as it does without plugins.
* Settings and secret values are never printed or logged by the core.

## Directory layout

```text
<plugin dir>/<id>/
    manifest.conf       required: what the plugin is (read as data)
    plugin.sh           required if the plugin declares hooks

/etc/nginx-manager/plugins.enabled        enabled plugin IDs
/etc/nginx-manager/plugins/<id>.conf      optional settings (not secret)
/etc/nginx-manager/secrets/<id>/          optional secrets (0700, files 0600)
```

The plugin directory is:

* `plugins/` next to `nginx-site.sh` when running from a checkout of the
  repository (it contains the `example` plugin);
* `/usr/local/lib/nginx-manager/plugins/` for the installed single-file
  script. The installer does not install any plugins; copy a plugin's
  directory there.

The directory name must be the plugin's ID. Directories whose name is not
a valid ID are listed as ignored. Hidden directories and plain files are
skipped.

## Plugin IDs

An ID is 1-32 characters: a lowercase letter, then lowercase letters,
digits or `-` (`^[a-z][a-z0-9-]{0,31}$`). IDs are unique because the
directory name is the ID; a copied directory that still declares the
original's ID is refused as a duplicate.

## Manifest format

`manifest.conf` uses the same strict format as `config.conf`:

* one `KEY=VALUE` per line, no spaces around `=`;
* a value may be wrapped in one pair of `'...'` or `"..."`, taken
  literally (no escapes, no expansion);
* blank lines and lines starting with `#` are ignored; whitespace around a
  line is ignored;
* anything else - unknown keys, a repeated key, `export`, shell syntax,
  control characters - makes the whole manifest invalid.

| Key           | Required | Value                                               |
|---------------|----------|-----------------------------------------------------|
| `ID`          | yes      | the plugin ID; must equal the directory name        |
| `NAME`        | yes      | display name, at most 64 characters                 |
| `VERSION`     | yes      | the plugin's version, `MAJOR.MINOR.PATCH`           |
| `API`         | yes      | contract version; this manager supports `1`         |
| `DESCRIPTION` | no       | one line, at most 200 characters                    |
| `DEPENDS`     | no       | space-separated IDs of plugins this one requires    |
| `HOOKS`       | no       | space-separated hooks implemented by `plugin.sh`    |

Only hooks listed in `HOOKS` are ever called. A plugin without hooks needs
no `plugin.sh` (for example one that only provides settings for another).

Example:

```text
ID=example
NAME=Example greeting header
VERSION=1.0.0
API=1
DESCRIPTION=Sends an X-Example-Greeting header to the backend of sites that opt in
HOOKS=location-directives
```

An invalid plugin is shown as `✗ INVALID` in the Plugins menu with the
reason, and cannot be enabled.

## Enabling and disabling

Main menu -> **[5] Plugins** lists every plugin with its status:

| Status       | Meaning                                                      |
|--------------|--------------------------------------------------------------|
| `● ENABLED`  | enabled and able to run                                      |
| `○ DISABLED` | available, not enabled                                       |
| `✗ INVALID`  | cannot be used; the reason is shown below it                 |
| `✗ BROKEN`   | enabled, but cannot run; the reason is shown below it        |

Use **[E] Enable** / **[D] Disable** and pick the plugin from the list
(**[V] Details** shows its manifest, hooks, dependencies and which settings
and secrets exist, never their values). The functions behind them are
`plugin_enable <id>` and `plugin_disable <id>`.

The enabled list is `/etc/nginx-manager/plugins.enabled`, one ID per line
(`#` comments and blank lines are allowed). It is rewritten through a
temporary file and an atomic rename, and keeps every other enabled plugin.
A line that is not a valid ID makes the whole file invalid: no hook runs
(see [Error handling](#error-handling)) until it is fixed or removed.

Enabling or disabling a plugin runs no plugin code and **does not change any
nginx configuration**. A plugin's directives are added to, or removed from,
a site's configuration the next time that site is created, edited or
regenerated (open the site under **Sites** and choose **Regenerate**, or
**Sites -> [G] Regenerate all**).

A plugin that is no longer installed or no longer valid can still be
disabled.

## Dependencies

`DEPENDS` lists plugins that must be installed, valid and enabled for this
one to work. The rules are deliberately simple:

* A plugin with a missing or unavailable dependency is unavailable itself
  (this follows chains). A dependency cycle makes every plugin in it, and
  every plugin waiting on it, unavailable.
* Enabling never enables anything else: enable the dependencies first.
* Disabling is refused while another enabled plugin that can run depends
  on the plugin. A dependent that cannot run anyway (for example because an
  update created a cycle) does not hold its dependencies, so a broken set
  can always be disabled.
* Versions are not compared; there are no optional dependencies.

## Hooks

### Execution order

Hooks run for enabled plugins that declare them, one plugin at a time, in a
fixed order: every plugin after its dependencies, otherwise sorted by ID
(byte order). Concretely, the core repeatedly takes the first ID, in sorted
order, whose dependencies have all been placed.

### Blocking and informational hooks

| Hook                  | Kind          | Called                                                        |
|-----------------------|---------------|---------------------------------------------------------------|
| `validate-site`       | blocking      | before a site is created or edited; nothing is saved yet      |
| `server-directives`   | blocking      | when a site's configuration is generated                      |
| `location-directives` | blocking      | when a site's configuration is generated                      |
| `site-applied`        | informational | after a successful create, edit, enable or disable            |
| `site-deleted`        | informational | after the site's database entry has been removed              |

* **Blocking**: the first plugin that fails stops the operation; later
  plugins are not run. A failed `validate-site` makes the operation return
  2 ("rejected; nothing was changed"). A failed `*-directives` hook stops
  generation before anything is written: the previous configuration and
  database entry stay as they were (create is rolled back).
* **Informational**: every plugin runs, even after one fails. A failure is
  reported as an error and logged, followed by a warning that the site
  changes reported before it stand. The operation's result and return code
  do not change: a completed change is not reported as failed, and a
  partial one (e.g. a delete whose reload failed) is not reported as done.

The configuration is generated (and the directive hooks run) by create,
edit and regenerate. `site-applied` is not called by regenerate, which
changes no site settings, nor after an operation that failed (for example
when nginx could not be reloaded). `site-deleted` also runs when the
delete was partial but the database entry is gone.

### Calling convention

For each hook the core runs:

```text
bash <plugin dir>/<id>/plugin.sh <hook> <site>
```

with stdin from `/dev/null`, a time limit of 30 seconds (the plugin and
its child processes get SIGTERM, and SIGKILL 5 seconds later if they are
still running), and these environment variables in addition to the
manager's own:

| Variable              | Value                                                         |
|-----------------------|---------------------------------------------------------------|
| `NM_API`              | contract version (`1`)                                        |
| `NM_HOOK`             | the hook name (same as `$1`)                                  |
| `NM_PLUGIN_ID`        | the plugin's ID                                               |
| `NM_PLUGIN_DIR`       | the plugin's directory                                        |
| `NM_PLUGIN_CONFIG`    | path of its settings file (it may not exist)                  |
| `NM_PLUGIN_SECRETS`   | path of its secrets directory (it may not exist)              |
| `NM_SITE`             | site name (same as `$2`)                                      |
| `NM_SITE_DOMAIN`      | domain                                                        |
| `NM_SITE_BACKEND`     | backend `host:port`                                           |
| `NM_SITE_TLS`         | `http`, `https` or `both`                                     |
| `NM_SITE_ENABLED`     | `true` if its sites-enabled symlink exists, else `false`      |
| `NM_SITE_DATA`        | this plugin's per-site data, one JSON object (`{}` if none)   |
| `NM_SETTING_<KEY>`    | one per key in the settings file                              |

`validate-site` sees the proposed domain, backend and TLS mode (for a new
site, `NM_SITE_ENABLED` is `false` and `NM_SITE_DATA` is `{}`).
`site-deleted` sees the entry as it was just before it was removed.
A plugin only ever receives its own per-site data.

### Return codes and output

* Exit `0`: success. Any other exit code is a failure; exit `124` (and
  `137` after the time limit) is reported as a time-out.
* `*-directives` stdout is read once the plugin exits; a background process
  left running does not hold the manager up, but nothing it prints later is
  used. Do not leave processes running.
* stderr is shown to the user. Use it for messages, prefixed with the
  plugin ID. Never print secret values.
* stdout of `validate-site`, `site-applied` and `site-deleted` is shown to
  the user as well.
* stdout of `server-directives` and `location-directives` is the
  directives to add (see below); print nothing to add nothing.

### Directive output

`server-directives` output is placed in every server block that proxies
to the backend, just before `location / {` (for HTTPS sites, not in the
port-80 redirect block). `location-directives` output is placed at the end
of `location / { ... }`. Each plugin's lines are indented to fit and
preceded by a `# plugin: <id>` line:

```nginx
    location / {
        proxy_pass http://127.0.0.1:8080;
        include snippets/proxy-common.conf;
        # plugin: example
        proxy_set_header X-Example-Greeting "hello";
    }
```

Blank lines are dropped. The output is refused (a blocking failure) if a
line contains:

* a control character other than tab;
* `#` anywhere (an nginx comment could hide braces from the check below);
* a `}` without a matching `{`, or a `{` left open at the end.

The check only keeps the output inside its block; `nginx -t` validates the
directives themselves when the site is enabled, edited or regenerated, and
an invalid result is rolled back as usual. When no plugin prints anything,
the generated configuration is byte-for-byte what it is without plugins.

Note that nginx's `add_header` inside `location /` replaces the server's
`add_header` directives (including HSTS from `tls-common.conf`) for that
location; prefer `server-directives` or another directive for headers.

## Settings

Non-secret settings live in `/etc/nginx-manager/plugins/<id>.conf`, in the
same strict `KEY=VALUE` format as the manifest. Keys match
`[A-Z][A-Z0-9_]*`; values are passed to the plugin literally as
`NM_SETTING_<KEY>`. The core does not know which keys a plugin uses: the
plugin validates its own values and fails with a message when one is wrong.

If the file exists but is invalid, the plugin is not run and the hook fails
with the line number and the reason. Values never appear in the message.

## Secrets

Secrets live in `/etc/nginx-manager/secrets/<id>/`, one file per secret.
Save one from **Plugins -> [S] Set secret** (the value is not echoed), or
with `plugin_secret_set <id> <name>` and the value on stdin. Secret names
are 1-64 letters, digits, `.`, `_` or `-`, not starting with `.`.

The directories are created with mode `0700` and each file is written with
mode `0600` before the value goes in, then moved into place atomically. The
core never prints, logs or passes secret values; the plugin gets the
directory as `NM_PLUGIN_SECRETS` and reads the files it needs. Never put
secrets in the manifest or the settings file.

## Per-site data

Each site in `sites.json` can hold plugin-owned data in its `plugins`
object, keyed by plugin ID:

```json
"app": {
  "domain": "app.lan.example.com",
  "backend": "127.0.0.1:8080",
  "tls": "https",
  "enabled": true,
  "created": "2025-01-01T00:00:00Z",
  "plugins": { "example": { "header": true } }
}
```

Set it from **Plugins -> [P] Site data**, or with
`plugin_site_set <site> <id> '<json-object>'`; `{}` removes the plugin's
data (also for a plugin that is no longer installed). Updating one plugin's data keeps every other field of the site,
including `created`, unknown fields and other plugins' data, and so do
edits, enable/disable and regenerate. Plugins read their data from
`NM_SITE_DATA`; in API 1 they cannot write it back.

## Error handling

* **Invalid plugin** (manifest, missing dependency, cycle): listed with the
  reason; cannot be enabled; never runs.
* **Enabled plugin that cannot run** (removed, became invalid, dependency
  not enabled) or an invalid `plugins.enabled`: no plugin runs for any hook.
  Blocking hooks fail, so sites cannot be created, edited or regenerated
  until the plugin is fixed or disabled; informational hooks report it. This
  is deliberate: generating a configuration without, say, an authentication
  plugin's directives would silently remove protection.
* **Plugin failure or time-out**: reported as an error naming the plugin,
  the hook, the site and the exit code, and logged to
  `/var/log/nginx-manager/manager.log`. Never reported as success.

## Creating a minimal plugin

```bash
mkdir -p plugins/hello              # or /usr/local/lib/nginx-manager/plugins/hello
cat > plugins/hello/manifest.conf <<'EOF'
ID=hello
NAME=Hello
VERSION=0.1.0
API=1
HOOKS=validate-site
EOF
cat > plugins/hello/plugin.sh <<'EOF'
#!/bin/bash
case "$1" in
    validate-site)
        if [[ "$NM_SITE_DOMAIN" == test.* ]]; then
            echo "hello: test.* domains are not allowed" >&2
            exit 1
        fi
        ;;
esac
EOF
```

Then enable it in **Plugins**, and try adding a site named `test.<your
domain>`.

## The example plugin

`plugins/example` adds `proxy_set_header X-Example-Greeting "<GREETING>";`
to the `location /` of every site whose data for it is
`{"header": true}`. Other sites get nothing, so enabling it changes no
configuration by itself. `GREETING` defaults to `hello` and can be set in
`/etc/nginx-manager/plugins/example.conf` (1-64 letters, digits, spaces,
`.`, `_` or `-`; anything else makes the hook fail).

To try it from a checkout:

1. **Plugins -> [E] Enable**, `example`.
2. **Plugins -> [P] Site data**, pick a site, enter `{"header": true}`.
3. **Sites**, open that site, **[R] Regenerate**, then **[C] View
   config**: the header is in `location /`.
4. Disable the plugin (or set the data to `{}`) and regenerate: the
   configuration is back to the plain template.

## Compatibility and versioning

* `API` is the contract version: hook names, arguments, environment
  variables, exit-code meaning, output rules and file formats described
  here. A manager only loads plugins whose `API` it supports; this one
  supports `1` and refuses anything else instead of guessing.
* Within API 1, new optional environment variables may be added; plugins
  must ignore variables they do not know. New hooks may be added; a
  plugin is only called for hooks it lists in `HOOKS`, and a manager that
  does not know a listed hook refuses the plugin.
* Removing or changing the meaning of a hook, variable, exit code or file
  format requires a new API version.
* `VERSION` is the plugin's own version; the manager only displays it.
