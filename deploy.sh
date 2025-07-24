#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
REPO_URL="https://raw.githubusercontent.com/dynamicalsystem/gateway/main"
COMPOSE_FILE="docker-compose.yml"
DEPLOY_DIR="${DEPLOY_DIR:-$HOME/.local/share/oci-gateway}"

echo -e "${GREEN}OCI Gateway Deployment Script${NC}"
echo "================================"

# Check for required commands
command -v docker >/dev/null 2>&1 || { echo -e "${RED}Error: docker is not installed${NC}" >&2; exit 1; }
command -v docker compose >/dev/null 2>&1 || { echo -e "${RED}Error: docker compose is not installed${NC}" >&2; exit 1; }

# Check for OCI config
if [ ! -d "$HOME/.oci" ]; then
    echo -e "${RED}Error: OCI config directory not found at $HOME/.oci${NC}"
    echo "Please set up OCI CLI configuration first"
    exit 1
fi

if [ ! -f "$HOME/.oci/config" ]; then
    echo -e "${RED}Error: OCI config file not found at $HOME/.oci/config${NC}"
    echo "Please set up OCI CLI configuration first"
    exit 1
fi

# Create deployment directory
echo -e "${YELLOW}Creating deployment directory at $DEPLOY_DIR${NC}"
mkdir -p "$DEPLOY_DIR"
cd "$DEPLOY_DIR"

# Download docker-compose.yml
echo -e "${YELLOW}Downloading docker-compose.yml...${NC}"
curl -fsSL "$REPO_URL/$COMPOSE_FILE" -o "$COMPOSE_FILE"

# Set GitHub repository for image
export GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-dynamicalsystem/gateway}"

# Pull latest image
echo -e "${YELLOW}Pulling latest Docker image...${NC}"
docker compose pull

# Stop existing container if running
if docker compose ps -q >/dev/null 2>&1; then
    echo -e "${YELLOW}Stopping existing container...${NC}"
    docker compose down
fi

# Start the service
echo -e "${YELLOW}Starting OCI Gateway service...${NC}"
docker compose up -d

# Check if service is running
sleep 2
if docker compose ps | grep -q "Up"; then
    echo -e "${GREEN}✓ OCI Gateway is running!${NC}"
    echo ""
    echo "To view logs: docker compose -f $DEPLOY_DIR/$COMPOSE_FILE logs -f"
    echo "To stop: docker compose -f $DEPLOY_DIR/$COMPOSE_FILE down"
else
    echo -e "${RED}✗ Failed to start OCI Gateway${NC}"
    echo "Check logs with: docker compose -f $DEPLOY_DIR/$COMPOSE_FILE logs"
    exit 1
fi