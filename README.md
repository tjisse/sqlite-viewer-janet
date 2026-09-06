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
sudo apt-get install build-essential cmake pkg-config libssl-dev git python3-cryptography rpm createrepo-c
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
Keep its `bin/`, `lib/` and `share/` layout intact. The executable embeds Janet;
its application modules and assets live beside it under `lib/sqlite-viewer`.
SQLite, Jansson and libjwt are bundled; OpenSSL and glibc remain system libraries.
The x86_64 artifact requires glibc 2.38+ and OpenSSL 3.0+, suitable for Fedora
40+ (use a currently supported Fedora release). It is **not an EL9 binary**.

## Development and tests

Most application changes are in `src/*.janet`; styling and small browser
enhancements are in `assets/`. `src/sqlite-guard.c` extends the pinned binding
without editing it. `src/main.c` is only a Janet launcher. Build output is `dist/`.
No web routes allow file upload, database mutation, or changing trusted config.

For rapid Janet/UI changes after the first build:

```sh
cp src/*.janet dist/lib/sqlite-viewer/
cp assets/* dist/lib/sqlite-viewer/assets/
dist/bin/sqlite-viewer --demo
```

Restart after server/module changes; refresh the browser after asset changes.
`SV_PORT=8765` changes the development port. To create a standalone sample:

```sh
dist/bin/sqlite-viewer --seed /absolute/path/sample.sqlite
```

Seeding refuses to overwrite an existing file. `scripts/test.sh` runs core Janet
checks and Python integration tests using temporary databases and newly generated
Ed25519 keys. Tests exercise JWT failures, database grants, session cookies,
origin checks, query restrictions/budgets, escaping, 64-bit integer preservation,
commit/rollback hooks, views/search/sort/filter/export, and SSE external commits.
Tests need a local TCP listener; production does not need Python.

## Authentication and authorization

There is no custom JWT cryptography, signing endpoint, password store or implicit
trust in token-supplied keys. `janet-jwt` verifies signatures using **configured
public JWKS**, an issuer, an audience, and an explicit algorithm allowlist. It
checks required expiry and optional not-before claims. The viewer then requires
a nonempty `sub`, the role `viewer`, and a database alias grant:

```json
{
  "iss": "https://auth.example.com",
  "aud": "sqlite-viewer",
  "sub": "alice",
  "exp": 2000000000,
  "roles": ["viewer"],
  "databases": ["Studio"]
}
```

`databases: ["*"]` grants all configured databases. Grants apply to all tables in
that database, including SQL and exports. There is no row/column permission model.
Treat a database grant as permission to read the entire database, including
schema. Obtain tokens from your existing identity provider with a dedicated
audience. The sign-in form accepts such a token and sets an HttpOnly,
SameSite=Strict cookie; HTTPS enables Secure. API clients can instead send
`Authorization: Bearer TOKEN`. Tokens never belong in URLs or browser storage.

Configure the trusted key file from the provider out of band. Each JWK must have
`kid` and `alg` metadata supported by janet-jwt; provide **public keys only**.
Accepted configured algorithms are EdDSA, RS256, PS256, ES256. Startup fails if
auth configuration is absent or invalid. The app does not fetch token-supplied
URLs. Restart after updating JWKS; overlap old/new public keys during rotation.
Short token lifetimes limit revocation delay: there is no online revocation list.
Streams stop at token expiry; logout clears the browser cookie. A copied token
remains usable until expiry. A session cookie lasts at most one hour.

| Setting | Purpose |
|---|---|
| `SV_HOST` | Listen address, default `127.0.0.1` |
| `SV_PORT` | Port, default `8080` |
| `SV_ORIGIN` | Exact browser origin, e.g. `https://sqlite.example.com`, without trailing slash |
| `SV_ISSUER`, `SV_AUDIENCE` | Required trusted token issuer/audience |
| `SV_JWKS` | Path to public JWKS JSON |
| `SV_ALGORITHMS` | Comma-separated allowlist, default `EdDSA` |
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

The binding is pinned to **`change-tracking-hooks` commit `f3c6f4b`**, including the
reviewed garbage-collection, veto and statement-cleanup fixes. `watch.janet`
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
rows. Individual values are capped at 1 MiB on production connections. The C
adapter finalizes statements and clears progress handlers on failures. Integers
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
sudo dnf install ./dist/sqlite-viewer-0.1.0-1.x86_64.rpm
```

Package layout:

| Path | Contents |
|---|---|
| `/usr/bin/sqlite-viewer` | Janet service executable |
| `/usr/lib/sqlite-viewer` | Application, native modules, browser assets |
| `/etc/sqlite-viewer` | Root-managed auth/database configuration |
| `/var/lib/sqlite-viewer` | Service-owned persistent state/sample database |
| `/usr/lib/systemd/system/sqlite-viewer.service` | Hardened unit |

Installation creates a locked `sqlite-viewer` system account. Config files use
`%config(noreplace)`, so upgrades preserve edits. Installation **does not start or
enable** the service before auth is configured. Add `/etc/sqlite-viewer/jwks.json`,
edit `viewer.env` and `databases.json`, set ownership `root:sqlite-viewer` and mode
`0640`. To try the packaged database with real authentication:

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
The application never trusts forwarded identity headers.

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
4. Push a matching version tag (initially `v0.1.0`), let Build and test pass, then
   run **Publish signed RPM repository** with that tag. Publication rebuilds/tests,
   signs the RPM, creates a release, regenerates metadata with retained release
   RPMs, signs `repomd.xml`, and deploys Pages. Both RPM and metadata verification
   remain enabled in the `.repo` file. Update the package/version fields before
   making a new version tag; do not overwrite an existing released RPM.

The signing job deliberately requires maintainer credentials; it never falls
back to `gpgcheck=0`. Local deliverables are unsigned for inspection and require
your release key before distribution as a trusted repository. `repository.sh`
can generate unsigned metadata locally without a key for inspection, but the
generated secure `.repo` intentionally cannot install from that unsigned snapshot.

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
binary still requires the supported glibc/OpenSSL baseline. This is pull-based
deployment; no GitHub credentials or push agent are needed on target servers.
Upgrades restart an already-running service. Rollback changes only application
files: this viewer performs no production schema migrations. Back up configuration
before changes. Removal stops/disables the service and preserves user databases,
modified config (`.rpmsave` where applicable), and the system account. Review and
remove those retained files/account manually if no longer needed; the package
never deletes your data. Remove the `.repo` file separately to stop update checks.

## License and provenance

Application code is MIT. Runtime dependencies retain their upstream licenses,
including libjwt's MPL-2.0, in the package. `deps.lock` records source repositories
and exact commits. The vendored Datastar v1.0.2 browser bundle has SHA256
`2837d87acf6ee0ba8e4e63765926c25a98d63883b02f88be194a86b81d3fd24a`.
Its source is [starfederation/datastar v1.0.2](https://github.com/starfederation/datastar/tree/v1.0.2).
