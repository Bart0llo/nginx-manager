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

## Installation

```bash
curl -fsSL https://gist.githubusercontent.com/Bart0llo/e746ec66324473d20a72f13588f9d3b3/raw/install.sh | sudo bash
```

After installation:

```bash
nginx-manager
```

The installer places the application in:

```text
/usr/local/bin/nginx-manager
```

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
default. Install it later from TLS Manager -> Install TLS dependencies, or
during installation:

```bash
curl -fsSL https://gist.githubusercontent.com/Bart0llo/e746ec66324473d20a72f13588f9d3b3/raw/install.sh | sudo bash -s -- --with-certbot
```

This adds:

```text
certbot
python3-certbot-dns-cloudflare
```

To have the installer verify the downloaded script, pass its expected
SHA-256 from a source you trust (a checksum published next to the file on
the same gist would not prove anything):

```bash
curl -fsSL https://gist.githubusercontent.com/Bart0llo/e746ec66324473d20a72f13588f9d3b3/raw/install.sh | sudo NM_SHA256=<sha256> bash
```

Without `NM_SHA256` the installer only checks the script's Bash syntax and
says that the download was not verified.

The check is done by `install.sh` itself, which also comes from the gist.
When it is piped straight into `bash`, a tampered gist could serve an
`install.sh` that skips the check, so the piped form only guards the
`nginx-site.sh` download. For real assurance, download `install.sh` first,
read it (or compare its SHA-256 with a trusted value), then run the local
copy with `NM_SHA256` set.

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

## TLS

HTTPS can use a Cloudflare DNS-01 challenge and a wildcard certificate.

Supported modes:

* HTTP
* HTTPS
* BOTH

## Updating

Run the installation command again:

```bash
curl -fsSL https://gist.githubusercontent.com/Bart0llo/e746ec66324473d20a72f13588f9d3b3/raw/install.sh | sudo bash
```

## Uninstall

The application can be removed with:

```bash
sudo rm /usr/local/bin/nginx-manager
```

Configuration files and managed NGINX sites are not removed automatically.