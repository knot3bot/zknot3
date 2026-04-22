#!/usr/bin/env bash
set -euo pipefail

zig build test --summary all -- tx_admission

# Optional focused adversarial checks (require running node endpoints).
if command -v python3 >/dev/null 2>&1; then
  python3 tools/adversarial_test.py --case=tx_replay || true
  python3 tools/adversarial_test.py --case=tx_bad_signature || true
  python3 tools/adversarial_test.py --case=tx_nonce_gap || true
fi

echo "p0_tx_admission_gate: PASS"
