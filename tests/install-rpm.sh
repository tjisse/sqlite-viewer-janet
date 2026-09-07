#!/usr/bin/env bash
# Destructive package lifecycle test: run only inside a disposable Fedora container.
set -euo pipefail
test -f /run/.containerenv || test -f /.dockerenv
dnf -y install curl util-linux
curl -fsSL https://tjisse.github.io/sqlite-viewer-janet/rpm/sqlite-viewer.repo \
  -o /etc/yum.repos.d/sqlite-viewer.repo
# Both package and metadata signature verification must remain enabled.
grep -qx 'gpgcheck=1' /etc/yum.repos.d/sqlite-viewer.repo
grep -qx 'repo_gpgcheck=1' /etc/yum.repos.d/sqlite-viewer.repo
dnf -y install sqlite-viewer
installed_version=$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}' sqlite-viewer)
test ! -e /usr/lib/sqlite-viewer
rpm -V sqlite-viewer
sqlite-viewer --version
systemd-analyze verify /usr/lib/systemd/system/sqlite-viewer.service
runuser -u sqlite-viewer -- sqlite-viewer --seed /var/lib/sqlite-viewer/demo.sqlite
runuser -u sqlite-viewer -- env SV_DEMO_DB=/var/lib/sqlite-viewer/demo.sqlite \
  sqlite-viewer --demo > /tmp/viewer.log 2>&1 &
viewer_pid=$!
trap 'kill "$viewer_pid" 2>/dev/null || true' EXIT
for attempt in {1..30}; do
  if curl -fsS http://127.0.0.1:8080/healthz; then break; fi
  sleep 1
done
curl -fsS http://127.0.0.1:8080/healthz
curl -fsS 'http://127.0.0.1:8080/?table=customers' -o /tmp/viewer.html
grep -q 'customers' /tmp/viewer.html
kill "$viewer_pid"
wait "$viewer_pid" || true
trap - EXIT
printf '\n# Preserve administrator configuration\n' >> /etc/sqlite-viewer/viewer.env
sha256sum /var/lib/sqlite-viewer/demo.sqlite > /tmp/database.sha256
# Exercise the layout migration in both directions, using the retained release.
dnf -y downgrade sqlite-viewer-0.1.0-1.x86_64
test -e /usr/lib/sqlite-viewer/modules/sqlite3.so
sqlite-viewer --version
grep -q 'Preserve administrator configuration' /etc/sqlite-viewer/viewer.env
sha256sum --check /tmp/database.sha256
dnf -y upgrade sqlite-viewer
test "$installed_version" = "$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}' sqlite-viewer)"
test ! -e /usr/lib/sqlite-viewer
sqlite-viewer --version
grep -q 'Preserve administrator configuration' /etc/sqlite-viewer/viewer.env
sha256sum --check /tmp/database.sha256
dnf -y reinstall sqlite-viewer
grep -q 'Preserve administrator configuration' /etc/sqlite-viewer/viewer.env
sha256sum --check /tmp/database.sha256
dnf -y remove sqlite-viewer
test ! -e /usr/bin/sqlite-viewer
grep -q 'Preserve administrator configuration' /etc/sqlite-viewer/viewer.env.rpmsave
sha256sum --check /tmp/database.sha256
getent passwd sqlite-viewer
echo 'Published RPM installation, runtime, downgrade, upgrade, reinstall, and removal passed.'
