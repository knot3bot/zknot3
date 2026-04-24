#!/bin/bash
# zknot3 soak test monitor
# Usage: ./tools/soak_monitor.sh [duration_hours]

set -e

DURATION_HOURS="${1:-24}"
# Compute total seconds using awk to handle floating point
DURATION_SECS=$(awk "BEGIN {printf \"%d\", $DURATION_HOURS * 3600}")
INTERVAL_SECS=30
LOG_DIR="./soak_logs"
mkdir -p "$LOG_DIR"

VALIDATORS=("zknot3-validator-1" "zknot3-validator-2" "zknot3-validator-3" "zknot3-validator-4")
FULLNODE="zknot3-fullnode"
ALL_NODES=("${VALIDATORS[@]}" "$FULLNODE")

RPC_PORTS=(9003 9013 9023 9033 9043)

START_TIME=$(date +%s)
END_TIME=$((START_TIME + DURATION_SECS * 3600))

echo "=== zknot3 Soak Test Monitor ==="
echo "Duration: ${DURATION_HOURS}h"
echo "Interval: ${INTERVAL_SECS}s"
echo "Started at: $(date -r $START_TIME '+%Y-%m-%d %H:%M:%S')"
echo "Expected end: $(date -r $END_TIME '+%Y-%m-%d %H:%M:%S')"
echo ""

FAILURES=0
MAX_FAILURES=3

check_http() {
    local port=$1
    local name=$2
    if ! curl -s --max-time 5 "http://localhost:${port}/health" > /dev/null 2>&1; then
        echo "[FAIL] HTTP health check failed for ${name} (port ${port})"
        return 1
    fi
    return 0
}

check_container() {
    local name=$1
    local status
    status=$(docker inspect --format='{{.State.Status}}' "$name" 2>/dev/null || echo "missing")
    if [ "$status" != "running" ]; then
        echo "[FAIL] Container ${name} is not running (status: ${status})"
        return 1
    fi
    return 0
}

check_consensus() {
    local port=$1
    local name=$2
    local round
    round=$(curl -s --max-time 5 "http://localhost:${port}/api/consensus/status" 2>/dev/null | grep -o '"current_round":[0-9]*' | cut -d: -f2 || echo "0")
    if [ "$round" = "0" ] || [ -z "$round" ]; then
        echo "[WARN] ${name}: consensus endpoint unreachable or round=0"
        return 1
    fi
    echo "[OK] ${name}: round=${round}"
    return 0
}

submit_tx() {
    local port=$1
    local result
    result=$(curl -s --max-time 5 -X POST "http://localhost:${port}/tx" -d '0000000000000000000000000000000000000000000000000000000000000001' 2>/dev/null || echo "fail")
    if [ "$result" = "{\"success\":true}" ]; then
        return 0
    fi
    return 1
}

ITERATION=0
while true; do
    NOW=$(date +%s)
    if [ "$NOW" -ge "$END_TIME" ]; then
        echo ""
        echo "=== Soak test completed successfully ==="
        echo "Ran for ${DURATION_HOURS} hours with ${ITERATION} iterations."
        exit 0
    fi

    ITERATION=$((ITERATION + 1))
    ELAPSED=$((NOW - START_TIME))
    ELAPSED_H=$((ELAPSED / 3600))
    ELAPSED_M=$(((ELAPSED % 3600) / 60))

    echo "--- [$(date '+%H:%M:%S')] Iteration ${ITERATION} | Elapsed: ${ELAPSED_H}h ${ELAPSED_M}m ---"

    ALL_OK=true

    # Check containers
    for node in "${ALL_NODES[@]}"; do
        if ! check_container "$node"; then
            ALL_OK=false
            FAILURES=$((FAILURES + 1))
        fi
    done

    # Check HTTP and consensus on validators
    for i in "${!VALIDATORS[@]}"; do
        node="${VALIDATORS[$i]}"
        port="${RPC_PORTS[$i]}"
        if ! check_http "$port" "$node"; then
            ALL_OK=false
            FAILURES=$((FAILURES + 1))
        else
            if ! check_consensus "$port" "$node"; then
                ALL_OK=false
            fi
        fi
    done

    # Check fullnode HTTP
    if ! check_http "9043" "$FULLNODE"; then
        ALL_OK=false
        FAILURES=$((FAILURES + 1))
    fi

    # Submit a test transaction every 10 iterations (~5 minutes)
    if [ $((ITERATION % 10)) -eq 0 ]; then
        if submit_tx "9003"; then
            echo "[OK] TX submitted successfully"
        else
            echo "[WARN] TX submission failed"
            ALL_OK=false
        fi
    fi

    # Collect container restart counts
    for node in "${ALL_NODES[@]}"; do
        restarts=$(docker inspect --format='{{.RestartCount}}' "$node" 2>/dev/null || echo "?")
        if [ "$restarts" != "0" ]; then
            echo "[WARN] ${node} has ${restarts} restart(s)"
        fi
    done

    if [ "$ALL_OK" = true ]; then
        echo "[PASS] All checks passed"
    fi

    if [ "$FAILURES" -ge "$MAX_FAILURES" ]; then
        echo ""
        echo "=== SOAK TEST FAILED ==="
        echo "Too many failures (${FAILURES}). Investigate immediately."
        echo "Dumping last 50 lines of validator-1 logs:"
        docker logs --tail 50 zknot3-validator-1 2>&1 | tee "${LOG_DIR}/validator-1-failure.log"
        exit 1
    fi

    sleep "$INTERVAL_SECS"
done
