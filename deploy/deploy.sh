#!/bin/bash
# zknot3 Deployment Script

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== zknot3 Deployment Script ==="
echo ""

# Parse arguments
DEPLOY_MODE="${1:-docker}"
CONFIG_FILE="${2:-$SCRIPT_DIR/config/production.toml}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check prerequisites
check_prereqs() {
    log_info "Checking prerequisites..."
    
    # Check Zig installation
    if ! command -v zig &> /dev/null; then
        log_error "Zig not found. Please install Zig 0.15+"
        exit 1
    fi
    
    ZIG_VERSION=$(zig version)
    log_info "Found Zig $ZIG_VERSION"
}

# Build the project
build() {
    log_info "Building zknot3..."
    cd "$PROJECT_DIR"
    zig build -Doptimize=ReleaseSafe -Dexport-formal=false
    log_info "Build complete"
}

# Run tests
test() {
    log_info "Running tests..."
    cd "$PROJECT_DIR"
    zig build test
    log_info "All tests passed"
}

# Build Docker image
docker_build() {
    log_info "Building Docker image..."
    cd "$PROJECT_DIR"
    docker build -t zknot3:latest -f deploy/docker/Dockerfile .
    log_info "Docker image built: zknot3:latest"
}

# Deploy with Docker Compose
docker_deploy() {
    log_info "Deploying with Docker Compose..."
    cd "$SCRIPT_DIR/docker"
    docker-compose up -d
    log_info "Containers started"
    docker-compose ps
}

# Deploy to Kubernetes
k8s_deploy() {
    log_info "Deploying to Kubernetes..."
    
    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found"
        exit 1
    fi
    
    # Apply manifests
    kubectl apply -f "$SCRIPT_DIR/kubernetes/namespace.yaml"
    kubectl apply -f "$SCRIPT_DIR/kubernetes/validator.yaml"
    
    log_info "Waiting for pods..."
    kubectl wait --for=condition=ready pod -l app=zknot3 -n zknot3 --timeout=120s || true
    
    kubectl get pods -n zknot3
    kubectl get svc -n zknot3
}

# Show usage
usage() {
    echo "Usage: $0 <command> [config_file]"
    
    echo ""
    echo "Commands:"
    echo "  build         Build the project"
    echo "  test          Run tests"
    echo "  docker-build   Build Docker image"
    echo "  docker-deploy  Deploy with Docker Compose"
    echo "  k8s-deploy    Deploy to Kubernetes"
    echo "  all           Build, test, and deploy (default)"
    
    echo ""
    echo "Examples:"
    echo "  $0 build"
    echo "  $0 test"
    echo "  $0 docker-build"
    echo "  $0 docker-deploy"
    echo "  $0 k8s-deploy"
}

# Main
case "$DEPLOY_MODE" in
    build)
        check_prereqs
        build
        ;;
    test)
        test
        ;;
    docker-build)
        check_prereqs
        build
        docker_build
        ;;
    docker-deploy)
        check_prereqs
        build
        docker_build
        docker_deploy
        ;;
    k8s-deploy)
        check_prereqs
        build
        k8s_deploy
        ;;
    all)
        check_prereqs
        build
        test
        docker_build
        log_info "Ready for deployment"
        ;;
    *)
        usage
        exit 1
        ;;
esac

log_info "Done!"
