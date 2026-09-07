#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/format.sh --check
.build/jpm/sqlite-viewer-tests
python3 tests/integration.py
