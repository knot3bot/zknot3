#!/bin/bash
# zknot3 安装脚本
# 用于在本地安装 zknot3 区块链节点

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 默认配置
ZIG_VERSION="0.16.0"
INSTALL_DIR="/usr/local/bin"
DATA_DIR="/var/lib/zknot3"
CONFIG_DIR="/etc/zknot3"
BINARY_NAME="zknot3-node"

# 显示帮助信息
show_help() {
    cat << EOF
zknot3 安装脚本

用法: $0 [选项]

选项:
    -h, --help              显示此帮助信息
    -v, --version           显示版本信息
    -d, --install-dir       安装目录 (默认: $INSTALL_DIR)
    --data-dir              数据目录 (默认: $DATA_DIR)
    --config-dir            配置目录 (默认: $CONFIG_DIR)
    --skip-deps             跳过依赖检查
    --only-build            仅构建，不安装
    --uninstall             卸载 zknot3

示例:
    $0                          # 完整安装
    $0 --install-dir ~/bin     # 安装到用户目录
    $0 --uninstall              # 卸载
EOF
}

# 显示版本
show_version() {
    echo "zknot3 安装脚本 v1.0.0"
    echo "Zig 版本: $ZIG_VERSION"
}

# 检查依赖
check_dependencies() {
    log_info "检查依赖..."
    
    local missing_deps=()
    
    # 检查 build-essential
    if ! command -v gcc &> /dev/null; then
        missing_deps+=("build-essential")
    fi
    
    # 检查 cmake
    if ! command -v cmake &> /dev/null; then
        missing_deps+=("cmake")
    fi
    
    # 检查 git
    if ! command -v git &> /dev/null; then
        missing_deps+=("git")
    fi
    
    # 检查 curl
    if ! command -v curl &> /dev/null; then
        missing_deps+=("curl")
    fi
    
    # 检查 librocksdb
    if ! ldconfig -p 2>/dev/null | grep -q librocksdb; then
        missing_deps+=("librocksdb-dev")
    fi
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_warning "缺少依赖: ${missing_deps[*]}"
        
        if [ "$(id -u)" -eq 0 ]; then
            log_info "尝试自动安装依赖..."
            if [ -f /etc/debian_version ]; then
                apt-get update
                apt-get install -y "${missing_deps[@]}"
            elif [ -f /etc/redhat-release ]; then
                yum install -y "${missing_deps[@]}"
            else
                log_error "无法自动安装依赖，请手动安装: ${missing_deps[*]}"
                exit 1
            fi
        else
            log_error "请使用 root 权限运行或手动安装依赖: ${missing_deps[*]}"
            exit 1
        fi
    fi
    
    log_success "依赖检查完成"
}

# 检测系统架构
detect_arch() {
    local arch=$(uname -m)
    case $arch in
        x86_64|amd64)
            echo "x86_64"
            ;;
        aarch64|arm64)
            echo "aarch64"
            ;;
        *)
            log_error "不支持的架构: $arch"
            exit 1
            ;;
    esac
}

# 安装 Zig
install_zig() {
    local arch=$(detect_arch)
    local zig_url="https://ziglang.org/download/$ZIG_VERSION/zig-$arch-linux-$ZIG_VERSION.tar.xz"
    
    log_info "下载 Zig $ZIG_VERSION ($arch)..."
    
    local temp_dir=$(mktemp -d)
    trap 'rm -rf "$temp_dir"' EXIT
    
    curl -fsSL "$zig_url" -o "$temp_dir/zig.tar.xz"
    
    log_info "解压 Zig..."
    tar xJf "$temp_dir/zig.tar.xz" -C "$temp_dir" --strip-components=1
    
    log_info "安装 Zig 到 $INSTALL_DIR..."
    cp "$temp_dir/zig" "$INSTALL_DIR/"
    
    log_success "Zig 安装完成"
}

# 构建 zknot3
build_zknot3() {
    log_info "构建 zknot3..."
    
    if [ ! -d "src" ]; then
        log_error "请在 zknot3 项目根目录运行此脚本"
        exit 1
    fi
    
    # 检查 Zig 是否可用
    if ! command -v zig &> /dev/null; then
        log_warning "Zig 未找到，尝试安装..."
        install_zig
    fi
    
    # ReleaseSafe 构建（推荐用于生产）
    log_info "使用 ReleaseSafe 模式构建..."
    zig build -Doptimize=ReleaseSafe
    
    log_success "zknot3 构建完成"
}

# 安装 zknot3
install_zknot3() {
    log_info "安装 zknot3..."
    
    # 创建目录
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$DATA_DIR"
    mkdir -p "$CONFIG_DIR"
    
    # 复制二进制文件
    if [ -f "zig-out/bin/zknot3-node-safe" ]; then
        cp "zig-out/bin/zknot3-node-safe" "$INSTALL_DIR/$BINARY_NAME"
        chmod +x "$INSTALL_DIR/$BINARY_NAME"
        log_success "已安装: $INSTALL_DIR/$BINARY_NAME"
    elif [ -f "zig-out/bin/zknot3-node-fast" ]; then
        cp "zig-out/bin/zknot3-node-fast" "$INSTALL_DIR/$BINARY_NAME"
        chmod +x "$INSTALL_DIR/$BINARY_NAME"
        log_success "已安装: $INSTALL_DIR/$BINARY_NAME"
    elif [ -f "zig-out/bin/$BINARY_NAME" ]; then
        cp "zig-out/bin/$BINARY_NAME" "$INSTALL_DIR/$BINARY_NAME"
        chmod +x "$INSTALL_DIR/$BINARY_NAME"
        log_success "已安装: $INSTALL_DIR/$BINARY_NAME"
    else
        log_error "未找到编译的二进制文件，请先构建"
        exit 1
    fi
    
    # 复制配置文件 (支持 JSON 和 TOML)
    if [ -f "deploy/config/production.toml" ]; then
        cp "deploy/config/production.toml" "$CONFIG_DIR/config.toml"
        log_success "TOML 配置已复制到 $CONFIG_DIR"
    fi
    if [ -f "deploy/docker/configs/validator-1.json" ]; then
        cp "deploy/docker/configs/validator-1.json" "$CONFIG_DIR/config.json"
        log_success "JSON 配置已复制到 $CONFIG_DIR"
    fi
    
    # 设置权限
    if [ "$(id -u)" -eq 0 ]; then
        chown -R "$(whoami):$(whoami)" "$DATA_DIR" 2>/dev/null || true
    fi
    
    log_success "zknot3 安装完成"
}

# 卸载 zknot3
uninstall_zknot3() {
    log_warning "正在卸载 zknot3..."
    
    # 确认
    read -p "确定要卸载 zknot3 吗？这将删除二进制文件和配置 (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "取消卸载"
        exit 0
    fi
    
    # 删除二进制文件
    if [ -f "$INSTALL_DIR/$BINARY_NAME" ]; then
        rm "$INSTALL_DIR/$BINARY_NAME"
        log_success "已删除: $INSTALL_DIR/$BINARY_NAME"
    fi
    
    # 删除配置文件（可选）
    read -p "是否删除配置文件 $CONFIG_DIR？(y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if [ -d "$CONFIG_DIR" ]; then
            rm -rf "$CONFIG_DIR"
            log_success "已删除: $CONFIG_DIR"
        fi
    fi
    
    # 询问是否删除数据目录
    read -p "是否删除数据目录 $DATA_DIR？(y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if [ -d "$DATA_DIR" ]; then
            rm -rf "$DATA_DIR"
            log_success "已删除: $DATA_DIR"
        fi
    fi
    
    log_success "zknot3 卸载完成"
}

# 设置 shell 补全
setup_completion() {
    log_info "设置 shell 补全..."
    
    local shell
    if [ -n "$ZSH_VERSION" ]; then
        shell="zsh"
        local comp_dir="$HOME/.zsh/completions"
        mkdir -p "$comp_dir"
        
        cat > "$comp_dir/_$BINARY_NAME" << 'EOF'
#compdef zknot3-node

_zknot3-node() {
    local -a commands
    commands=(
        '--help:Show help message'
        '--version:Show version information'
        '--dev:Start in development mode'
        '--validator:Enable validator mode'
        '--config:Load configuration from file'
        '--rpc-port:Set RPC server port'
        '--p2p-port:Set P2P server port'
        '--log-level:Set log level'
        '--data-dir:Set data directory'
    )
    
    _arguments -C \
        '(-h --help)'{-h,--help}'[Show help message]' \
        '(-v --version)'{-v,--version}'[Show version information]' \
        '(-d --dev)'{-d,--dev}'[Start in development mode]' \
        '--validator[Enable validator mode]' \
        '(-c --config)'{-c,--config}'[Load configuration from file]:file:_files' \
        '--rpc-port[Set RPC server port]:port:_numbers' \
        '--p2p-port[Set P2P server port]:port:_numbers' \
        '--log-level[Set log level]:level:(error warn info debug trace)' \
        '--data-dir[Set data directory]:directory:_directories'
}

_zknot3-node "$@"
EOF
        
        log_success "Zsh 补全已安装到 $comp_dir/_$BINARY_NAME"
        log_info "请添加 'fpath+=($comp_dir)' 到你的 ~/.zshrc"
        
    elif [ -n "$BASH_VERSION" ]; then
        shell="bash"
        local comp_dir="/etc/bash_completion.d"
        if [ ! -d "$comp_dir" ]; then
            comp_dir="$HOME/.bash_completion.d"
            mkdir -p "$comp_dir"
        fi
        
        cat > "$comp_dir/$BINARY_NAME" << 'EOF'
_zknot3-node() {
    local cur prev opts
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    
    opts="--help --version --dev --validator --config --rpc-port --p2p-port --log-level --data-dir"
    
    case "${prev}" in
        --config)
            COMPREPLY=( $(compgen -f -- ${cur}) )
            return 0
            ;;
        --data-dir)
            COMPREPLY=( $(compgen -d -- ${cur}) )
            return 0
            ;;
        --log-level)
            COMPREPLY=( $(compgen -W "error warn info debug trace" -- ${cur}) )
            return 0
            ;;
        zknot3-node)
            COMPREPLY=( $(compgen -W "${opts}" -- ${cur}) )
            return 0
            ;;
    esac
}
complete -F _zknot3-node zknot3-node
EOF
        
        log_success "Bash 补全已安装到 $comp_dir/$BINARY_NAME"
        log_info "请添加 'source $comp_dir/$BINARY_NAME' 到你的 ~/.bashrc"
    fi
}

# 主函数
main() {
    local skip_deps=false
    local only_build=false
    local uninstall=false
    
    # 解析参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--version)
                show_version
                exit 0
                ;;
            -d|--install-dir)
                INSTALL_DIR="$2"
                shift 2
                ;;
            --data-dir)
                DATA_DIR="$2"
                shift 2
                ;;
            --config-dir)
                CONFIG_DIR="$2"
                shift 2
                ;;
            --skip-deps)
                skip_deps=true
                shift
                ;;
            --only-build)
                only_build=true
                shift
                ;;
            --uninstall)
                uninstall=true
                shift
                ;;
            *)
                log_error "未知选项: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                    zknot3 安装程序                              ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo
    
    # 卸载
    if [ "$uninstall" = true ]; then
        uninstall_zknot3
        exit 0
    fi
    
    # 检查依赖
    if [ "$skip_deps" = false ]; then
        check_dependencies
    fi
    
    # 构建
    build_zknot3
    
    # 仅构建模式
    if [ "$only_build" = true ]; then
        log_success "构建完成！二进制文件在 zig-out/bin/"
        exit 0
    fi
    
    # 安装
    install_zknot3
    
    # 设置补全
    setup_completion
    
    echo
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                    安装完成！                                   ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo
    log_info "使用方法:"
    echo "  $BINARY_NAME --config $CONFIG_DIR/config.toml"
    echo
    log_info "查看帮助:"
    echo "  $BINARY_NAME --help"
    echo
}

# 运行主函数
main "$@"
