# Use Python 3.13 slim image
FROM python:3.13-slim

# Set working directory
WORKDIR /app

# Install system dependencies if needed
RUN apt-get update && apt-get install -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*

# Copy dependency files
COPY pyproject.toml uv.lock ./

# Install uv and dependencies
RUN pip install uv && \
    uv sync --frozen

# Copy application code
COPY main.py ./

# Create directory for OCI config (will be mounted at runtime)
RUN mkdir -p /root/.oci

# Run the application
CMD ["uv", "run", "main.py"]