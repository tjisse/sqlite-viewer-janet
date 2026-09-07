#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
root=$PWD
package_dir=$(mktemp -d "$root/.build/package.XXXXXX")
stage=$package_dir/sqlite-viewer-runtime
mkdir -p "$stage" .build/rpm/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS,tmp,db}
cp -a dist/bin dist/share "$stage/"
cp -a packaging README.md "$stage/"
tar -czf .build/rpm/SOURCES/sqlite-viewer-0.2.0-runtime.tar.gz -C "$package_dir" sqlite-viewer-runtime
rpmbuild -bb --nodeps --define "_topdir $root/.build/rpm" \
  --define "_tmppath $root/.build/rpm/tmp" --define "_dbpath $root/.build/rpm/db" \
  --define '_unpackaged_files_terminate_build 1' \
  --define '__os_install_post %{nil}' packaging/sqlite-viewer.spec
cp .build/rpm/RPMS/x86_64/*.rpm dist/
printf 'RPM artifacts are in %s/dist\n' "$root"
