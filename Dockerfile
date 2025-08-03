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
RUN wget -q https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip \
    && unzip terraform_${TERRAFORM_VERSION}_linux_amd64.zip \
    && mv terraform /usr/local/bin/ \
    && rm terraform_${TERRAFORM_VERSION}_linux_amd64.zip \
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

# Create directories with proper ownership
RUN mkdir -p /data /config /state && \
    chown -R appuser:appuser /app /data /config /state

# Switch to non-root user
USER appuser

# Default to terraform deployment script
CMD ["uv", "run", "terraform_deploy.py"]