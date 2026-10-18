# NGINX Manager Pro

Bash CLI for managing NGINX reverse proxy sites on Debian and Ubuntu.

## Features

* Add, edit and delete sites
* Enable and disable sites
* HTTP / HTTPS / BOTH
* Cloudflare DNS-01 support
* Automatic NGINX configuration generation
* Configuration validation before applying changes
* Backups and rollback on failed changes
* Basic system checks
* JSON-based site database
* Plugins (site validation, extra nginx directives, change notifications)

## Installation

NGINX Manager Pro is published as GitHub Releases of its public
repository, [`Bart0llo/nginx-manager`](https://github.com/Bart0llo/nginx-manager).
Each release has three files:

| Asset           | Contents                                              |
|-----------------|-------------------------------------------------------|
| `nginx-site.sh` | the application: one Bash file with all its modules   |
| `install.sh`    | the installer and updater for that release            |
| `SHA256SUMS`    | SHA-256 checksums of both files                       |

No GitHub account, token or GitHub CLI is needed: everything is
downloaded anonymously over HTTPS. Git is not needed either.

Download the installer of the latest release, read it, and run it:

```bash
curl -fsSLO https://github.com/Bart0llo/nginx-manager/releases/latest/download/install.sh
less install.sh
sudo bash install.sh
```

It downloads `nginx-site.sh` and `SHA256SUMS` of the latest release
(`--release vX.Y.Z` picks another one) and installs them. In one step,
without reading it first:

```bash
curl -fsSL https://github.com/Bart0llo/nginx-manager/releases/latest/download/install.sh | sudo bash
curl -fsSL https://github.com/Bart0llo/nginx-manager/releases/latest/download/install.sh | sudo bash -s -- --with-certbot
```

On a server without internet access, download the three files elsewhere
(from the release page) and copy them over:

```bash
sha256sum -c SHA256SUMS
sudo bash install.sh --bundle nginx-site.sh --sha256sums SHA256SUMS
```

`install.sh` from a release already knows its repository; a copy from a
checkout uses `Bart0llo/nginx-manager`. `--repo OWNER/NAME` (or
`NM_REPO`) downloads from another repository, such as a fork.

### What the installer does

1. Installs `curl`, `jq`, `nginx` and `openssl` with apt-get (plus certbot
   with `--with-certbot`, see Requirements). `--no-deps` skips this and only
   warns if `jq` or `nginx` is missing.
2. Looks up the release with one request to the GitHub API, then downloads
   `nginx-site.sh` and `SHA256SUMS` from the release's download URLs into a
   private temporary directory. With `--bundle` it copies the local file
   there instead. Only HTTPS is used, also after redirects. No credentials
   are sent, and a `GH_TOKEN` in the environment is ignored.
3. Checks the bundle without running it: SHA-256 against `SHA256SUMS`
   (required for downloads) and against `NM_SHA256` if set; non-empty;
   starts with `#!/bin/bash`; valid Bash (`bash -n`); every module listed in
   its end marker present; its version matches the release tag. A
   truncated file, or the modular `nginx-site.sh` from a checkout, is
   refused.
4. Installs it (see Updating for how a file is replaced) and reports the
   old and new version.

It never prompts, so it can run from scripts (apt-get runs with `-y` and
`DEBIAN_FRONTEND=noninteractive`). Running it again is safe: if the same
version is already installed, nothing is replaced. Run
`bash install.sh --help` for all options.

If GitHub cannot be reached, the release or repository does not exist,
GitHub answers with an error or with data that is not a release, the
installer names the problem and stops with a non-zero status. Requests to
the GitHub API without credentials are limited to 60 per hour per IP
address; an install or `--check` uses one. When the limit is used up, the
installer says so: wait, or use `--bundle`.

### Paths

| Path                                                  | Installer                                                 |
|-------------------------------------------------------|-----------------------------------------------------------|
| `/usr/local/bin/nginx-manager`                        | the application (mode `0755`)                             |
| `/usr/local/lib/nginx-manager/nginx-manager.previous` | the version the last update replaced                      |
| `/usr/local/lib/nginx-manager/plugins/`               | created empty (`0755`) if missing; contents never changed |
| `/usr/local/lib/nginx-manager/.install.lock`          | lets only one `install.sh` run at a time                  |
| `/etc/nginx-manager/`                                 | never read or written                                     |

`/etc/nginx-manager/` holds the configuration, `sites.json`, secrets,
backups, the enabled-plugin list and plugin settings. Files are owned by
the user running the installer (root). Existing directories keep their
permissions. If `/usr/local/bin/nginx-manager` is a symbolic link (for
example to a checkout), the installer refuses to replace it.

After installation:

```bash
nginx-manager
nginx-manager --version
```

### Checksums and trust

`SHA256SUMS` comes from the same release as the bundle. It detects a
damaged or truncated download, but it does not prove who published the
release: anyone who can publish a release can replace both files. For an
independent check, pass a SHA-256 that you obtained through another
trusted channel:

```bash
sudo NM_SHA256=<sha256> bash install.sh --bundle nginx-site.sh --sha256sums SHA256SUMS
```

`install.sh` itself also comes from the release. Read it, or check it
against a trusted hash, before you run it as root; the piped one-step
form gives you no chance to.

## Updating

Check for a newer release (no root or credentials needed):

```bash
nginx-manager --version
bash install.sh --check
```

Then install it the same way as a fresh installation. Use the
`install.sh` of the new release:

```bash
curl -fsSLO https://github.com/Bart0llo/nginx-manager/releases/latest/download/install.sh
sudo bash install.sh
```

How an update replaces the program:

* The installed version is not touched until the new one has been
  downloaded and has passed every check.
* The current file is copied to `nginx-manager.previous`. Then the new file,
  written next to `/usr/local/bin/nginx-manager`, is renamed over it. On a
  local filesystem a rename is atomic, so the command is always either the
  complete old file or the complete new one. A manager that is already
  running keeps the old version until it is restarted.
* Configuration, sites, secrets, backups, enabled plugins, plugin settings
  and the plugin directory are not touched.
* If any step fails, the installer exits with a non-zero status, names the
  step and shows no success message. The installed version is then unchanged.

### Recovery

* **Failed install or update:** the installed version is unchanged; fix the
  reported cause and run the installer again. If only the final rename
  failed, `nginx-manager.previous` already holds the current version.
* **Interrupted (Ctrl-C, SIGTERM):** temporary files are removed; the
  command is the old or the new version. After SIGKILL or a power loss,
  staging files (`/usr/local/bin/.nginx-manager.new.*`) can remain; the
  next run removes them.
* **The new version misbehaves:** `sudo bash install.sh --rollback` puts
  `nginx-manager.previous` back and keeps the version it replaces as the
  new `nginx-manager.previous`, so running it again undoes the rollback.
  This restores the program only. It does not undo changes that the newer
  version made to sites or configuration while it was in use.
* **Both copies unusable:** install a known release with `--release vX.Y.Z`
  or `--bundle`.

Limitations:

* Only one previous version is kept.
* The new file is flushed to disk before the rename, but the directory is
  not. A power loss right after an update can bring back the old version;
  run the installer again.
* Releases are not signed; see Checksums and trust.
* There are no automatic updates: the manager itself never contacts GitHub.

## Interface

The manager works in any terminal with its built-in text menus. If
[gum](https://github.com/charmbracelet/gum#installation) 0.15 or newer is
installed, it is used automatically for arrow-key menus, searchable lists
and confirmation dialogs. Nothing else changes. Neither the manager nor the
installer installs gum; install it yourself from your distribution or from
Charm's apt repository if you want it. Settings and Help show which
interface is active and why.

```bash
sudo nginx-manager --plain            # built-in menus even if gum is installed
sudo nginx-manager --non-interactive  # never wait for input; exit 1 where an answer is needed
sudo NO_COLOR=1 nginx-manager         # no colours
```

Gum is only used when stdin, stdout and stderr are a terminal. Piped input
is read line by line by the built-in menus. Colours are only used on a
terminal. If gum is missing, too old or its version cannot be determined,
the built-in menus are used. The automated tests use a stand-in for gum;
they do not exercise a real gum binary.

## Requirements

Supported:

* Debian
* Ubuntu

The installer installs the required packages automatically:

```text
nginx
jq
curl
openssl
```

Certbot is only needed for HTTPS certificates and is not installed by
default. Install it later from TLS & certificates -> Install TLS packages,
or during installation:

```bash
sudo bash install.sh --with-certbot
```

This adds:

```text
certbot
python3-certbot-dns-cloudflare
```

## Configuration

Application files are stored in:

```text
/etc/nginx-manager/
```

`/etc/nginx-manager/config.conf` is read as plain data, never executed as
shell code. Each line is `KEY=VALUE` for one of `DOMAIN`, `CERT_NAME`,
`CERTBOT_EMAIL`, `DEFAULT_TLS` or `SETUP_DONE`; a value may be wrapped in
one pair of `'...'` or `"..."`. Blank lines and `#` comment lines are
allowed. Any other line (unknown keys, `export`, spaces around `=`, `$(...)`
or other shell syntax, invalid values) makes the manager reject the whole
file and name the offending line, instead of guessing.

NGINX configurations use the standard:

```text
/etc/nginx/sites-available/
/etc/nginx/sites-enabled/
```

Logs:

```text
/var/log/nginx-manager/
```

## Plugins

Plugins add optional behaviour without changing the core: they can check
a site before it is saved, add directives to its generated nginx
configuration, and react when it changes or is deleted. Manage them from
the main menu -> Plugins. Enabling a plugin changes no existing
configuration until a site is edited or regenerated.

Plugins run as root with the manager's privileges and are not sandboxed:
install only plugins you trust. See [docs/PLUGINS.md](docs/PLUGINS.md)
for the format, the hook contract and the example plugin.

## TLS

HTTPS can use a Cloudflare DNS-01 challenge and a wildcard certificate.

Supported modes:

* HTTP
* HTTPS
* BOTH

## Development and releases

A checkout runs without installing anything and without GitHub access:
`sudo ./nginx-site.sh` uses the checkout's `lib/` and `plugins/` and
reports version `dev`.

```bash
bash tools/bundle.sh                                # single file: dist/nginx-site.sh (not tracked)
sudo bash install.sh --bundle dist/nginx-site.sh    # install that build locally
bash tests/run.sh                                   # test suite (needs Docker)
NM_TEST_BUNDLE=1 bash tests/run.sh                  # the same suite against the bundle
```

The tests run in disposable `debian:stable` containers without network
access. apt-get and curl (GitHub) are replaced by mocks, so the tests
never touch the host, GitHub or a real installation. `NM_INSTALL_ROOT=DIR` makes
`install.sh` install below `DIR` instead of `/`, without root and without
installing packages; the tests use it for staging installs.

To publish a release, push a version tag:

```bash
git tag v4.0.0
git push origin v4.0.0
```

`.github/workflows/release.yml` runs only for tags of the form
`vMAJOR.MINOR.PATCH`. It runs both test suites, builds the assets with
`tools/release.sh` (which stamps the version into `nginx-site.sh` and the
repository the workflow runs in into `install.sh`), and publishes
`nginx-site.sh`, `install.sh` and `SHA256SUMS` as a GitHub Release of that
repository. It never overwrites an existing
release. The tests run with read-only access to the repository; only the
publish job may create the release, and it uses no repository secrets. `bash tools/release.sh v4.0.0 Bart0llo/nginx-manager` builds the same files
locally in `dist/release/`.

## Uninstall

The application can be removed with:

```bash
sudo rm /usr/local/bin/nginx-manager
```

`/usr/local/lib/nginx-manager/` holds the previous version and installed
plugins; remove it too if you no longer need them. Configuration files and
managed NGINX sites are not removed automatically.
