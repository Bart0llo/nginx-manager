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
certbot
python3-certbot-dns-cloudflare
```

## Configuration

Application files are stored in:

```text
/etc/nginx-manager/
```

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