#!/usr/bin/env bash
set -euo pipefail

zig build test --summary all -- mysticeti_property
zig build -Dtsan=true test --summary all -- mysticeti_property

echo "p0_mysticeti_concurrency_gate: PASS"
