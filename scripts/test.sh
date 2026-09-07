#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/format.sh --check
dist/bin/sqlite-viewer --test tests/core.janet
python3 tests/integration.py
