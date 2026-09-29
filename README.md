# SQLite Viewer · Janet

A small read-only SQLite web application: an iOS-inspired desktop/tablet working
surface, server-rendered in Janet, with Datastar live updates. One HTTP listener,
one service executable, no Node runtime, no frontend build server, no CDN at runtime.

Features: database/table sidebar; Data, Schema, Indexes and SQL tabs; pagination;
sorting; text search; equality/contains filters; column visibility; CSV export of
the current page; a bounded read-only SQL editor; live query results; and JWT
identity verification with separate database authorization.

## Quick start

Build prerequisites on Ubuntu 24.04:

```sh
sudo apt-get install build-essential cmake pkg-config libssl-dev libcurl4-openssl-dev git python3-cryptography rpm createrepo-c
git clone https://github.com/tjisse/sqlite-viewer-janet.git
cd sqlite-viewer-janet
bash scripts/build.sh
bash scripts/test.sh
dist/bin/sqlite-viewer --demo
```

Open `http://127.0.0.1:8080/?table=customers`. Demo mode creates `demo.sqlite` only
if it does not exist, binds exclusively to `127.0.0.1`, and disables authentication
explicitly. It contains fictional customers, products, orders and activity.

**Private dependency:** `tjisse/janet-jwt` is private at the time of this release.
The application repository does not redistribute its source. You need permission
to clone it. For an authenticated GitHub CLI installation, run the build with:

```sh
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper \
  GIT_CONFIG_VALUE_0='!gh auth git-credential' bash scripts/build.sh
```

Alternatively, pre-clone every repository in `deps.lock` to a directory, then set
`SV_DEPS_DIR=/absolute/path/to/deps`. The build checks out exact commits. In CI,
`JWT_SOURCE_SSH_KEY` holds a dedicated **read-only deploy key for tjisse/janet-jwt**.
It is already configured on the original application repository. Fork maintainers
must provision their own authorized deploy key; no personal GitHub token is stored.
GitHub's host keys are fetched over HTTPS and checked strictly. Remove the deploy
key in janet-jwt Settings → Deploy keys, and the matching Actions secret, to revoke
this build access.
Public/fork PRs deliberately do not run secret-bearing builds.

Already have the runtime archive? Extract it and run `bin/sqlite-viewer --demo`.
The executable is independently relocatable: Janet, application bytecode, SQLite,
native bindings, Jansson, libjwt and all web assets are embedded. There is no
runtime module directory or installed Janet requirement. Retain `share/` when
redistributing the archive for its license notices. OpenSSL, libcurl (7.85+), glibc and libm remain
system libraries: this is a bundled executable, not a fully static libc binary.
The x86_64 artifact requires glibc 2.38+ and OpenSSL 3.0+, suitable for Fedora
40+ (use a currently supported Fedora release). It is **not an EL9 binary**.

## Development and tests

Application code is in `src/*.janet`; styling and small browser enhancements are
in `assets/`. HTML components use janet-html trees, rendered through `ui/render`
which escapes attributes and handles optional boolean attributes. The library is
pinned in `deps.lock` and embedded by the existing build flow. There are no handwritten C files in this repository. JPM's
`declare-executable` builds `src/main.janet`; `project.janet` declares the native
dependencies using their own source files. JPM-generated C and intermediate
native modules stay in `.build/` and are not shipped. The public SQLite controls
live in `tjisse/sqlite3`; viewer-specific authorization and budgets live in
`src/query.janet`. Build output is `dist/bin/sqlite-viewer` and license notices.
No web routes allow file upload, database mutation, or changing trusted config.

After changing Janet code or web assets, rebuild the embedded image:

```sh
bash scripts/format.sh
bash scripts/build.sh
bash scripts/test.sh
dist/bin/sqlite-viewer --demo
```

Restart the executable after rebuilding; refresh the browser after asset changes.
`SV_PORT=8765` changes the development port. To create a standalone sample:

```sh
dist/bin/sqlite-viewer --seed /absolute/path/sample.sqlite
```

Seeding refuses to overwrite an existing file. `scripts/test.sh` runs core Janet
checks and Python integration tests using temporary databases and newly generated
RSA keys. Tests exercise Access JWT failures, prefixed Entra grants, logout,
origin checks, query restrictions/budgets, escaping, 64-bit integer preservation,
commit/rollback hooks, views/search/sort/filter/export, and SSE external commits.
The core suite is a separate build-only Janet executable, not a production
`--test` command. Integration tests run a copied service executable in an isolated
directory and verify embedded assets, auth, SQL and subscriptions without modules
or source files beside it. The entry point handles SIGPIPE so disconnected SSE
clients cannot terminate the service.
Tests need local TCP listeners; production does not need Python or the curl executable.
The HTTPS client is Jurl, pinned in `deps.lock`, with its Janet and native bindings
embedded. Install the system libcurl library and CA certificate store at runtime.
Client tests check certificate trust, hostnames, HTTPS-only transport, redirects,
timeouts, size limits, and key rotation/cache failures against a temporary TLS server.

## Authentication and authorization

Production uses **Cloudflare Access with Microsoft Entra ID over OIDC**. Entra
manages role assignments, Cloudflare signs the application JWT, and the viewer
verifies the `Cf-Access-Jwt-Assertion` header with `janet-jwt`. RS256 is pinned;
issuer, application audience, expiry and optional not-before are checked. A
nonempty `sub` and `type: "app"` are required. Plain identity headers, bearer
tokens and browser cookies are not accepted by the origin. There is no viewer
password store, signing endpoint, or token-paste form.

The forwarded Entra roles must be an array of strings in `custom.roles`:

```json
{
  "iss": "https://YOUR-TEAM.cloudflareaccess.com",
  "aud": ["YOUR-ACCESS-APPLICATION-AUD"],
  "sub": "user-subject",
  "type": "app",
  "exp": 2000000000,
  "custom": {
    "roles": ["sqlite-viewer.viewer", "sqlite-viewer.db.Studio.read"]
  }
}
```

| Entra app role value | Permission |
|---|---|
| `sqlite-viewer.viewer` | Required to use the viewer |
| `sqlite-viewer.db.<alias>.read` | Read the exact configured database alias |
| `sqlite-viewer.db.All.read` | Read all configured databases |

Alias matching is case-sensitive. `All` is reserved and cannot be a database
alias. Unrelated roles are ignored; missing/malformed roles deny access. The
viewer role alone grants no database access. Grants cover the entire database,
including schema, SQL, exports and subscriptions; there are no row/column grants.

### Entra and Cloudflare setup

1. In Entra **App registrations**, select the client ID used by Cloudflare's OIDC
   connection. Under **App roles**, create the role values above, enable them,
   and set allowed member types to **Users/Groups**. Define one read role per
   database alias as needed.
2. In the corresponding **Enterprise application → Users and groups**, assign
   each user or group both the viewer role and the desired database roles. Entra
   emits app role values in the ID token's `roles` claim automatically.
3. In Cloudflare **Zero Trust → Integrations → Identity providers**, edit the
   Entra/OIDC provider and add `roles` under **OIDC Claims**. Test the provider;
   verify all assigned values in `oidc_fields.roles`.
4. Protect the viewer hostname with a self-hosted Access application. Restrict
   its Allow policy to the intended Entra provider and users with the viewer
   role, using an OIDC claim rule. Copy the application's **AUD tag** (not the
   Entra client ID) into `SV_AUDIENCE`.
5. Set `SV_ISSUER` to the Cloudflare team URL and `SV_ORIGIN` to the protected
   public HTTPS origin. Route the origin through Cloudflare Tunnel or a
   restricted reverse proxy. Keep the viewer on loopback and prevent direct
   public access to its port; preserve the assertion header, Host and Origin.
6. Sign in through Access and confirm the Access JWT contains the expected
   `custom.roles`. Test with a Studio reader and a user lacking its grant.

See [Entra app roles](https://learn.microsoft.com/en-us/entra/identity-platform/howto-add-app-roles-in-apps)
and [Cloudflare OIDC claims](https://developers.cloudflare.com/cloudflare-one/integrations/identity-providers/generic-oidc/#custom-oidc-claims).
Cloudflare can trim custom claims beyond roughly 1 KB; omitted roles deny access.
Keep role sets small. Full-identity lookup is not implemented.

### Keys and sessions

By default keys are fetched from the configured issuer's
`/cdn-cgi/access/certs` endpoint using Jurl with certificate/hostname verification,
HTTPS-only protocols, no redirects, a 3-second connection timeout, a 5-second
request timeout and a 1 MiB body cap. Fetching runs on a worker thread so it does
not block requests or subscriptions. Only configured URLs are used, never URLs
from a token. Startup requires a valid key set. Cached keys refresh on requests
after one hour and on signature verification failure (including unknown `kid`),
with at most one attempt per minute. A failed refresh keeps the last valid set;
verification fails closed once that cache is 24 hours old. Overlap old/new keys
when rotating externally maintained key files. No keys are persisted by the app.

`SV_JWKS` optionally selects a trusted public JWKS file instead of network fetches;
it is reread on the same refresh schedule. Every JWK must include `kid`, `alg:
"RS256"` and a supported public RSA key. This is useful for offline provisioning
and local tests. Remove this setting to use automatic Cloudflare key fetching.

The viewer's Sign out form posts to `/logout`, which checks the request Origin and
redirects to `/cdn-cgi/access/logout`. `Referrer-Policy: same-origin` preserves the
Origin on same-origin form submissions while withholding referrer URLs from other
origins. Cloudflare clears/revokes its Access session across applications. Existing
origin streams stop at JWT expiry; the viewer performs no online revocation checks.
A copied assertion can still pass origin signature checks until expiry, which is why the
origin must remain behind Access. Changing Entra assignments requires fresh IdP
claims; existing Access sessions can retain previous grants until reauthentication.
Use short session durations appropriate to the deployment.
See [Access session management](https://developers.cloudflare.com/cloudflare-one/access-controls/access-settings/session-management/).

| Setting | Purpose |
|---|---|
| `SV_HOST` | Listen address, default `127.0.0.1` |
| `SV_PORT` | Port, default `8080` |
| `SV_ORIGIN` | Exact public browser origin, without trailing slash |
| `SV_ISSUER` | Required `https://TEAM.cloudflareaccess.com` |
| `SV_AUDIENCE` | Required Cloudflare Access application AUD tag |
| `SV_JWKS` | Optional externally maintained public JWKS file; default HTTPS fetch |
| `SV_DATABASES` | Path to database alias/path JSON |
| `SV_ALLOW_HTTP=1` | Explicit local-only auth testing; requires loopback binding |
| `SV_DEMO_DB` | Demo database path, used only with `--demo` |

All POST requests check the exact Origin. Run production behind an HTTPS reverse
proxy on the same origin. Datastar compiles its HTML expressions in the browser,
so CSP includes `script-src 'self' 'unsafe-eval'`; scripts/assets are served
locally and database values are HTML-escaped. No inline scripts are required.

## Databases and reactivity

`SV_DATABASES` points to JSON such as:

```json
{"Studio":"/srv/studio/studio.sqlite", "Reports":"/srv/reports/reports.sqlite"}
```

Only configured paths are opened. Browser inputs select aliases, not filesystem
paths. Connections use SQLite `OPEN_READONLY`; extension loading and trusted
schema are disabled. The service needs directory traversal and read access to the
database and any WAL/SHM files. A WAL database may need an already-created readable
SHM file; arrange permissions with its writer. Do not use `immutable=1` for live
databases. Replacing the database file itself requires restarting the viewer.

The binding is pinned to **`query-controls` commit `cf01247`**, based on your
`change-tracking-hooks` work and including the reviewed garbage-collection, veto
and statement-cleanup fixes. Its general `query`, `config`, `limit`, read-only
opening and busy-timeout APIs replace the application's former C adapter. `watch.janet`
registers `update-hook`, `commit-hook`, and `rollback-hook`. Callbacks only record
invalidation; they never execute SQL, publish SSE, or yield. `watch/eval!` publishes
after the SQLite call returns. Rollbacks discard pending changes. Commit-level
invalidation also covers DDL, `WITHOUT ROWID`, and optimized DELETE operations
that the row update hook can miss.

The shipped viewer does not write to production databases. Its persistent read
connections poll `PRAGMA data_version` once per second to detect **other
connections/processes**. A change invalidates that database's table/schema/index
and active SQL subscriptions conservatively. The next stream tick reruns the
bounded query and sends `datastar-patch-elements`; typical external-writer delay
is 1–2 seconds. It is not a durable event log and does not report individual
external row changes. In-process integrations should use `watch/eval!` around
every write, with one SQL statement per call (separate BEGIN/COMMIT calls are
supported); direct writes bypass its post-eval publication step. Call
`watch/detach` before closing a tracked connection to release hook closures.

Browser reconnects receive a fresh snapshot. Streams are capped at 64 and emit
heartbeats; slow/disconnected clients release their generators. SQL results
subscribe after Run; their full SQL stays in the POST body. Non-Datastar API
requests to `/query` get a single SSE result, useful for scripting.

SQLite's own documentation explains [update hook scope and omissions](https://www.sqlite.org/c3ref/update_hook.html)
and [data_version's per-connection behavior](https://www.sqlite.org/pragma.html#pragma_data_version).

## Query and resource limits

SQL permits one read-only statement, including CTEs, with a SQLite authorizer
blocking writes, ATTACH, unsafe PRAGMAs, and extension/file functions. It is not a
keyword-prefix filter. Queries have a 250 ms / approximately 2 million VM
instruction budget, 16 KiB SQL length limit, 4 MiB result budget, and 200 displayed
rows. Individual values are capped at 1 MiB on production connections. The binding
finalizes statements and clears query-scoped callbacks on failures. The Janet
policy sets the authorizer, progress callback, and resource limits. Integers
are displayed losslessly as decimal strings; BLOBs are labeled without decoding.

Search is case-insensitive SQLite `lower()`/substring search across columns;
Unicode case folding follows the bundled SQLite build, not full ICU. Filters
compare displayed text. Offset pagination and exact counts can be expensive on
very large tables; tighten filters/use indexed SQL if a query reaches its budget.
Rows with identical sort values have no guaranteed tie order. CSV exports only
the current page/visible columns and prefixes potential spreadsheet formulas.
For names containing commas, column visibility's comma-separated URL preference
cannot address those columns independently; SQL projection remains available.

The small single-threaded server is intended for trusted team usage behind a
reverse proxy, not an exposed multi-tenant database sandbox. Spork's HTTP parser
does not provide a header-size/slow-client policy. Apply proxy header/body limits,
connection limits and timeouts; preserve SSE streaming and disable response
buffering. The systemd unit also caps process memory/tasks. CPU budgets are checked
between SQLite VM operations, not a hard process-level deadline for every builtin.

## RPM and systemd deployment

```sh
bash scripts/rpm.sh
# Local artifact has no maintainer signature yet. Verify its supplied SHA256.
sudo dnf install ./dist/sqlite-viewer-0.3.0-1.x86_64.rpm
```

Package layout:

| Path | Contents |
|---|---|
| `/usr/bin/sqlite-viewer` | Janet service executable |
| `/etc/sqlite-viewer` | Root-managed auth/database configuration |
| `/var/lib/sqlite-viewer` | Service-owned persistent state/sample database |
| `/usr/lib/systemd/system/sqlite-viewer.service` | Hardened unit |

Installation creates a locked `sqlite-viewer` system account. Config files use
`%config(noreplace)`, so upgrades preserve edits. Installation **does not start or
enable** the service before auth is configured. Edit `viewer.env` with the Cloudflare issuer, application AUD and public origin,
and edit `databases.json`. Keep ownership `root:sqlite-viewer` and mode `0640`.
Keys are fetched automatically; no JWKS file is required. To try the packaged database with real authentication:

```sh
sudo -u sqlite-viewer /usr/bin/sqlite-viewer --seed /var/lib/sqlite-viewer/demo.sqlite
sudo systemctl enable --now sqlite-viewer
sudo journalctl -u sqlite-viewer -f
```

The unit denies writes outside its state directory and blocks access to home
directories. Configure database paths under `/srv` or another readable location,
not a personal home. Production runs on loopback behind your HTTPS proxy; set
`SV_ORIGIN` to that public origin. In nginx, use `proxy_http_version 1.1`,
`proxy_buffering off`, `proxy_read_timeout 60s`, `client_max_body_size 20k`, and
preserve `Host`/`Origin`. Limit request rates/connections according to your team.
The application verifies the signed Cloudflare assertion and never trusts plain
forwarded identity headers.

## Free RPM repository and publishing

Chosen approach: **GitHub Releases for immutable RPM files + GitHub Pages for
signed repository metadata and the public key**. This fits the existing Actions
build and needs no second build service. See [the 2026 comparison](docs/rpm-hosting.md)
for Copr, OBS, Cloudsmith and static hosting tradeoffs.

One-time maintainer setup:

1. Create/push this source repository. If it is private, GitHub's free Pages plan
   is not sufficient; make the app source public or use a separate public metadata
   repository. Do not change the private dependency's visibility implicitly.
2. Configure the Actions secret `JWT_SOURCE_SSH_KEY` described above. Enable Pages with
   **GitHub Actions** as the publishing source.
3. Supply a dedicated RPM signing key as the Actions secret `RPM_GPG_PRIVATE_KEY`
   and its full fingerprint as repository variable `RPM_SIGNING_KEY`. The included
   noninteractive workflow expects a dedicated unencrypted CI key protected by
   Actions secrets/environment controls; use a hardware/KMS signing workflow if
   that is your policy. Publish/verify its fingerprint out of band.
4. Push a matching version tag (currently `v0.3.0`), let Build and test pass, then
   run **Publish signed RPM repository** with that tag. Publication rebuilds/tests,
   signs the RPM, creates a release, regenerates metadata with retained release
   RPMs, signs `repomd.xml`, and deploys Pages. Both RPM and metadata verification
   remain enabled in the `.repo` file. Update the package/version fields before
   making a new version tag; do not overwrite an existing released RPM.

The original repository has a dedicated signing key configured in Actions and
publishes signed releases. Its fingerprint is
`91ED 8184 134F 2AAD B0DD 1BCB 497D 7F47 0CE7 6057` (expires 2028-09-05).
The public key is also committed under `packaging/`. Fork maintainers must
provision their own key; private signing material is never committed. The signing
job never falls back to `gpgcheck=0`. Ordinary local `scripts/rpm.sh` builds remain
unsigned until explicitly signed. `repository.sh` can generate unsigned metadata
without a key for inspection, but the secure `.repo` intentionally cannot install
from an unsigned snapshot. Back up signing keys securely and plan rotation before
expiry; update the committed public key, Actions secret and fingerprint together.

If publication fails after creating a release, keep that release immutable:
rerun just the metadata/deploy steps against the already-signed release assets
using `scripts/repository.sh`, or adjust the workflow to resume that stage.
The sample collector retains up to 100 recent stable releases; extend pagination
before reaching that threshold. Never delete versions required for rollback.

After the signed repository is published:

```sh
curl -fsSLO https://tjisse.github.io/sqlite-viewer-janet/rpm/sqlite-viewer.repo
# Inspect the .repo and verify the signing-key fingerprint with the maintainer.
sudo install -m 0644 sqlite-viewer.repo /etc/yum.repos.d/sqlite-viewer.repo
sudo dnf install sqlite-viewer
sudo dnf upgrade sqlite-viewer
dnf --showduplicates list sqlite-viewer
sudo dnf downgrade sqlite-viewer-VERSION-RELEASE.x86_64
sudo dnf remove sqlite-viewer
```

Normal `yum` clients supporting rpm-md work with the same repository, but the
binary still requires the supported glibc/OpenSSL/libcurl baseline. This is pull-based
deployment; no GitHub credentials or push agent are needed on target servers.
Upgrades restart an already-running service. Rollback changes only application
files: this viewer performs no production schema migrations. Back up configuration
before changes. Removal stops/disables the service and preserves user databases,
modified config (`.rpmsave` where applicable), and the system account. Review and
remove those retained files/account manually if no longer needed; the package
never deletes your data. Remove the `.repo` file separately to stop update checks.

## Janet formatting

Keep a blank line between top-level functions and between logical sections.
Use Spork's `janet-format` command:

```sh
bash scripts/format.sh          # Format first-party Janet files in place
bash scripts/format.sh --check  # Check without modifying files
```

Run the build first to fetch the pinned Janet and Spork tools. If using an external
dependency directory, pass the same `SV_DEPS_DIR` as the build. The wrapper uses
the Spork revision in `deps.lock`, not an arbitrary globally installed formatter.
Spork is already a dependency, so no additional JPM or runtime dependency is needed.
The formatter normalizes indentation and preserves intentional blank lines; it
does not choose where functions or long expressions should be split.

`scripts/test.sh` runs the formatting check automatically, including in build and
release CI. CI reports unformatted files without rewriting or committing code.
Generated and vendored dependencies are excluded. When adding code, retain the
blank lines between functions and break complex expressions into readable lines.

## Published-package smoke test

Run the **Published RPM install test** workflow manually after publishing a release.
It uses a disposable current Fedora container to install through the public signed
repository, check installed files and the systemd unit, serve the demo as the
service account, downgrade to retained v0.1.0, upgrade to the current release,
reinstall, and remove the package. It verifies that the database,
modified configuration, and service account survive removal. It needs no private
dependency credentials. To run locally with Docker:

```sh
docker run --rm -v "$PWD:/source:ro" fedora:latest bash /source/tests/install-rpm.sh
```

This checks the unit definition but does not boot systemd in the container;
service startup and hardening still need validation on the deployment host.
Run this version of the test after publishing v0.2.0 or later. It also verifies
that upgrading removes the old `/usr/lib/sqlite-viewer` module directory, while
downgrading restores it; configuration and database contents survive both.

## License and provenance

Application code is MIT. Runtime dependencies retain their upstream licenses,
including libjwt's MPL-2.0 and Jurl's Unlicense, in the package. `deps.lock` records source repositories
and exact commits. The vendored Datastar v1.0.2 browser bundle has SHA256
`2837d87acf6ee0ba8e4e63765926c25a98d63883b02f88be194a86b81d3fd24a`.
Its source is [starfederation/datastar v1.0.2](https://github.com/starfederation/datastar/tree/v1.0.2).

### SQL expressions

The viewer builds its table, schema, index, search, filter, and pagination queries
with [janet-sqlexpr](https://github.com/tjisse/janet-sqlexpr), a separate pure Janet
jpm library inspired by HoneySQL. Its exact commit is recorded in `deps.lock` and
its source is embedded in the executable by `scripts/build.sh`.

`(sqlexpr/format query)` returns `[sql params]` for the existing SQLite binding.
The viewer passes these through `query/run`, preserving authorization, read-only
execution, and resource limits. Dynamic table/column names use `sqlexpr/id`;
values use positional bindings. The library also offers the optional
`(sqlexpr/expr (= name ,value))` macro for Lisp-style expression syntax.
