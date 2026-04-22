#!/usr/bin/env bash
set -euo pipefail

zig build test --summary all -- checkpoint_bls
zig build test --summary all -- m4_multi_validator_checkpoint
zig build test --summary all -- "BLS quorum over signingCommitment"
zig build test --summary all -- "BLS bitmap below quorum"

echo "p0_bls_checkpoint_gate: PASS"
