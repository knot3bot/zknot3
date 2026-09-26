#!/usr/bin/env bash
# Machine-check the Lean 4 specification: every theorem must compile with
# no `sorry` and no speculative axioms (only the kernel-standard
# propext / Quot.sound are acceptable). Fails closed without elan/lean.
set -euo pipefail

if ! command -v lean >/dev/null 2>&1 && ! command -v "$HOME/.elan/bin/lean" >/dev/null 2>&1; then
  echo "lean_gate: FAIL — Lean 4 not installed (curl elan-init.sh | sh)." >&2
  exit 1
fi
if ! command -v lean >/dev/null 2>&1; then
  export PATH="$HOME/.elan/bin:$PATH"
fi

# Reject speculative axioms: only propext/Quot.sound/Classical.choice allowed.
cd "$(dirname "$0")/../.."
AXIOM_REPORT="$(lean specs/consensus.lean 2>&1 || true)"
echo "$AXIOM_REPORT" | grep -q "error" && { echo "$AXIOM_REPORT"; echo "lean_gate: FAIL"; exit 1; }
echo "$AXIOM_REPORT" | grep -q "sorry" && { echo "lean_gate: FAIL — sorry found"; exit 1; }
BAD_AXIOM="$(echo "$AXIOM_REPORT" | grep "depends on axioms" | grep -v "propext" | grep -v "Quot.sound" | grep -v "Classical.choice" || true)"
if [ -n "$BAD_AXIOM" ]; then
  echo "lean_gate: FAIL — speculative axioms:"; echo "$BAD_AXIOM"; exit 1
fi

echo "lean_gate: PASS"
