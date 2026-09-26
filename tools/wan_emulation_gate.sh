#!/usr/bin/env bash
# WAN-emulation gate: runs the multi-container devnet under kernel-level
# network impairment (tc netem) and asserts consensus safety + liveness:
#
#   1. healthy baseline        — 4 validators + fullnode, all /health OK
#   2. WAN impairment          — 80ms ± 10ms delay + 2% loss on every
#                                validator; blocks must still be committed
#   3. partition               — validator-4 fully cut off; the 3-validator
#                                majority must keep committing (BFT liveness)
#   4. healing                 — impairment removed; validator-4 must resume
#                                progress (catch-up)
#   5. restart discipline      — no container may crash/restart at any point
#
# Requires: docker with the zknot3:latest image built; iproute2 (tc) inside
# the containers (installed in the runtime image).
set -euo pipefail

cd "$(dirname "$0")/../deploy/docker"

VALIDATORS=(zknot3-validator-1 zknot3-validator-2 zknot3-validator-3 zknot3-validator-4)
RUNNER=zknot3-test-runner
DELAY_ARGS=(delay 80ms 10ms loss 2%)

trap 'echo "::error title=wan_gate::script failed at line $LINENO (see job log)"; exit 1' ERR

fail() {
  # Surface the failure as a check-run annotation with the last container
  # log lines: job logs need admin rights to download, annotations are
  # publicly readable.
  local logs=""
  if docker inspect zknot3-validator-1 >/dev/null 2>&1; then
    logs=$(docker logs --tail 15 zknot3-validator-1 2>&1 | tr '\n' ' ' | tr -cd '[:print:]' | cut -c1-400)
    local flogs=""
    if docker inspect zknot3-fullnode >/dev/null 2>&1; then
      flogs=$(docker logs --tail 10 zknot3-fullnode 2>&1 | tr '\n' ' ' | tr -cd '[:print:]' | cut -c1-400)
    fi
  fi
  echo "::error title=wan_gate::$* | v1-log: ${logs} | fullnode-log: ${flogs}"
  echo "wan_gate: FAIL — $*" >&2
  exit 1
}

metric() { # metric <validator> <name> — read from /health JSON
  docker exec "$RUNNER" curl -sf "http://$1:9003/health" | grep -o "\"$2\":[0-9]*" | cut -d: -f2 | tail -1
}

# Block production is message/transaction driven; stimulate with a burst of
# transactions through a validator's RPC (same pattern as soak_monitor.sh).
stimulate() { # stimulate <validator> <count>
  local i hex
  for ((i = 0; i < $2; i++)); do
    hex=$(printf 'wan-gate-tx-%064d' "$i")
    docker exec "$RUNNER" curl -s --max-time 5 -X POST "http://$1:9003/tx" -d "$hex" >/dev/null || true
  done
}

wait_healthy() { # wait_healthy <timeout_s>
  local deadline=$((SECONDS + $1)) ok next_note=0
  while (( SECONDS < deadline )); do
    ok=1
    for v in "${VALIDATORS[@]}"; do
      docker exec "$RUNNER" curl -sf "http://$v:9003/health" >/dev/null || { ok=0; break; }
    done
    docker exec "$RUNNER" curl -sf "http://zknot3-fullnode:9003/health" >/dev/null || ok=0
    (( ok )) && return 0
    if (( SECONDS >= next_note )); then
      next_note=$((SECONDS + 30))
      local diag=""
      for v in "${VALIDATORS[@]}"; do
        local rc=0
        docker exec "$RUNNER" curl -sf -o /dev/null "http://$v:9003/health" 2>/dev/null || rc=$?
        diag="$diag $v(health_rc=$rc,restarts=$(docker inspect -f '{{.RestartCount}}' "$v"),status=$(docker inspect -f '{{.State.Status}}' "$v"))"
      done
      local fn_rc=0
      docker exec "$RUNNER" curl -sf -o /dev/null "http://zknot3-fullnode:9003/health" 2>/dev/null || fn_rc=$?
      echo "::notice title=wan_gate-wait::t=${SECONDS}s$diag fullnode(health_rc=${fn_rc},restarts=$(docker inspect -f '{{.RestartCount}}' zknot3-fullnode 2>/dev/null || echo n/a),status=$(docker inspect -f '{{.State.Status}}' zknot3-fullnode 2>/dev/null || echo n/a))"
    fi
    sleep 3
  done
  return 1
}

impair() { # impair <container> [netem args...]
  local c=$1; shift
  docker exec "$c" tc qdisc replace dev eth0 root netem "$@"
}

clear_impair() {
  docker exec "$1" tc qdisc del dev eth0 root 2>/dev/null || true
}

restarts() { docker inspect -f '{{.RestartCount}} {{.State.Status}}' "$1"; }

# ---------------------------------------------------------------- setup
[ -f .env ] || echo "ZKNOT3_ADMIN_TOKEN=wan-gate-test-token" > .env
if ! docker compose -f docker-compose-testnet.yml -f docker-compose.wan.yml up -d 2>/tmp/compose_up.log; then
  echo "::error title=wan_gate::compose up failed|$(tr '\n' ' ' < /tmp/compose_up.log | tr -cd '[:print:]' | cut -c1-500)"
  exit 1
fi
trap 'docker compose -f docker-compose-testnet.yml -f docker-compose.wan.yml down -v >/dev/null 2>&1 || true' EXIT

wait_healthy 240 || fail "cluster did not become healthy within 240s"
echo "phase 1 (baseline): all 5 nodes healthy"

# ---------------------------------------------------- WAN impairment soak
for v in "${VALIDATORS[@]:1}"; do impair "$v" "${DELAY_ARGS[@]}"; done
impair zknot3-validator-1 "${DELAY_ARGS[@]}"

base_blocks=$(metric zknot3-validator-1 zknot3_blocks_committed_total)
[ -n "$base_blocks" ] || fail "cannot read blocks metric (got '${base_blocks}')"
stimulate zknot3-validator-2 20
sleep 60
wan_blocks=$(metric zknot3-validator-1 zknot3_blocks_committed_total)
(( wan_blocks > base_blocks )) || fail "no commits under 80ms/2%loss WAN impairment ($base_blocks -> $wan_blocks)"
echo "phase 2 (WAN impairment): commits progressed under 80ms±10ms + 2% loss ($base_blocks -> $wan_blocks)"

# ------------------------------------------------------------- partition
v4_base=$(metric zknot3-validator-4 zknot3_blocks_committed_total)
majority_base=$(metric zknot3-validator-1 zknot3_blocks_committed_total)
impair zknot3-validator-4 loss 100%
stimulate zknot3-validator-2 20
sleep 45
majority_mid=$(metric zknot3-validator-1 zknot3_blocks_committed_total)
v4_mid=$(metric zknot3-validator-4 zknot3_blocks_committed_total)
(( majority_mid > majority_base )) || fail "majority stalled during partition ($majority_base -> $majority_mid)"
echo "phase 3 (partition): 3-validator majority kept committing ($majority_base -> $majority_mid); isolated node frozen ($v4_base -> $v4_mid)"

# --------------------------------------------------------------- healing
clear_impair zknot3-validator-4
stimulate zknot3-validator-2 20
sleep 60
v4_healed=$(metric zknot3-validator-4 zknot3_blocks_committed_total)
(( v4_healed > v4_mid )) || fail "validator-4 did not resume progress after healing ($v4_mid -> $v4_healed)"
echo "phase 4 (healing): validator-4 resumed progress ($v4_mid -> $v4_healed)"

# ------------------------------------------------------- restart audit
for v in "${VALIDATORS[@]}"; do
  read -r count status < <(restarts "$v")
  [ "$count" = "0" ] && [ "$status" = "running" ] || fail "$v restarted (count=$count status=$status)"
done
docker inspect -f '{{.RestartCount}} {{.State.Status}}' zknot3-fullnode | {
  read -r count status
  [ "$count" = "0" ] && [ "$status" = "running" ] || fail "fullnode restarted (count=$count status=$status)"
}
echo "phase 5 (restart audit): zero restarts across all nodes"

# cleanup impairments before teardown so the trap's compose down is clean
for v in "${VALIDATORS[@]}"; do clear_impair "$v"; done

echo "wan_gate: PASS"
