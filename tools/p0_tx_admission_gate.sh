#!/usr/bin/env bash
set -euo pipefail

zig build test --summary all -- tx_admission

# Focused adversarial checks. These need a running node endpoint; when the
# python deps (pynacl, blake3) are missing the gate FAILS CLOSED instead of
# silently skipping the checks -- a skipped check must never read as PASS.
if command -v python3 >/dev/null 2>&1; then
  if ! python3 -c 'import nacl, blake3' >/dev/null 2>&1; then
    echo "p0_tx_admission_gate: FAIL -- missing python deps (pynacl, blake3)." >&2
    echo "Install with: python3 -m pip install --user pynacl blake3" >&2
    exit 1
  fi
  python3 tools/adversarial_test.py --case=tx_replay
  python3 tools/adversarial_test.py --case=tx_bad_signature
  python3 tools/adversarial_test.py --case=tx_nonce_gap
fi

echo "p0_tx_admission_gate: PASS"
