# OCI Gateway

Automated Oracle Cloud Infrastructure (OCI) instance deployment tool that continuously retries provisioning until successful. Now supports both Terraform (recommended) and OCI Resource Manager approaches.

## Features

- **Terraform Mode (Recommended)**: Full control over infrastructure with version-controlled configuration
- **Resource Manager Mode**: Uses existing OCI stacks (legacy approach)
- Automatic retry on capacity errors
- Detailed error logging with proper log formatting
- Docker containerized for easy deployment
- Configurable infrastructure parameters

## Prerequisites

- Valid OCI API credentials (tenancy OCID, user OCID, API key, etc.)
- Docker and Docker Compose (for containerized deployment)
- Python 3.13+ with `uv` (for local development)
- Your OCI private key file

## Quick Start

### Standalone Deployment (Without Tinsnip)

1. **Set up your environment:**
   ```bash
   # Copy the example environment file
   cp gateway.env.example gateway.env
   
   # Edit with your OCI credentials and keep XDG paths as default home paths
   nano gateway.env
   ```

2. **Place your OCI credentials:**
   ```bash
   # Create the directory structure for OCI API key
   mkdir -p ~/.local/share/dynamicalsystem/gateway/oci/
   
   # Copy your OCI API private key
   cp /path/to/your/oci_api_key.pem ~/.local/share/dynamicalsystem/gateway/oci/
   chmod 600 ~/.local/share/dynamicalsystem/gateway/oci/oci_api_key.pem
   
   # Place SSH public key
   mkdir -p ~/.config/dynamicalsystem/gateway/ssh/
   cp ~/.ssh/id_oci.pub ~/.config/dynamicalsystem/gateway/ssh/
   ```

3. **Run with Docker Compose:**
   ```bash
   docker compose up
   ```

### Tinsnip Deployment

Gateway is a tinsnip-compliant service. When deploying through tinsnip infrastructure:

**Prerequisites:** Tinsnip must be installed and configured on the target machine. See the [tinsnip repository](https://tangled.sh/dynamicalsystem.com/tinsnip) for setup instructions.

1. **Setup tinsnip infrastructure (if not done already):**
   ```bash
   # First-time tinsnip setup (creates tinsnip user, LLDAP, etc.)
   cd ~/.local/opt/dynamicalsystem.tinsnip
   ./setup.sh
   ```

2. **Create gateway's tinsnip machine:**
   ```bash
   # Create gateway's tinsnip machine environment  
   cd ~/.local/opt/dynamicalsystem.tinsnip
   ./machine/setup.sh <service> <environment> <nas-server>
   
   # Example for production gateway with Synology NAS:
   ./machine/setup.sh gateway prod DS412plus
   ```

3. **Deploy as service user:**
   ```bash
   # Switch to service user
   sudo -u gateway-prod -i
   
   # Copy service files
   cp -r ~/.local/opt/dynamicalsystem.service/gateway /mnt/docker/service/
   cd /mnt/docker/service/gateway
   
   # The .env file is automatically generated with:
   # XDG_DATA_HOME=/mnt/tinsnip/data
   # XDG_CONFIG_HOME=/mnt/tinsnip/config
   # XDG_STATE_HOME=/mnt/tinsnip/state
   
   # Deploy
   docker compose up -d
   ```

## Docker Deployment Options

**Default (Rootless - Recommended):**
```bash
# Runs as non-root user (UID/GID 1000 by default)
docker compose up

# Optional: Match your specific user IDs
USER_ID=$(id -u) GROUP_ID=$(id -g) docker compose up
```

**Rootful (Legacy):**
```bash
# For compatibility with systems requiring root containers
docker compose -f docker-compose.rootful.yml up
```

**Key differences:**
- **Default**: Non-root user, SELinux compatible (`:Z` flags), better security
- **Rootful**: Root user, traditional Docker behavior, may have permission issues

## Manual Installation

### Using Terraform (Recommended)

1. Clone the repository:
   ```bash
   git clone https://github.com/dynamicalsystem/gateway.git
   cd gateway
   ```

2. Set up environment:
   ```bash
   cp .env.example .env
   # Edit .env with your OCI credentials
   ```

3. Install dependencies:
   ```bash
   uv sync
   ```

4. Run the Terraform deployment:
   ```bash
   # Source environment variables
   source .env
   
   # Run deployment
   uv run terraform_deploy.py
   ```

### Using Resource Manager (Legacy)

1. Clone the repository:
   ```bash
   git clone https://github.com/dynamicalsystem/gateway.git
   cd gateway
   ```

2. Install dependencies:
   ```bash
   uv sync
   ```

3. Run the application:
   ```bash
   uv run main.py
   ```

### Docker Deployment

1. Build the image:
   ```bash
   docker build -t oci-gateway .
   ```

2. Run with environment variables:
   ```bash
   docker run --env-file .env oci-gateway
   ```

Or use Docker Compose:
```bash
docker compose up -d
```

## Configuration

### Environment Variables

The application uses environment variables for all configuration. See `.env.example` for the complete list.

### File Storage Locations

The application follows XDG Base Directory specification with two deployment modes:

#### Standalone Mode (Default)
- **XDG paths**: Standard user home directories
- **Environment config**: `gateway.env` in project directory
- **Private keys**: `~/.local/share/dynamicalsystem/gateway/oci/`
- **SSH keys**: `~/.config/dynamicalsystem/gateway/ssh/`
- **Terraform state**: `~/.local/state/dynamicalsystem/gateway/terraform/`

#### Tinsnip Mode
- **XDG paths**: NFS mount points (`/mnt/tinsnip/{data,config,state}`)
- **Environment config**: Generated by tinsnip with mount paths
- **Private keys**: `/mnt/tinsnip/data/dynamicalsystem/gateway/oci/`
- **SSH keys**: `/mnt/tinsnip/config/dynamicalsystem/gateway/ssh/`
- **Terraform state**: `/mnt/tinsnip/state/dynamicalsystem/gateway/terraform/`

The key difference is in the `.env` file:
```bash
# Standalone mode
XDG_DATA_HOME=~/.local/share
XDG_CONFIG_HOME=~/.config
XDG_STATE_HOME=~/.local/state

# Tinsnip mode (auto-generated)
XDG_DATA_HOME=/mnt/tinsnip/data
XDG_CONFIG_HOME=/mnt/tinsnip/config
XDG_STATE_HOME=/mnt/tinsnip/state
```

### Security Best Practices

1. **Never commit secrets**: The `.env` file and private keys should never be in version control
2. **Use Docker secrets**: When running in production, use proper Docker secrets management
3. **Protect state files**: Terraform state files contain sensitive data and should be protected
4. **Minimal permissions**: Set file permissions to 600 for private keys

## How It Works

### Terraform Mode (Recommended)
1. Reads infrastructure definition from `terraform/main.tf`
2. Attempts to provision resources using `terraform apply`
3. On capacity errors:
   - Logs the specific error
   - Waits 60 seconds
   - Retries the deployment
4. On success:
   - Displays connection information
   - Exits successfully

### Resource Manager Mode (Legacy)
1. Creates an OCI Resource Manager apply job with auto-approval
2. Monitors job status every 60 seconds
3. On failure:
   - Displays the failure message
   - Fetches and parses job logs for error details
   - Creates a new job and continues monitoring
4. On success or cancellation:
   - Displays final status and exits

## Terraform Configuration

The Terraform configuration in `terraform/main.tf` provisions:
- Ubuntu 22.04 on ARM (VM.Standard.A1.Flex)
- 1 OCPU and 6GB RAM (conservative free tier usage)
- VCN with public subnet
- Internet gateway and security rules
- SSH access configuration

To customize the instance, edit `terraform/main.tf` directly.

## Managing the Service

View logs:
```bash
docker compose logs -f
```

Stop the service:
```bash
docker compose down
```

Check status:
```bash
docker compose ps
```

## GitHub Actions

The repository includes automated Docker image builds on push to:
- `main` and `develop` branches
- Version tags (`v*`)

Images are published to GitHub Container Registry at `ghcr.io/dynamicalsystem/gateway`

## License

[Add your license here]