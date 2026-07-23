#!/usr/bin/env bash
# ==============================================================================
# zknot3 One-Line Installer Script
# ==============================================================================
# Usage:
#   curl -fsSL https://zknot3.io/install.sh | sh
# ==============================================================================

set -e

BOLD='\033[1m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[zknot3]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[zknot3]${NC} ${BOLD}$1${NC}"
}

log_error() {
    echo -e "${RED}[zknot3 ERROR]${NC} $1"
}

# Detect OS and CPU Architecture
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"

case "$ARCH" in
    x86_64|amd64)
        TARGET_ARCH="x86_64"
        ;;
    aarch64|arm64)
        TARGET_ARCH="aarch64"
        ;;
    riscv64)
        TARGET_ARCH="riscv64"
        ;;
    *)
        log_error "Unsupported architecture: $ARCH"
        exit 1
        ;;
esac

case "$OS" in
    linux)
        TARGET_OS="linux-musl"
        ;;
    darwin)
        TARGET_OS="macos"
        ;;
    *)
        log_error "Unsupported operating system: $OS"
        exit 1
        ;;
esac

BIN_DIR="/usr/local/bin"
if [ ! -w "$BIN_DIR" ]; then
    BIN_DIR="$HOME/.zknot3/bin"
    mkdir -p "$BIN_DIR"
fi

log_info "Detected Platform: ${OS} (${TARGET_ARCH})"
log_info "Target Binary Directory: ${BIN_DIR}"

# Check if prebuilt binary or local build is available
LOCAL_BIN="$(pwd)/zig-out/bin/zknot3-node"
if [ -f "$LOCAL_BIN" ]; then
    log_info "Found local compiled binary. Installing..."
    cp "$LOCAL_BIN" "$BIN_DIR/zknot3-node"
else
    log_info "Building zknot3 node from source..."
    if command -v zig &> /dev/null; then
        zig build -Doptimize=ReleaseSmall
        cp ./zig-out/bin/zknot3-node "$BIN_DIR/zknot3-node"
    else
        log_error "Zig compiler not found. Please install Zig 0.17+ or compile zknot3-node first."
        exit 1
    fi
fi

chmod +x "$BIN_DIR/zknot3-node"

log_success "zknot3-node installed successfully to ${BIN_DIR}/zknot3-node!"
echo ""
echo "Quick Start Commands:"
echo "  1. Check Version:  zknot3-node --version"
echo "  2. Start Local Devnet (4 Validators):  ./deploy/deploy.sh docker"
echo "  3. Start Single Node:  zknot3-node --network devnet"
echo ""
