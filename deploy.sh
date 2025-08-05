#!/bin/bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${BLUE}[Gateway Deploy]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[Gateway Deploy]${NC} $*"
}

error() {
    echo -e "${RED}[Gateway Deploy]${NC} $*" >&2
    exit 1
}

success() {
    echo -e "${GREEN}[Gateway Deploy]${NC} $*"
}

echo -e "${GREEN}Gateway Service Deployment${NC}"
echo "=========================="

# Check for required commands
command -v docker >/dev/null 2>&1 || error "Docker is not installed"
command -v docker compose >/dev/null 2>&1 || error "Docker Compose is not installed"

# Set XDG defaults if not already set
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"

# Auto-detect deployment mode
detect_deployment_mode() {
    # Check if running as tinsnip service user
    if [[ "$(whoami)" =~ ^[^-]+-[^-]+$ ]]; then
        echo "tinsnip"
        return
    fi
    
    # Check if tinsnip infrastructure exists
    if [[ -f "/etc/tinsnip-namespace" ]] || command -v tinsnip &>/dev/null; then
        # Tinsnip available but not running as service user
        if [[ -d "/mnt/$(whoami 2>/dev/null || echo 'unknown')" ]]; then
            echo "tinsnip"
        else
            echo "tinsnip-admin"
        fi
        return
    fi
    
    echo "standalone"
}

setup_environment() {
    local mode="$1"
    
    case "$mode" in
        "standalone")
            log "Standalone deployment mode"
            SERVICE_DIR="${XDG_DATA_HOME}/dynamicalsystem/gateway"
            ENV_FILE="${XDG_CONFIG_HOME}/dynamicalsystem/gateway/.env"
            COMPOSE_FILES="docker-compose.yml"
            ;;
        "tinsnip")
            log "Tinsnip service deployment mode"
            SERVICE_DIR="/mnt/$(whoami)/service/gateway"
            ENV_FILE="${XDG_CONFIG_HOME}/dynamicalsystem/gateway/.env"
            COMPOSE_FILES="docker-compose.yml:docker-compose.override.yml"
            ;;
        "tinsnip-admin")
            warn "Tinsnip detected but you're not running as a service user"
            warn "To deploy via tinsnip, first create the gateway machine:"
            warn "  cd ~/.local/opt/dynamicalsystem.tinsnip"
            warn "  ./machine/setup.sh gateway prod <nas-server>"
            warn ""
            warn "Then run this script as the service user:"
            warn "  sudo -u gateway-prod -i"
            warn "  curl -fsSL <script-url> | bash"
            error "Cannot deploy in current context"
            ;;
        *)
            error "Unknown deployment mode: $mode"
            ;;
    esac
    
    export SERVICE_DIR ENV_FILE COMPOSE_FILES
}

create_directories() {
    log "Creating directory structure..."
    mkdir -p "$(dirname "$ENV_FILE")"
    mkdir -p "${XDG_DATA_HOME}/dynamicalsystem/gateway/oci"
    mkdir -p "${XDG_CONFIG_HOME}/dynamicalsystem/gateway/ssh"
    mkdir -p "${XDG_STATE_HOME}/dynamicalsystem/gateway"
    
    if [[ "$DEPLOY_MODE" == "standalone" ]]; then
        mkdir -p "$SERVICE_DIR"
    fi
}

create_env_file() {
    if [[ -f "$ENV_FILE" ]]; then
        log "Environment file already exists: $ENV_FILE"
        return
    fi
    
    log "Creating environment file: $ENV_FILE"
    
    cat > "$ENV_FILE" << 'EOF'
# Gateway Service Configuration
# Fill in your OCI credentials below

# OCI API Credentials (required)
OCI_TENANCY_OCID=
OCI_USER_OCID=
OCI_FINGERPRINT=
OCI_REGION=us-phoenix-1
OCI_COMPARTMENT_ID=
OCI_AVAILABILITY_DOMAIN=

# Optional: Deployment mode
# USE_RESOURCE_MANAGER=false    # Use Terraform (default)

# Note: Place your OCI API key at: oci/oci_api_key.pem
# Note: Place your SSH public key at: ssh/id_oci.pub
EOF
    
    warn "Created template environment file: $ENV_FILE"
    warn "Please edit this file with your OCI credentials before running docker compose"
}

deploy_service() {
    local compose_args=()
    
    # Build compose file arguments
    IFS=':' read -ra files <<< "$COMPOSE_FILES"
    for file in "${files[@]}"; do
        if [[ -f "$file" ]]; then
            compose_args+=("-f" "$file")
        else
            warn "Compose file not found: $file"
        fi
    done
    
    if [[ ${#compose_args[@]} -eq 0 ]]; then
        error "No valid compose files found"
    fi
    
    log "Deploying service..."
    log "Working directory: $(pwd)"
    log "Compose files: ${COMPOSE_FILES}"
    log "Environment file: $ENV_FILE"
    
    # Pull latest image
    log "Pulling latest image..."
    docker compose "${compose_args[@]}" pull
    
    # Stop existing container if running
    if docker compose "${compose_args[@]}" ps -q >/dev/null 2>&1; then
        log "Stopping existing container..."
        docker compose "${compose_args[@]}" down
    fi
    
    # Start the service
    log "Starting gateway service..."
    docker compose "${compose_args[@]}" up -d
    
    # Check if service is running
    sleep 2
    if docker compose "${compose_args[@]}" ps | grep -q "Up"; then
        success "✓ Gateway service is running!"
        echo ""
        log "Service management commands:"
        log "  View logs: docker compose ${compose_args[*]} logs -f"
        log "  Stop service: docker compose ${compose_args[*]} down"
        log "  Restart: docker compose ${compose_args[*]} restart"
    else
        error "✗ Failed to start gateway service. Check logs: docker compose ${compose_args[*]} logs"
    fi
}

main() {
    # Detect deployment mode
    DEPLOY_MODE=$(detect_deployment_mode)
    log "Detected deployment mode: $DEPLOY_MODE"
    
    # Setup environment based on mode
    setup_environment "$DEPLOY_MODE"
    
    # Change to service directory
    cd "$SERVICE_DIR"
    
    # Create necessary directories and files
    create_directories
    create_env_file
    
    # Deploy the service
    deploy_service
}

main "$@"