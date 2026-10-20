# AdGuard Home DNS rewrites

NGINX Manager can look up, add, change and remove
[AdGuard Home](https://github.com/AdguardTeam/AdGuardHome) DNS rewrites for
the domains of your sites, so that clients using AdGuard Home as their DNS
server reach those sites through this NGINX server.

* The integration is **optional and inactive until configured**. Nothing
  is sent anywhere until a connection is saved and you pick an action on
  the DNS screen.
* It is part of the core (`lib/adguard.sh`), not a plugin: it is not
  listed under Plugins and cannot be enabled or disabled there.
* Only AdGuard Home is supported. Pi-hole and other DNS servers are not.
* It only works on AdGuard Home's DNS rewrites (Filters › DNS rewrites).
  Filtering, clients, upstreams and other AdGuard Home settings are never
  read or changed.

Open it from the main menu -> DNS (AdGuard Home).

## Configuration

### Setting the connection

Choose DNS (AdGuard Home) -> Connection. The form asks for:

1. **AdGuard Home URL**: its web address, the same one you open in a
   browser, e.g. `https://dns.lan.example.com`. A trailing `/` or
   `/control` is removed.
2. **Username**: leave empty if AdGuard Home has no login. If you keep the
   same username and a password is already saved, you are asked whether to
   keep it.
3. **Password** (only with a username): typed without being shown; it
   cannot be empty.
4. **Default IP** (optional): offered as the answer when adding a rewrite
   and as the new address when editing one. See [Why the answer must be
   this NGINX server](#why-the-answer-must-be-this-nginx-server).

Nothing is saved until you confirm the summary; cancelling changes
nothing. After saving, you can test the connection right away. There is no
command-line option or other way to set the connection.

Test connection (GET `/control/status`) shows AdGuard Home's version and
whether its DNS server and protection are on. It changes nothing.

### Files

| Path                                          | Contents                   | Mode   |
|-----------------------------------------------|----------------------------|--------|
| `/etc/nginx-manager/adguard.conf`             | URL, username, default IP  | `0600` |
| `/etc/nginx-manager/secrets/`                 | directory for secrets      | `0700` |
| `/etc/nginx-manager/secrets/adguard.password` | the password, nothing else | `0600` |

Both files are written to a temporary file with these permissions first
and then renamed into place, so they are never briefly readable by others
or left half-written. The password file is only created when a username is
set. Saving the connection without a username deletes a saved password.

`adguard.conf` is written by the manager. If you edit it by hand, it uses
the same strict `KEY=VALUE` format as `config.conf` (see the
[README](../README.md#configuration)): it is read as data, never run as
shell code, and any unknown key, repeated key, shell syntax or invalid
value makes the manager reject the whole file. The DNS screen then shows
it as invalid with the reason (never the values), and Connection replaces
it.

| Key              | Required | Value                                            |
|------------------|----------|--------------------------------------------------|
| `URL`            | yes      | `http(s)://host[:port][/path]`                   |
| `USERNAME`       | no       | 1-64 of `A-Z a-z 0-9 . _ @ + -`; empty: no login |
| `DEFAULT_ANSWER` | no       | an IPv4 or IPv6 address                          |

The URL's host is a name or an IP address (IPv6 in `[...]`). It must not
contain a login (`user:pass@`), a query or a `#`. The password is never
stored in `adguard.conf`.

### Removing the connection

Remove connection (asks for confirmation, default no) deletes
`adguard.conf` and the saved password. AdGuard Home and its DNS rewrites
are not changed, and neither are your sites or their nginx configuration.
The DNS screen then shows the integration as not configured.

### Login, URL and HTTP

* The login is sent as HTTP Basic authentication to AdGuard Home's API
  (`<URL>/control/...`), the same login as its web interface.
* The password is only read when a request is sent. It is passed to curl
  as a header in a config read from standard input, never as a command-line
  argument or environment variable, and it is never written to the log or
  the screen.
* Redirects are not followed. If AdGuard Home redirects (for example from
  `http://` to `https://`), enter the final address.
* Each request has a 5-second connect timeout, a 15-second total timeout
  and a 1 MiB answer limit.
* No request is retried. AdGuard Home blocks an address for a while after
  repeated failed logins, so after a rejected login nothing more is sent
  until you start another action.
* `~/.curlrc` is ignored, so it cannot add options such as `--insecure`.

**Use HTTPS.** With `http://` the login and every DNS change travel
unencrypted, and anyone on the network path can read the password. The
manager warns about this when you enter an `http://` URL and on the DNS
screen, and asks you to confirm.

### TLS certificates

HTTPS certificates are always verified against this system's trusted
certificates, including the host name. There is no setting to turn this
off or to name a separate CA file.

If AdGuard Home uses a certificate from a private CA, add that CA to the
system trust store. On Debian and Ubuntu:

```bash
sudo cp my-private-ca.crt /usr/local/share/ca-certificates/my-private-ca.crt
sudo update-ca-certificates
```

The file must be in PEM format and end in `.crt`. The URL's host name must
match a name in the certificate.

## DNS behaviour

### Sites and rewrites

A rewrite in AdGuard Home has a domain and an answer. The manager looks at
the domain of each site in its database and finds the rewrites for it the
way AdGuard Home matches them: letter case and a trailing `.` are ignored.

* An **exact** rewrite has the site's domain itself (`app.example.com`).
* A **wildcard** rewrite `*.example.com` covers every name below
  `example.com`, at any depth, but not `example.com` itself.
* An exact rewrite takes precedence over a wildcard for that name.

Sites whose stored domain is not a valid domain name are not looked up.

### Why the answer must be this NGINX server

A site's domain must resolve to **this NGINX server**, not to the
application behind it. NGINX receives the request and forwards it to the
site's backend (`proxy_pass`). If the rewrite pointed at the backend's IP,
clients would bypass NGINX, and with it TLS and everything else the site's
configuration does.

`DEFAULT_ANSWER` is therefore normally the address of this server as seen
by your clients. It is only a suggestion: you can enter another address
for each rewrite, and the default stays unchanged.

Adding, editing or deleting a rewrite never changes a site, its
`proxy_pass` or any other nginx configuration, and never reloads nginx.

### What the views show

**Your sites' DNS** shows, for each site's domain:

* one exact rewrite, or an IPv4 and an IPv6 rewrite together;
* duplicates (the same answer more than once) or conflicting answers
  (different addresses of the same kind, or a name next to anything;
  clients may get any of them), as a warning;
* an exact rewrite that is disabled in AdGuard Home;
* no exact rewrite, but a wildcard that may match;
* no rewrite at all.

Wildcards covering a domain are listed under it. The answers `A` and
`AAAA`, which make AdGuard Home keep the upstream records of that type,
count as an IPv4 or IPv6 answer.

**All rewrites** lists every rewrite AdGuard Home reports, with its answer
and state, also for domains that are not your sites.

Both views only read and change nothing. They show:

* **Rewriting**: AdGuard Home's global rewrite switch (v0.107.68 and
  later). When it is off, the views say that no rewrite is applied now.
  Older versions have no such switch; the state is shown as unknown.
* **State per record**: enabled or disabled (v0.107.68 and later). Older
  versions do not report it; such records are shown as "not reported",
  which is not the same as disabled.
* Records that are not a domain and answer as expected (missing fields,
  wrong types) are counted as skipped. Control characters are removed from
  what is shown.

### Ownership and synchronisation

The manager does not keep a list of rewrites it created, and it does not
claim a record just because its domain matches a site. A rewrite may have
been created by hand in AdGuard Home or by another tool; the screens say
so before a change. That is also why unmanaged rewrites are only shown in
All rewrites, never offered for changes: Edit and Delete only work on the
exact rewrites of a site's domain.

There is no automatic synchronisation. Adding, editing, renaming,
disabling or deleting a site never contacts AdGuard Home, and changing a
rewrite never changes a site. Update the rewrites yourself when a site's
domain changes or a site is removed.

### Which actions contact AdGuard Home

Endpoints are below `<URL>/control/`. "Read" means GET `status`,
`rewrite/list` and `rewrite/settings`.

* **Opening the DNS screen, Connection, Remove connection:** nothing.
  Saving a connection offers a test, which you can decline.
* **Test connection:** GET `status`.
* **Your sites' DNS:** read, only if there are sites.
* **All rewrites:** read.
* **Add rewrite:** read once the IP address is entered; after
  confirmation GET `rewrite/list`, POST `rewrite/add`, GET `rewrite/list`.
* **Edit rewrite:** read once a site is picked; after confirmation GET
  `rewrite/list`, PUT `rewrite/update`, GET `rewrite/list`.
* **Delete rewrite:** read once a site is picked; after confirmation GET
  `rewrite/list`, POST `rewrite/delete`, GET `rewrite/list`.

A request that fails stops the action: nothing after it is sent.

## Adding, editing and deleting

Each change is shown as a summary and needs confirmation. Right before
sending it, the manager reads the rewrite list again and sends nothing if
it no longer matches what you confirmed. Each write is sent at most once.

### Add rewrite

Pick a site, enter an IPv4 or IPv6 address (the default IP is offered),
review the summary and confirm. One exact rewrite is added.

* If the domain already has an exact rewrite - with the same answer, a
  different one, disabled, or several - nothing is added and the existing
  records are shown. Add rewrite never changes existing records; use Edit
  rewrite to change an address.
* If only a wildcard covers the domain, it is shown and you must confirm
  (default no) that the exact rewrite should take precedence for this
  domain.
* AdGuard Home stores the domain in lowercase; the summary says so.
* If an exact rewrite appears between the summary and sending, nothing is
  sent.

### Edit rewrite

Changes the address of one exact rewrite in place (PUT
`/control/rewrite/update`, AdGuard Home v0.107.33 or later). The domain and
the record's enabled state stay as they are. A rewrite is never changed by
deleting and re-adding it.

AdGuard Home finds the record to change by its domain and answer, letter
for letter, and changes the first match. Therefore nothing is sent when:

* the AdGuard Home version is older than v0.107.33 or cannot be determined
  (for example a development build);
* the record is now missing, or the same domain and answer are listed more
  than once (which one would change cannot be chosen);
* the record was switched on or off since it was shown;
* another exact rewrite for the domain already has the new address;
* any record in the list could not be read (it might match as well);
* the new address is the same as the current one.

With several exact rewrites for a domain, you pick one. Records containing
characters that cannot be shown are not offered for editing or deletion,
since what is stored differs from what is shown; change them in AdGuard
Home.

### Delete rewrite

Pick a site (and a rewrite if it has several), then type the domain to
confirm. Only records with exactly this domain and answer are removed;
other addresses for the domain and other domains stay.

AdGuard Home removes every record with the same domain and answer at once.
When there are several identical records, the manager says how many and
asks for a separate confirmation (default no) to delete all of them. If the
number of matching records has changed by the time of sending, or any
record could not be read, nothing is sent.

### Results and uncertain outcomes

A change is reported as done only after the rewrite list has been read
again and shows it. An HTTP success alone is not enough: for example,
AdGuard Home answers a delete with success even when nothing matched.

* **"Rewrite added / changed / deleted":** sent, and confirmed in the list
  read back.
* **"nothing was sent":** a check failed; AdGuard Home was not changed.
* **"was not added / changed / deleted":** not carried out: the connection
  was refused, the name or TLS failed, or AdGuard Home refused the request
  (3xx/4xx).
* **"may or may not have been ...":** sent, but the answer timed out, the
  connection broke off, or AdGuard Home failed with a 5xx error.
* **"accepted ..., but it could not be confirmed" / "... is not in its
  list":** AdGuard Home answered with success, but the list read back does
  not show the change.

The AdGuard Home API returns no operation identifier, and it does not
refuse duplicate rewrites. After an uncertain outcome the manager therefore
cannot tell whether the change was made, and sending it again could create
a duplicate. **Check Your sites' DNS (or Filters › DNS rewrites in AdGuard
Home) before trying again.**

The log (`/var/log/nginx-manager/manager.log`) records each change with its
domain, answers and result, never the password.

## Troubleshooting

* **"login failed" / "requires a login" (HTTP 401):** check the username
  and password under Connection. After repeated failures AdGuard Home
  blocks this address for a while (HTTP 429); wait before trying again.
* **"access denied" (HTTP 403):** AdGuard Home's access settings may not
  allow this server's address.
* **"could not resolve" / "could not connect" / "timed out":** check the
  URL, the port and that AdGuard Home is running and reachable from this
  server.
* **"the certificate ... is not trusted or does not match its name":** add
  the private CA to the system trust store (see [TLS
  certificates](#tls-certificates)) and make sure the URL's host name is in
  the certificate.
* **"TLS connection ... failed":** the port probably speaks plain HTTP;
  check the protocol and port.
* **"redirected":** enter the final address, usually with `https://`.
* **"not found (HTTP 404/405)":** the URL is not AdGuard Home's web address
  (do not add `/control`), or this version does not support the request.
* **"did not answer like AdGuard Home":** the URL points to another
  service.
* **Enabled state "not reported", Rewriting "Unknown":** AdGuard Home
  before v0.107.68 does not report them. Updating AdGuard Home shows them.
* **"cannot edit rewrites":** update AdGuard Home to v0.107.33 or later,
  or change the record in AdGuard Home.
* **"record(s) could not be read" / "skipped":** a rewrite has an
  unexpected form; review the rewrites in AdGuard Home. Edit and Delete
  stay blocked until then.
* **Accepted but not confirmed:** read the list again with Your sites' DNS
  and compare it with Filters › DNS rewrites in AdGuard Home before
  repeating the change.

## Limitations

* Rewrites can only point to IPv4 or IPv6 addresses; other answers (such
  as a domain name) can be shown but not created.
* Rewrites cannot be switched on or off here; do that in AdGuard Home.
* Wildcard rewrites and rewrites for domains that are not sites are only
  shown, never changed.
* There is no automatic synchronisation and no record of which rewrites the
  manager created.
* The automated tests use a stand-in for AdGuard Home's API that follows
  its documented behaviour, and a stand-in for gum. Certificate
  verification is tested with the real curl against a local TLS server.
  The integration has not been tested against a real AdGuard Home server
  or with a real gum binary.
