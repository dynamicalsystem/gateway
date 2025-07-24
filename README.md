# OCI Gateway

Automated Oracle Cloud Infrastructure (OCI) Resource Manager job executor that continuously monitors and retries failed apply jobs.

## Features

- Automatically creates and monitors OCI Resource Manager apply jobs
- Retries failed jobs with detailed error logging
- Extracts specific error messages from job logs
- Runs continuously until successful completion

## Prerequisites

- OCI CLI configuration (`~/.oci/config`)
- Valid OCI API credentials
- Docker and Docker Compose (for containerized deployment)
- Python 3.13+ with `uv` (for local development)

## Quick Deploy with Docker

Run this command to automatically deploy the service:

```bash
curl -fsSL https://raw.githubusercontent.com/dynamicalsystem/gateway/main/deploy.sh | bash
```

This will:
- Download the docker-compose configuration
- Pull the latest Docker image
- Start the service with your OCI credentials mounted
- Run the job monitor in the background

## Manual Installation

### Local Development

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

2. Run with mounted OCI config:
   ```bash
   docker run -v ~/.oci:/root/.oci:ro oci-gateway
   ```

Or use Docker Compose:
```bash
docker-compose up -d
```

## Configuration

The application expects OCI configuration at `~/.oci/config` with the following structure:

```ini
[DEFAULT]
user=ocid1.user.oc1..aaaaaaaaa...
fingerprint=aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99
tenancy=ocid1.tenancy.oc1..aaaaaaaaa...
region=uk-london-1
key_file=~/.oci/oci_api_key.pem
```

## How It Works

1. Creates an OCI Resource Manager apply job with auto-approval
2. Monitors job status every 60 seconds
3. On failure:
   - Displays the failure message
   - Fetches and parses job logs for `[INFO] Error:` messages
   - Creates a new job and continues monitoring
4. On success or cancellation:
   - Displays final status and exits

## Managing the Service

View logs:
```bash
docker-compose logs -f
```

Stop the service:
```bash
docker-compose down
```

Check status:
```bash
docker-compose ps
```

## GitHub Actions

The repository includes automated Docker image builds on push to:
- `main` and `develop` branches
- Version tags (`v*`)

Images are published to GitHub Container Registry at `ghcr.io/dynamicalsystem/gateway`

## License

[Add your license here]