%global debug_package %{nil}
%global _build_id_links none
Name: sqlite-viewer
Version: 0.1.0
Release: 1
Summary: Reactive read-only SQLite browser built in Janet
License: MIT AND MPL-2.0
URL: https://github.com/tjisse/sqlite-viewer-janet
Source0: sqlite-viewer-0.1.0-runtime.tar.gz
BuildArch: x86_64
Requires: glibc >= 2.38
Requires: openssl-libs >= 3.0
Requires: systemd
Requires(pre): systemd
Requires(pre): shadow-utils
Requires(post): systemd
Requires(preun): systemd
Requires(postun): systemd
AutoReqProv: no

%description
An iOS-inspired SQLite table viewer with Datastar subscriptions, public-key JWT
verification, bounded read-only SQL, and systemd integration. Bundles the Janet
runtime and pinned native bindings. Supports Fedora 40+ x86_64; EL9 requires a
separate build against its older glibc. No database or private keys are bundled.

%prep
%setup -q -n sqlite-viewer-runtime

%build
# The runtime payload is built and tested from deps.lock before packaging.

%install
mkdir -p %{buildroot}/usr/bin %{buildroot}/usr/lib/sqlite-viewer
mkdir -p %{buildroot}/usr/share/licenses/sqlite-viewer %{buildroot}/usr/share/doc/sqlite-viewer
mkdir -p %{buildroot}/usr/lib/systemd/system %{buildroot}/usr/lib/sysusers.d
mkdir -p %{buildroot}/etc/sqlite-viewer %{buildroot}/var/lib/sqlite-viewer
cp -a bin/sqlite-viewer %{buildroot}/usr/bin/
cp -a lib/sqlite-viewer/. %{buildroot}/usr/lib/sqlite-viewer/
cp -a share/licenses/. %{buildroot}/usr/share/licenses/sqlite-viewer/
cp README.md %{buildroot}/usr/share/doc/sqlite-viewer/
cp packaging/sqlite-viewer.service %{buildroot}/usr/lib/systemd/system/
cp packaging/sqlite-viewer.sysusers %{buildroot}/usr/lib/sysusers.d/sqlite-viewer.conf
cp packaging/viewer.env packaging/databases.json %{buildroot}/etc/sqlite-viewer/
find %{buildroot}/usr/lib/sqlite-viewer -type f -exec chmod 0644 {} +
chmod 0755 %{buildroot}/usr/bin/sqlite-viewer

%pre
getent group sqlite-viewer >/dev/null || groupadd --system sqlite-viewer
getent passwd sqlite-viewer >/dev/null || useradd --system --gid sqlite-viewer --home-dir /var/lib/sqlite-viewer --shell /usr/sbin/nologin sqlite-viewer

%post
systemctl daemon-reload >/dev/null 2>&1 || :
# Do not start automatically: the administrator must configure trusted keys.

%preun
if [ "$1" -eq 0 ]; then
  systemctl disable --now sqlite-viewer.service >/dev/null 2>&1 || :
fi

%postun
systemctl daemon-reload >/dev/null 2>&1 || :
if [ "$1" -ge 1 ]; then
  systemctl try-restart sqlite-viewer.service >/dev/null 2>&1 || :
fi

%files
%defattr(0644,root,root,0755)
%attr(0755,root,root) /usr/bin/sqlite-viewer
/usr/lib/sqlite-viewer
/usr/lib/systemd/system/sqlite-viewer.service
/usr/lib/sysusers.d/sqlite-viewer.conf
%license /usr/share/licenses/sqlite-viewer
%doc /usr/share/doc/sqlite-viewer/README.md
%dir %attr(0750,root,sqlite-viewer) /etc/sqlite-viewer
%config(noreplace) %attr(0640,root,sqlite-viewer) /etc/sqlite-viewer/viewer.env
%config(noreplace) %attr(0640,root,sqlite-viewer) /etc/sqlite-viewer/databases.json
%dir %attr(0750,sqlite-viewer,sqlite-viewer) /var/lib/sqlite-viewer

%changelog
* Sun Sep 06 2026 SQLite Viewer contributors - 0.1.0-1
- Initial reactive Janet SQLite viewer.
