#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

echo "[p0-gate] 1/5 tx admission"
bash "${ROOT_DIR}/tools/p0_tx_admission_gate.sh"

echo "[p0-gate] 2/5 bls checkpoint"
bash "${ROOT_DIR}/tools/p0_bls_checkpoint_gate.sh"

echo "[p0-gate] 3/5 recovery loop"
bash "${ROOT_DIR}/tools/p0_recovery_loop_gate.sh"

echo "[p0-gate] 4/5 mysticeti concurrency"
bash "${ROOT_DIR}/tools/p0_mysticeti_concurrency_gate.sh"

echo "[p0-gate] 5/5 p2p async"
bash "${ROOT_DIR}/tools/p0_p2p_async_gate.sh"

echo "[p0-gate][PASS] all P0 gates passed"
