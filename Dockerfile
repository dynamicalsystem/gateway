# Use Python 3.13 slim image
FROM python:3.13-slim

# Set working directory
WORKDIR /app

# Install system dependencies and Terraform
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget \
    unzip \
    git \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install Terraform
ENV TERRAFORM_VERSION=1.9.5
RUN ARCH=$(uname -m) \
    && if [ "$ARCH" = "x86_64" ]; then TERRAFORM_ARCH="amd64"; elif [ "$ARCH" = "aarch64" ]; then TERRAFORM_ARCH="arm64"; else TERRAFORM_ARCH="$ARCH"; fi \
    && wget -q https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${TERRAFORM_ARCH}.zip \
    && unzip terraform_${TERRAFORM_VERSION}_linux_${TERRAFORM_ARCH}.zip \
    && mv terraform /usr/local/bin/ \
    && rm terraform_${TERRAFORM_VERSION}_linux_${TERRAFORM_ARCH}.zip \
    && terraform version

# Create a non-root user for rootless Docker compatibility
ARG USER_ID=1000
ARG GROUP_ID=1000
RUN groupadd -g ${GROUP_ID} appuser && \
    useradd -u ${USER_ID} -g ${GROUP_ID} -m -s /bin/bash appuser

# Copy dependency files
COPY pyproject.toml uv.lock ./

# Install uv and dependencies
RUN pip install uv && \
    uv sync --frozen

# Copy application code and Terraform configuration
COPY main.py terraform_deploy.py ./
COPY terraform/ ./terraform/
COPY setup_secure_tunnel.sh ./

# Make scripts executable
RUN chmod +x terraform_deploy.py main.py

# Create directories with proper ownership
RUN mkdir -p /data /config /state /app/.terraform && \
    chown -R appuser:appuser /app /data /config /state

# Switch to non-root user
USER appuser

# Set working directory permissions for the user
WORKDIR /app

# Default to terraform deployment script - run with uv but no cache
CMD ["uv", "run", "--no-cache", "terraform_deploy.py"]