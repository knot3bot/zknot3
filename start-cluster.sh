#!/usr/bin/env bash
# 一键启动 Docker 多节点集群（默认 deploy/docker/docker-compose.yml）
#
# 环境变量：
#   ZKNOT3_COMPOSE_FILE  覆盖 compose 文件路径（默认 deploy/docker/docker-compose.yml）
#   ZKNOT3_DOCKER_DIR    compose 所在目录（默认 deploy/docker）
#
# 用法：
#   ./start-cluster.sh [--build] [--testnet] [-- down|logs|ps]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}"

DOCKER_DIR="${ZKNOT3_DOCKER_DIR:-${REPO_ROOT}/deploy/docker}"
COMPOSE_REL="${ZKNOT3_COMPOSE_FILE:-docker-compose.yml}"
BUILD_IMAGES=0
COMPOSE_CMD=()

if docker compose version &>/dev/null; then
  COMPOSE_CMD=(docker compose)
elif command -v docker-compose &>/dev/null; then
  COMPOSE_CMD=(docker-compose)
else
  echo "[start-cluster] 需要 docker compose 或 docker-compose" >&2
  exit 1
fi

SUBCMD=(up -d)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build)
      BUILD_IMAGES=1
      shift
      ;;
    --testnet)
      COMPOSE_REL="docker-compose-testnet.yml"
      shift
      ;;
    --file|-f)
      COMPOSE_REL="$2"
      shift 2
      ;;
    down|logs|ps|restart|stop|start)
      SUBCMD=("$1")
      shift
      # 其余参数透传（如 logs -f）
      SUBCMD+=("$@")
      break
      ;;
    -h|--help)
      sed -n '1,15p' "$0" | tail -n +2
      exit 0
      ;;
    *)
      echo "[start-cluster] 未知参数: $1" >&2
      exit 1
      ;;
  esac
done

if [[ ! -d "${DOCKER_DIR}" ]]; then
  echo "[start-cluster] 目录不存在: ${DOCKER_DIR}" >&2
  exit 1
fi

COMPOSE_FILE="${DOCKER_DIR}/${COMPOSE_REL}"
if [[ ! -f "${COMPOSE_FILE}" ]]; then
  echo "[start-cluster] 未找到 compose 文件: ${COMPOSE_FILE}" >&2
  exit 1
fi

ENV_FILE="${DOCKER_DIR}/.env"
ENV_EXAMPLE="${DOCKER_DIR}/.env.example"
if [[ ! -f "${ENV_FILE}" ]]; then
  if [[ -f "${ENV_EXAMPLE}" ]]; then
    echo "[start-cluster] 创建 ${ENV_FILE}（从 .env.example 复制，请修改 ZKNOT3_ADMIN_TOKEN）"
    cp "${ENV_EXAMPLE}" "${ENV_FILE}"
  else
    echo "[start-cluster] 缺少 ${ENV_FILE} 且无 .env.example，请手动创建并设置 ZKNOT3_ADMIN_TOKEN" >&2
    exit 1
  fi
fi

if ! grep -q '^ZKNOT3_ADMIN_TOKEN=.\+' "${ENV_FILE}" 2>/dev/null; then
  echo "[start-cluster] 警告: ${ENV_FILE} 中 ZKNOT3_ADMIN_TOKEN 为空或仅为占位，请设为强随机值" >&2
fi

cd "${DOCKER_DIR}"

if [[ "${BUILD_IMAGES}" -eq 1 ]]; then
  echo "[start-cluster] docker build（上下文: ${REPO_ROOT}）"
  docker build -t zknot3:latest -f Dockerfile "${REPO_ROOT}"
fi

echo "[start-cluster] ${COMPOSE_CMD[*]} -f ${COMPOSE_REL} ${SUBCMD[*]}"
"${COMPOSE_CMD[@]}" -f "${COMPOSE_REL}" "${SUBCMD[@]}"

if [[ "${SUBCMD[0]}" == "up" ]]; then
  echo ""
  echo "[start-cluster] 集群已后台启动。默认 RPC 映射见 compose（validator-1 常为宿主机 9003）。"
  echo "[start-cluster] 健康检查示例: curl -sf http://127.0.0.1:9003/health"
fi
