#!/usr/bin/env bash
set -euo pipefail

zig build test --summary all -- m4_wal_recovery
zig build test --summary all -- m4_adversarial_recovery

echo "p0_recovery_loop_gate: PASS"
