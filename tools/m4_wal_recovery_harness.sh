#!/usr/bin/env bash
# Focused M4 WAL recovery integration tests (truncation, cold replay, slash dedupe).
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"
exec zig build test -- --test-filter "M4 WAL recovery"
