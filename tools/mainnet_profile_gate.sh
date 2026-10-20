#!/usr/bin/env bash
# Static mainnet profile checks. The full release gate calls this after the
# build and test stages. CI runs this script on its own so the profile cannot
# drift without a green check.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

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
  require_pattern "${cfg}" "^transport = \"tcp\"$"
done

echo "[gate:blocking] validating the validator profile"
validator_cfg="deploy/config/production-validator.toml"
require_pattern "${validator_cfg}" "^validator_enabled = true$"
require_pattern "${validator_cfg}" "^p2p_enabled = true$"
require_pattern "${validator_cfg}" "^structured = true$"
require_pattern "${validator_cfg}" "^transport = \"tcp\"$"
require_pattern "${validator_cfg}" "^epoch_reward = 0$"
require_pattern "${validator_cfg}" "^signing_key_env = \"ZKNOT3_SIGNING_KEY\"$"
require_pattern "${validator_cfg}" "^stake = [1-9]"
require_pattern "${validator_cfg}" "^genesis_path = "
require_no_pattern "${validator_cfg}" "signing_key = \"[0-9a-fA-F]"

genesis="deploy/config/mainnet-genesis.k3gen"
if [[ ! -f "${genesis}" ]]; then
  echo "[gate][FAIL] missing ${genesis}"
  exit 1
fi
hdr="$(head -c 7 "${genesis}")"
if [[ "${hdr}" != "k3gen01" ]]; then
  echo "[gate][FAIL] ${genesis} is not a k3gen01 file"
  exit 1
fi

echo "[gate:blocking] checking reserved placeholders on m4 protocol paths"
require_no_pattern "src/app/MainnetExtensionHooks.zig" "\"reserved\""
require_no_pattern "src/form/network/RPC.zig" "rpc-reserved|\"reserved\""
require_no_pattern "src/form/network/HTTPServer.zig" "\"reserved\""
require_no_pattern "src/form/network/AsyncHTTPServer.zig" "\"reserved\""
require_no_pattern "src/app/GraphQL.zig" "graphql-reserved|\"reserved\""

echo "[profile-gate][PASS]"
