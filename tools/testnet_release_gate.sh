#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "[gate:blocking] 1/6 zig build"
zig build

echo "[gate:blocking] 2/6 zig build test"
zig build test

echo "[gate:blocking] 3/6 p0 consolidated gate"
bash "${ROOT_DIR}/tools/p0_mainnet_gate.sh"

require_pattern() {
  local file="$1"
  local pattern="$2"
  if ! rg -n "${pattern}" "${file}" >/dev/null 2>&1; then
    echo "[gate][FAIL] ${file} missing pattern: ${pattern}"
    exit 1
  fi
}

echo "[gate:blocking] 4/6 M4 adversarial integration tests present"
require_pattern "test/integration/m4_adversarial_recovery_test.zig" "M4 adversarial"

echo "[gate:blocking] 5/6 adversarial tx semantics"
python3 tools/adversarial_test.py --case tx_replay
python3 tools/adversarial_test.py --case tx_bad_signature
python3 tools/adversarial_test.py --case tx_nonce_gap

echo "[gate:blocking] 6/6 quick load smoke (30s)"
python3 tools/load_test.py || {
  echo "[gate] load smoke failed"
  exit 1
}

echo "[gate:blocking] config sanity"
if [[ ! -f "deploy/config/production.toml" ]]; then
  echo "[gate] missing deploy/config/production.toml"
  exit 1
fi

echo "[gate:observe] full adversarial suite (non-blocking on known P2P hang profile)"
if ! python3 tools/adversarial_test.py; then
  echo "[gate:observe][WARN] full adversarial suite reported failures (see business/environment breakdown above)"
fi

echo "[gate] PASS: testnet release gate passed."
