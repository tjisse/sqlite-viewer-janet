#!/usr/bin/env bash
# Task-specific read-only deploy key; never persist it in Git or build artifacts.
set -euo pipefail
cd "$(dirname "$0")/.."
test -n "${JWT_SOURCE_SSH_KEY:-}" || { echo 'Configure JWT_SOURCE_SSH_KEY for the private janet-jwt dependency' >&2; exit 1; }
keydir=$(mktemp -d)
trap 'rm -f "$keydir/key" "$keydir/known_hosts"; rmdir "$keydir"' EXIT
umask 077
printf '%s\n' "$JWT_SOURCE_SSH_KEY" > "$keydir/key"
unset JWT_SOURCE_SSH_KEY
# GitHub host keys are obtained over authenticated HTTPS, not blind ssh-keyscan.
gh api meta --jq '.ssh_keys[] | "github.com " + .' > "$keydir/known_hosts"
export GIT_SSH_COMMAND="ssh -i $keydir/key -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$keydir/known_hosts"
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0='url.git@github.com:tjisse/janet-jwt.insteadOf'
export GIT_CONFIG_VALUE_0='https://github.com/tjisse/janet-jwt'
bash scripts/build.sh
