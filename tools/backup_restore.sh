#!/bin/bash
# zknot3 Backup & Restore Script
# Usage:
#   ./backup_restore.sh backup  /var/lib/zknot3  /backups/zknot3  [validator_name]
#   ./backup_restore.sh restore /backups/zknot3  /var/lib/zknot3  [timestamp]

set -euo pipefail

ACTION="${1:-}"
DATA_DIR="${2:-./data}"
BACKUP_DIR="${3:-./backups}"
NODE_NAME="${4:-$(hostname)}"

backup() {
    local timestamp
    timestamp="$(date -u +%Y%m%d_%H%M%S)"
    local backup_path="${BACKUP_DIR}/${NODE_NAME}_${timestamp}"

    echo "=== zknot3 Backup ==="
    echo "Source:  ${DATA_DIR}"
    echo "Target:  ${backup_path}"

    mkdir -p "${backup_path}"

    # 1. Grab a consistent checkpoint snapshot (signal node to flush)
    echo "[1/4] Requesting checkpoint flush..."
    curl -s -X POST "http://localhost:9003/rpc" \
        -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","method":"knot3_flushCheckpoint","id":1}' \
        || echo "(node may not be running — proceeding with filesystem backup)"

    # 2. Copy data files
    echo "[2/4] Copying object store..."
    cp -r "${DATA_DIR}/objects" "${backup_path}/" 2>/dev/null || echo "  (no objects directory)"

    echo "[3/4] Copying checkpoints..."
    cp -r "${DATA_DIR}/checkpoints" "${backup_path}/" 2>/dev/null || echo "  (no checkpoints directory)"

    # 3. Snapshot WAL
    echo "[4/4] Capturing WAL state..."
    if [ -f "${DATA_DIR}/data.wal" ]; then
        cp "${DATA_DIR}/data.wal" "${backup_path}/"
    fi

    # 4. Create manifest
    cat > "${backup_path}/MANIFEST" <<MANIFEST
timestamp=${timestamp}
node=${NODE_NAME}
data_dir=${DATA_DIR}
files=$(ls "${backup_path}" | tr '\n' ' ')
MANIFEST

    echo "Backup complete: ${backup_path}"
    echo "${backup_path}" > "${BACKUP_DIR}/latest_backup.txt"
}

restore() {
    local backup_source="${1}"
    local target_dir="${2}"

    echo "=== zknot3 Restore ==="
    echo "Source:  ${backup_source}"
    echo "Target:  ${target_dir}"

    if [ ! -f "${backup_source}/MANIFEST" ]; then
        echo "ERROR: Not a valid backup (missing MANIFEST)"
        exit 1
    fi

    echo "Manifest:"
    cat "${backup_source}/MANIFEST"

    mkdir -p "${target_dir}"

    [ -d "${backup_source}/objects" ] && cp -r "${backup_source}/objects" "${target_dir}/"
    [ -d "${backup_source}/checkpoints" ] && cp -r "${backup_source}/checkpoints" "${target_dir}/"
    [ -f "${backup_source}/data.wal" ] && cp "${backup_source}/data.wal" "${target_dir}/"

    echo "Restore complete. Start the node to recover from WAL."
}

case "${ACTION}" in
    backup)  backup ;;
    restore) restore "${BACKUP_DIR}/$([ -f "${BACKUP_DIR}/latest_backup.txt" ] && cat "${BACKUP_DIR}/latest_backup.txt" || echo "NO_BACKUP")" "${DATA_DIR}" ;;
    *)
        echo "Usage: $0 backup|restore [data_dir] [backup_dir] [node_name]"
        echo "  backup  — snapshot data directory to backup path"
        echo "  restore — restore latest backup to data directory"
        exit 1
        ;;
esac
