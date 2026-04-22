#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_DIR="${DEPLOY_DIR}/config"
TARGET_CONFIG="${CONFIG_DIR}/production.toml"
BACKUP_DIR="${CONFIG_DIR}/backups"

usage() {
  cat <<'EOF'
Usage:
  ./deploy/scripts/switch-profile.sh --list
  ./deploy/scripts/switch-profile.sh <profile> [--no-backup]

Profiles:
  conservative
  balanced
  throughput

Examples:
  ./deploy/scripts/switch-profile.sh --list
  ./deploy/scripts/switch-profile.sh balanced
  ./deploy/scripts/switch-profile.sh conservative --no-backup
EOF
}

get_toml_value() {
  local key="$1"
  local file="$2"
  awk -F'=' -v key="$key" '
    $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
      gsub(/[[:space:]]/, "", $2);
      print $2;
      exit;
    }
  ' "$file"
}

detect_current_profile() {
  if [[ ! -f "${TARGET_CONFIG}" ]]; then
    echo "unknown (no production.toml)"
    return
  fi

  local max_per_tick tx_budget per_peer
  max_per_tick="$(get_toml_value "max_messages_per_tick" "${TARGET_CONFIG}")"
  tx_budget="$(get_toml_value "max_transaction_messages_per_tick" "${TARGET_CONFIG}")"
  per_peer="$(get_toml_value "per_peer_batch_limit" "${TARGET_CONFIG}")"

  if [[ "${max_per_tick}" == "192" && "${tx_budget}" == "12" && "${per_peer}" == "3" ]]; then
    echo "conservative"
  elif [[ "${max_per_tick}" == "256" && "${tx_budget}" == "32" && "${per_peer}" == "4" ]]; then
    echo "balanced"
  elif [[ "${max_per_tick}" == "320" && "${tx_budget}" == "104" && "${per_peer}" == "6" ]]; then
    echo "throughput"
  else
    echo "custom"
  fi
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 1
fi

if [[ "$1" == "--list" ]]; then
  echo "Available profiles:"
  echo "  - conservative"
  echo "  - balanced"
  echo "  - throughput"
  echo "Current active profile: $(detect_current_profile)"
  exit 0
fi

PROFILE="$1"
NO_BACKUP="false"
if [[ $# -eq 2 ]]; then
  if [[ "$2" != "--no-backup" ]]; then
    echo "Unknown option: $2" >&2
    usage
    exit 1
  fi
  NO_BACKUP="true"
fi

case "${PROFILE}" in
  conservative|balanced|throughput) ;;
  *)
    echo "Unknown profile: ${PROFILE}" >&2
    usage
    exit 1
    ;;
esac

SOURCE_CONFIG="${CONFIG_DIR}/production-${PROFILE}.toml"
if [[ ! -f "${SOURCE_CONFIG}" ]]; then
  echo "Profile config not found: ${SOURCE_CONFIG}" >&2
  exit 1
fi

if [[ "${NO_BACKUP}" == "false" && -f "${TARGET_CONFIG}" ]]; then
  mkdir -p "${BACKUP_DIR}"
  TS="$(date +%Y%m%d-%H%M%S)"
  BACKUP_FILE="${BACKUP_DIR}/production-${TS}.toml"
  cp "${TARGET_CONFIG}" "${BACKUP_FILE}"
  echo "Backup created: ${BACKUP_FILE}"
fi

cp "${SOURCE_CONFIG}" "${TARGET_CONFIG}"
echo "Switched production profile to: ${PROFILE}"
echo "Active config: ${TARGET_CONFIG}"
