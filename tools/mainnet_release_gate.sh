#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

echo "[gate:blocking] running build/test checks"
zig build
zig build test

echo "[gate:blocking] M4 WAL recovery harness (focused subset)"
bash "${ROOT_DIR}/tools/m4_wal_recovery_harness.sh"

echo "[gate:blocking] running P0 consolidated gate"
bash "${ROOT_DIR}/tools/p0_mainnet_gate.sh"

require_pattern() {
  local file="$1"
  local pattern="$2"
  if ! rg -n "${pattern}" "${file}" >/dev/null 2>&1; then
    echo "[gate][FAIL] ${file} missing pattern: ${pattern}"
    exit 1
  fi
}

require_no_pattern() {
  local file="$1"
  local pattern="$2"
  if rg -n "${pattern}" "${file}" >/dev/null 2>&1; then
    echo "[gate][FAIL] ${file} contains forbidden pattern: ${pattern}"
    exit 1
  fi
}

echo "[gate:blocking] validating production profile safety defaults"
for cfg in \
  deploy/config/production.toml \
  deploy/config/production-balanced.toml \
  deploy/config/production-conservative.toml \
  deploy/config/production-throughput.toml
do
  require_pattern "${cfg}" "^validator_enabled = false$"
  require_pattern "${cfg}" "^structured = true$"
done

echo "[gate:blocking] checking reserved placeholders on m4 protocol paths"
require_no_pattern "src/app/MainnetExtensionHooks.zig" "\"reserved\""
require_no_pattern "src/form/network/RPC.zig" "rpc-reserved|\"reserved\""
require_no_pattern "src/form/network/HTTPServer.zig" "\"reserved\""
require_no_pattern "src/form/network/AsyncHTTPServer.zig" "\"reserved\""
require_no_pattern "src/app/GraphQL.zig" "graphql-reserved|\"reserved\""

echo "[gate:blocking] M4 strict params / GraphQL parity smoke"
require_pattern "src/form/network/M4RpcParams.zig" "parseStakeOperationInput"
require_pattern "src/app/GraphQL.zig" "M4RpcParams.parseCheckpointProofFromPlainArgs"
require_pattern "test/unit/m4_rpc_params_test.zig" "parseStakeOperationFromPlainArgs"

echo "[gate:blocking] adversarial tx semantics"
python3 tools/adversarial_test.py --case tx_replay
python3 tools/adversarial_test.py --case tx_bad_signature
python3 tools/adversarial_test.py --case tx_nonce_gap

echo "[gate:blocking] validating required docs"
for doc in \
  docs/mainnet_go_live_gate.md \
  docs/mainnet_cutover_checklist.md \
  docs/testnet_runbook.md \
  docs/testnet_incident_template.md
do
  if [[ ! -f "${doc}" ]]; then
    echo "[gate][FAIL] missing required doc: ${doc}"
    exit 1
  fi
done

require_pattern "docs/mainnet_cutover_checklist.md" "Blocking vs Observe"
require_pattern "docs/mainnet_cutover_checklist.md" "验签失败率 > 0.1%"
require_pattern "docs/testnet_runbook.md" "阻塞项（必须通过）"
require_pattern "docs/testnet_runbook.md" "灰度比例：10% -> 30% -> 100%"

echo "[gate:observe] full adversarial suite (manual triage required on failure)"
if ! python3 tools/adversarial_test.py; then
  echo "[gate:observe][WARN] full adversarial suite reported failures; inspect business/environment breakdown before go-live"
fi

echo "[gate][PASS] mainnet release gate passed"
