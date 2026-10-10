#!/usr/bin/env bash
# Quorum single-source-of-truth gate.
#
# Phase 1.1 found the quorum formula duplicated across nine call sites, written
# two different ways, with three different accept/reject boundaries that
# disagreed by one stake unit:
#
#   Stake.hasQuorum            stake >  threshold
#   Egress.verifyCertificate   stake >= threshold
#   Quorum.hasQuorum           stake >= threshold
#   Mysticeti.hasQuorum        stake >= threshold
#   sdk/proof.quorumThreshold  a *different formula*, stricter for t % 3 != 0
#
# `src/form/consensus/QuorumConfig.zig` is now the only place the formula lives.
# This gate fails if any new literal formula creeps back in, and if the boundary
# behaviour regresses.
set -euo pipefail

cd "$(dirname "$0")/.."

fail=0

# --- 1. No literal quorum formula outside QuorumConfig -----------------------
# Matches both the floor form (x*2)/3+1 and the old SDK spelling (x*2+2)/3+1.
# Comment lines are stripped first so the explanatory note in sdk/proof.zig
# (which quotes the old formula to explain why it was removed) does not trip it.
violations="$(
  grep -rn --include='*.zig' \
    -E '(\* *2 *\) */ *3 *\+ *1|\+ *2\) */ *3 *\+ *1)' \
    src/ \
  | grep -v 'src/form/consensus/QuorumConfig.zig' \
  | grep -v ':[0-9]*: *//' \
  | grep -v ':[0-9]*: *///' \
  || true
)"

if [[ -n "$violations" ]]; then
  echo "FAIL: literal quorum formula outside QuorumConfig.zig:" >&2
  echo "$violations" >&2
  fail=1
fi

# --- 2. Every quorum decision routes through QuorumConfig -------------------
# `Stake.hasQuorum` was the one call site that inlined its own comparison.
if grep -rn --include='*.zig' 'total_accum > self.quorumThreshold()' src/ >/dev/null 2>&1; then
  echo "FAIL: Stake.hasQuorum bypasses QuorumConfig.accepts" >&2
  fail=1
fi

# --- 3. Boundary behaviour is locked by tests -------------------------------
# The regression these guard: a certificate carrying exactly `threshold` stake
# was rejected by Stake.hasQuorum (`>`) and accepted by Egress.verifyCertificate
# (`>=`). Zig 0.17 cannot self-verify that a *filtered* run matched anything — a
# filter matching zero tests still reports success — so this gate checks the two
# things that are actually observable:
#   (a) each boundary test still exists in the source, and
#   (b) the full unit suite is green.
boundary_tests=(
  "accepts: boundary is exactly at threshold (regression)"
  "accepts: the two Comparison styles differ by exactly one unit"
  "thresholdOf: differs from the old SDK spelling when t % 3 != 0"
  "thresholdOf: floor(2t/3)+1 across residues mod 3"
  "byzantineThreshold: honest stake alone cannot always form a quorum"
  "accepts: monotone in accumulated stake"
  "thresholdOf: saturates instead of wrapping on absurd totals"
)

for t in "${boundary_tests[@]}"; do
  if ! grep -qF "test \"$t\"" src/form/consensus/QuorumConfig.zig; then
    echo "FAIL: boundary test missing from QuorumConfig.zig: $t" >&2
    fail=1
  fi
done

zig build test-unit

if [[ $fail -ne 0 ]]; then
  echo "quorum_single_source_gate: FAIL" >&2
  exit 1
fi

echo "quorum_single_source_gate: PASS"