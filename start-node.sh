#!/usr/bin/env bash
# 一键启动本地 zknot3 节点（仓库根目录执行）
#
# 默认：使用 Zig 默认配置（bind 127.0.0.1，无需 admin_token），并以开发模式启动（--dev）。
# 环境变量：
#   ZKNOT3_BIN   显式指定节点二进制路径
#   ZKNOT3_BUILD 设为 1 时在找不到二进制时自动 zig build
#
# 用法：
#   ./start-node.sh [--build] [--safe|--fast|--debug] [--no-dev] [--] [传递给节点的额外参数…]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}"

BUILD_FIRST=0
VARIANT="safe"
USE_DEV=1
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build)
      BUILD_FIRST=1
      shift
      ;;
    --safe)
      VARIANT="safe"
      shift
      ;;
    --fast)
      VARIANT="fast"
      shift
      ;;
    --debug)
      VARIANT="debug"
      shift
      ;;
    --no-dev)
      USE_DEV=0
      shift
      ;;
    --)
      shift
      EXTRA_ARGS+=("$@")
      break
      ;;
    -h|--help)
      sed -n '1,20p' "$0" | tail -n +2
      exit 0
      ;;
    *)
      EXTRA_ARGS+=("$1")
      shift
      ;;
  esac
done

resolve_bin() {
  local name="zknot3-node-${VARIANT}"
  if [[ -n "${ZKNOT3_BIN:-}" ]]; then
    echo "${ZKNOT3_BIN}"
    return
  fi
  local p="${REPO_ROOT}/zig-out/bin/${name}"
  if [[ -x "$p" ]]; then
    echo "$p"
    return
  fi
  if command -v "${name}" &>/dev/null; then
    command -v "${name}"
    return
  fi
  return 1
}

BIN=""
if ! BIN="$(resolve_bin)"; then
  if [[ "${BUILD_FIRST}" -eq 1 || "${ZKNOT3_BUILD:-0}" == "1" ]]; then
    echo "[start-node] 未找到二进制，正在执行: zig build"
    (cd "${REPO_ROOT}" && zig build)
    BIN="$(resolve_bin)" || {
      echo "[start-node] 构建后仍找不到 zig-out/bin/zknot3-node-${VARIANT}" >&2
      exit 1
    }
  else
    echo "[start-node] 未找到节点二进制。请先运行: zig build" >&2
    echo "[start-node] 或设置 ZKNOT3_BIN，或使用 --build / ZKNOT3_BUILD=1" >&2
    exit 1
  fi
fi

RUN_ARGS=()
if [[ "${USE_DEV}" -eq 1 ]]; then
  RUN_ARGS+=(--dev)
fi
RUN_ARGS+=("${EXTRA_ARGS[@]}")

echo "[start-node] 使用: ${BIN}"
echo "[start-node] 参数: ${RUN_ARGS[*]:-（无）}"
cd "${REPO_ROOT}"
exec "${BIN}" "${RUN_ARGS[@]}"
