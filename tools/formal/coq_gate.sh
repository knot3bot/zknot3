#!/usr/bin/env bash
# Machine-check the Coq/Rocq specification: every theorem must compile
# under coqc with no unproved goals. Fails closed when coqc is absent.
set -euo pipefail

if ! command -v coqc >/dev/null 2>&1; then
  echo "coq_gate: FAIL — coqc not installed (brew install coq)." >&2
  exit 1
fi

cd "$(dirname "$0")/../.."
coqc specs/consensus.v
rm -f specs/consensus.vo specs/consensus.glob specs/.consensus.aux

echo "coq_gate: PASS"
