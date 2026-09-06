#!/usr/bin/env bash
# Metadata only on Pages; RPM bytes stay in immutable GitHub Releases.
# Input layout: packages/v0.1.0/sqlite-viewer-0.1.0-1.x86_64.rpm
set -euo pipefail
if [[ $# -ne 3 ]]; then echo 'Usage: repository.sh OWNER/REPO PACKAGES_DIR OUTPUT_DIR' >&2; exit 1; fi
repository=$1
packages=$(realpath "$2")
output=$(realpath -m "$3")
mkdir -p "$output"
createrepo_c --checksum sha256 --unique-md-filenames \
  --baseurl "https://github.com/$repository/releases/download/" \
  --outputdir "$output" "$packages"
owner=${repository%/*}
repo=${repository#*/}
sed -e "s|@OWNER@|$owner|g" -e "s|@REPO@|$repo|g" packaging/sqlite-viewer.repo.in > "$output/sqlite-viewer.repo"
if [[ -n "${RPM_SIGNING_KEY:-}" ]]; then
  gpg --batch --yes --armor --detach-sign --local-user "$RPM_SIGNING_KEY" "$output/repodata/repomd.xml"
  gpg --armor --export "$RPM_SIGNING_KEY" > "$output/RPM-GPG-KEY-sqlite-viewer"
fi
