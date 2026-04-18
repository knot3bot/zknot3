#!/bin/bash
# zknot3 CLI 工具
# 提供便捷的命令行操作接口

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# 配置
ZKNOT3_BIN="${ZKNOT3_BIN:-zknot3}"
ZKNOT3_CONFIG="${ZKNOT3_CONFIG:-/etc/zknot3/config.toml}"
ZKNOT3_DATA="${ZKNOT3_DATA:-/var/lib/zknot3}"

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

log_debug() {
    if [ "$VERBOSE" = true ]; then
        echo -e "${PURPLE}[DEBUG]${NC} $1"
    fi
}

# 显示帮助
show_help() {
    cat << EOF
${CYAN}zknot3 CLI${NC} - zknot3 区块链节点管理工具

用法: zknot3-cli [命令] [选项]

命令:
    start           启动 zknot3 节点
    stop            停止 zknot3 节点
    restart         重启 zknot3 节点
    status          查看节点状态
    logs            查看节点日志
    health          健康检查
    config          配置管理
    benchmark       运行基准测试
    version         显示版本信息
    help            显示此帮助信息

选项:
    -v, --verbose   详细输出
    -c, --config    指定配置文件
    -d, --data      指定数据目录
    -h, --help      显示帮助

示例:
    zknot3-cli start
    zknot3-cli status
    zknot3-cli logs -f
    zknot3-cli health
    zknot3-cli config show
EOF
}

# 显示版本
show_version() {
    echo "${CYAN}zknot3 CLI${NC} v1.0.0"
    if command -v "$ZKNOT3_BIN" &> /dev/null; then
        echo "Node binary: $ZKNOT3_BIN"
    else
        log_warning "zknot3 二进制文件未找到"
    fi
}

# 检查节点是否运行
is_running() {
    if pgrep -f "$ZKNOT3_BIN" &> /dev/null; then
        return 0
    else
        return 1
    fi
}

# 获取进程 ID
get_pid() {
    pgrep -f "$ZKNOT3_BIN" 2>/dev/null || true
}

# 启动节点
start_node() {
    log_info "正在启动 zknot3 节点..."
    
    if is_running; then
        log_warning "节点已经在运行 (PID: $(get_pid))"
        return 0
    fi
    
    # 检查配置文件
    if [ ! -f "$ZKNOT3_CONFIG" ]; then
        log_error "配置文件不存在: $ZKNOT3_CONFIG"
        log_info "请使用 --config 指定配置文件"
        return 1
    fi
    
    # 创建数据目录
    mkdir -p "$ZKNOT3_DATA"
    
    # 启动节点
    if [ "$DAEMON" = true ]; then
        nohup "$ZKNOT3_BIN" --config "$ZKNOT3_CONFIG" > "$ZKNOT3_DATA/zknot3.log" 2>&1 &
        local pid=$!
        sleep 2
        if kill -0 $pid 2>/dev/null; then
            log_success "节点已启动 (PID: $pid)"
            echo "$pid" > "$ZKNOT3_DATA/zknot3.pid"
        else
            log_error "节点启动失败，请查看日志: $ZKNOT3_DATA/zknot3.log"
            return 1
        fi
    else
        log_info "在前台运行节点 (按 Ctrl+C 停止)"
        "$ZKNOT3_BIN" --config "$ZKNOT3_CONFIG"
    fi
}

# 停止节点
stop_node() {
    log_info "正在停止 zknot3 节点..."
    
    if ! is_running; then
        log_warning "节点未运行"
        return 0
    fi
    
    local pid=$(get_pid)
    log_info "发送 SIGTERM 到进程 $pid..."
    
    kill "$pid" 2>/dev/null || true
    
    # 等待停止
    local count=0
    while is_running && [ $count -lt 30 ]; do
        sleep 1
        count=$((count + 1))
        log_debug "等待节点停止... ($count/30)"
    done
    
    if is_running; then
        log_warning "节点未响应，发送 SIGKILL..."
        kill -9 "$pid" 2>/dev/null || true
        sleep 2
    fi
    
    if ! is_running; then
        rm -f "$ZKNOT3_DATA/zknot3.pid" 2>/dev/null
        log_success "节点已停止"
    else
        log_error "无法停止节点"
        return 1
    fi
}

# 重启节点
restart_node() {
    log_info "正在重启 zknot3 节点..."
    stop_node
    sleep 2
    start_node
}

# 查看状态
show_status() {
    echo "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo "${CYAN}║                    zknot3 节点状态                              ║${NC}"
    echo "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo
    
    # 运行状态
    if is_running; then
        local pid=$(get_pid)
        echo -e "状态: ${GREEN}运行中${NC}"
        echo "PID: $pid"
        
        # 运行时间
        if command -v ps &> /dev/null; then
            local etime=$(ps -p $pid -o etime= 2>/dev/null || echo "N/A")
            echo "运行时间: $etime"
        fi
        
        # 内存使用
        if command -v ps &> /dev/null; then
            local rss=$(ps -p $pid -o rss= 2>/dev/null || echo "N/A")
            if [ "$rss" != "N/A" ]; then
                local rss_mb=$((rss / 1024))
                echo "内存使用: ${rss_mb} MB"
            fi
        fi
    else
        echo -e "状态: ${RED}已停止${NC}"
    fi
    
    echo
    echo "配置文件: $ZKNOT3_CONFIG"
    echo "数据目录: $ZKNOT3_DATA"
    
    # 健康检查
    if is_running; then
        echo
        health_check
    fi
}

# 查看日志
show_logs() {
    local log_file="$ZKNOT3_DATA/zknot3.log"
    
    if [ ! -f "$log_file" ]; then
        log_warning "日志文件不存在: $log_file"
        log_info "尝试使用 Docker 日志..."
        
        # 尝试 Docker 日志
        if command -v docker &> /dev/null; then
            local containers=$(docker ps -a --filter "name=zknot3" --format "{{.Names}}" 2>/dev/null)
            if [ -n "$containers" ]; then
                log_info "找到 Docker 容器:"
                echo "$containers"
                echo
                log_info "使用 'docker logs <容器名>' 查看日志"
            fi
        fi
        return 1
    fi
    
    if [ "$FOLLOW" = true ]; then
        log_info "跟踪日志 (按 Ctrl+C 停止)..."
        tail -f "$log_file"
    elif [ -n "$LINES" ]; then
        tail -n "$LINES" "$log_file"
    else
        tail -n 100 "$log_file"
    fi
}

# 健康检查
health_check() {
    log_info "执行健康检查..."
    
    # 提取 RPC 端口
    local rpc_port=9000
    if [ -f "$ZKNOT3_CONFIG" ]; then
        rpc_port=$(grep -A 5 -B 0 "rpc_port" "$ZKNOT3_CONFIG" 2>/dev/null | grep -o "[0-9]\+" | head -1 || echo 9000)
    fi
    
    log_debug "RPC 端口: $rpc_port"
    
    # 检查 HTTP 健康端点
    if command -v curl &> /dev/null; then
        local health_url="http://localhost:$rpc_port/health"
        log_debug "检查: $health_url"
        
        local response=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$health_url" 2>/dev/null || echo "000")
        
        if [ "$response" = "200" ]; then
            log_success "健康检查通过"
            return 0
        else
            log_warning "健康检查失败 (HTTP $response)"
            return 1
        fi
    else
        log_warning "curl 不可用，跳过 HTTP 检查"
    fi
}

# 配置管理
config_manage() {
    case $1 in
        show)
            if [ ! -f "$ZKNOT3_CONFIG" ]; then
                log_error "配置文件不存在: $ZKNOT3_CONFIG"
                return 1
            fi
            echo "${CYAN}配置文件: $ZKNOT3_CONFIG${NC}"
            echo "────────────────────────────────────────"
            cat "$ZKNOT3_CONFIG"
            ;;
        edit)
            if [ ! -f "$ZKNOT3_CONFIG" ]; then
                log_error "配置文件不存在: $ZKNOT3_CONFIG"
                return 1
            fi
            ${EDITOR:-nano} "$ZKNOT3_CONFIG"
            ;;
        validate)
            if [ ! -f "$ZKNOT3_CONFIG" ]; then
                log_error "配置文件不存在: $ZKNOT3_CONFIG"
                return 1
            fi
            log_info "验证配置文件..."
            # 基本验证
            if grep -q "rpc_port" "$ZKNOT3_CONFIG" && grep -q "data_dir" "$ZKNOT3_CONFIG"; then
                log_success "配置文件有效"
            else
                log_warning "配置文件可能缺少必要字段"
            fi
            ;;
        *)
            echo "配置管理命令:"
            echo "  show      显示配置"
            echo "  edit      编辑配置"
            echo "  validate  验证配置"
            ;;
    esac
}

# 运行基准测试
run_benchmark() {
    log_info "运行基准测试..."
    
    if ! command -v "zig" &> /dev/null; then
        log_error "Zig 未安装，无法运行基准测试"
        return 1
    fi
    
    if [ ! -d "src" ]; then
        log_error "请在 zknot3 项目根目录运行"
        return 1
    fi
    
    zig build test
}

# 主函数
main() {
    local VERBOSE=false
    local DAEMON=false
    local FOLLOW=false
    local LINES=""
    
    # 解析全局选项
    while [[ $# -gt 0 ]]; do
        case $1 in
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -c|--config)
                ZKNOT3_CONFIG="$2"
                shift 2
                ;;
            -d|--data)
                ZKNOT3_DATA="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                break
                ;;
        esac
    done
    
    local command=${1:-help}
    shift
    
    case $command in
        start)
            # 解析 start 选项
            while [[ $# -gt 0 ]]; do
                case $1 in
                    -d|--daemon)
                        DAEMON=true
                        shift
                        ;;
                    *)
                        shift
                        ;;
                esac
            done
            start_node
            ;;
        stop)
            stop_node
            ;;
        restart)
            restart_node
            ;;
        status)
            show_status
            ;;
        logs)
            # 解析 logs 选项
            while [[ $# -gt 0 ]]; do
                case $1 in
                    -f|--follow)
                        FOLLOW=true
                        shift
                        ;;
                    -n|--lines)
                        LINES="$2"
                        shift 2
                        ;;
                    *)
                        shift
                        ;;
                esac
            done
            show_logs
            ;;
        health)
            health_check
            ;;
        config)
            config_manage "$@"
            ;;
        benchmark)
            run_benchmark
            ;;
        version)
            show_version
            ;;
        help)
            show_help
            ;;
        *)
            log_error "未知命令: $command"
            show_help
            exit 1
            ;;
    esac
}

# 运行主函数
main "$@"
