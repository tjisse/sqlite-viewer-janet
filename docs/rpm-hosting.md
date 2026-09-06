# Public RPM hosting: checked 6 September 2026

## Decision

Use GitHub Releases for RPM payloads and GitHub Pages for signed `repodata/`,
the public signing key, and `.repo` configuration. The existing GitHub Actions
build can maintain both; target machines use ordinary dnf/yum. This is a choice
for a small project, not a promise of unlimited free CDN service.

| Option | Practical free offer | Maintenance/tradeoff |
|---|---|---|
| Releases + Pages metadata | Public repositories can use free Pages; Releases host assets. Pages has a 1 GB site limit and 100 GB/month soft bandwidth limit. Release assets are individually limited to 2 GiB. | Best fit here: build once in Actions; host small metadata on Pages and larger RPMs in Releases. Manage signing and retention yourself. |
| Fedora Copr | Public build service with generated RPM repositories for supported build targets. | Excellent when all sources/build inputs can be publicly fetched. Requires Fedora account/project setup, build-environment adaptation and policy compliance. Private janet-jwt source currently prevents a clean public-source build. |
| openSUSE Open Build Service | Public reference service for free/open-source projects; multi-distribution and architecture builds/repositories. | Strong packaging service, but project/repository definitions and source-service workflow add work compared with the already-requested Actions build. Private dependency access is again an obstacle. |
| Cloudsmith Core / OSS program | Current Core pricing lists $0/month, 500 MB artifact data and 1 GB package delivery. An OSS program is also advertised for qualifying public licensed projects. | Native package hosting is convenient, but the ordinary free quota is small. Do not assume the OSS program's expanded allowance is automatic or permanent; confirm current eligibility and allowance. |
| Static Pages-only RPM repo | A regular static host can serve rpm-md and RPMs directly. | Simplest technical layout, but all retained RPM bytes consume the site's storage/bandwidth budget. Keeping payloads in Releases makes Pages growth much smaller. |

Sources: [GitHub Pages limits](https://docs.github.com/en/pages/getting-started-with-github-pages/github-pages-limits),
[GitHub Releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases),
[Copr user documentation](https://docs.copr.fedorainfracloud.org/user_documentation.html),
[Open Build Service](https://openbuildservice.org/),
[Cloudsmith pricing](https://cloudsmith.com/pricing), and
[Cloudsmith OSS program](https://cloudsmith.com/blog/cloudsmith-loves-opensource).
Limits and eligibility can change. Check the provider's terms before a large
rollout; this project makes no zero-cost guarantee beyond the documented free
tiers and public-project assumptions.

## Repository mechanics

`scripts/repository.sh OWNER/REPO packages site/rpm` expects:

```text
packages/
  v0.1.0/sqlite-viewer-0.1.0-1.x86_64.rpm
  v0.2.0/sqlite-viewer-0.2.0-1.x86_64.rpm
```

`createrepo_c --baseurl https://github.com/OWNER/REPO/releases/download/` records
each versioned relative location in metadata. Dnf fetches metadata from Pages and
RPMs from their versioned release URLs. A GitHub Release alone cannot serve a
normal nested `repodata/repomd.xml` layout; it is not by itself an rpm-md repository.

Sign RPMs **before** generating metadata so checksums match. Sign the final
`repodata/repomd.xml` and publish its detached ASCII signature alongside it.
Publish the public key separately; never put the private key in Git, the runtime
archive, the metadata tree or release assets. Pages deployment switches the
metadata site as one artifact; retain old RPMs for clients holding cached metadata
and for explicit rollback. Routine clients need no GitHub login.

If the project becomes large, Copr is the most natural alternative once all build
sources are public. OBS is attractive when additional distribution/architecture
targets justify its configuration. Cloudsmith is attractive if its approved OSS
program covers measured delivery volume, but adds a service credential and quota
dependency. These are deployment options, not accounts created by this project.
