#!/usr/bin/env python3
"""
Terraform-based OCI deployment with automatic retry on capacity errors.
"""

import subprocess
import time
import json
import sys
import os
import logging
from datetime import datetime
from pathlib import Path


# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.StreamHandler(sys.stdout)
    ]
)
logger = logging.getLogger(__name__)


class TerraformDeployer:
    def __init__(self, terraform_dir="terraform"):
        self.terraform_dir = Path(terraform_dir)
        self.attempt = 0
        self._setup_terraform_env()
    
    def _setup_terraform_env(self):
        """Set up Terraform environment variables"""
        # Handle Docker secrets for private key
        if Path('/run/secrets/oci_private_key').exists():
            # Copy secret to a temporary location Terraform can read
            import shutil
            temp_key_path = Path('/tmp/oci_api_key.pem')
            shutil.copy('/run/secrets/oci_private_key', temp_key_path)
            temp_key_path.chmod(0o600)
            os.environ['TF_VAR_private_key_path'] = str(temp_key_path)
            logger.info("Using OCI private key from Docker secret")
        
        # Handle SSH public key from file
        ssh_key_path = os.environ.get('OCI_SSH_PUBLIC_KEY_PATH')
        if not ssh_key_path:
            # Use default path - standard SSH location
            ssh_key_path = os.path.expanduser("~/.ssh/id_oci.pub")
        
        if Path(ssh_key_path).exists():
            with open(ssh_key_path, 'r') as f:
                ssh_public_key = f.read().strip()
            os.environ['TF_VAR_ssh_public_key'] = ssh_public_key
            logger.info(f"Using SSH public key from: {ssh_key_path}")
        else:
            logger.warning(f"SSH public key not found at: {ssh_key_path}")
        
        # Set up state file path in XDG hierarchy
        xdg_state_home = os.environ.get('XDG_STATE_HOME', '/state')
        tin_namespace = os.environ.get('TIN_NAMESPACE', 'dynamicalsystem')
        tin_service = os.environ.get('TIN_SERVICE', 'gateway')
        
        state_dir = Path(xdg_state_home) / tin_namespace / tin_service / 'terraform'
        state_dir.mkdir(parents=True, exist_ok=True)
        
        self.state_file_path = state_dir / 'terraform.tfstate'
        logger.info(f"Terraform state will be stored at: {self.state_file_path}")
        
    def run_command(self, cmd, cwd=None):
        """Run a command and return output"""
        result = subprocess.run(
            cmd, 
            shell=True, 
            capture_output=True, 
            text=True,
            cwd=cwd or self.terraform_dir
        )
        return result
    
    def init_terraform(self):
        """Initialize Terraform"""
        logger.info("Initializing Terraform...")
        # Initialize with backend config for state file location
        cmd = f"terraform init -backend-config='path={self.state_file_path}'"
        result = self.run_command(cmd)
        if result.returncode != 0:
            logger.error(f"Error initializing Terraform: {result.stderr}")
            sys.exit(1)
        logger.info("Terraform initialized successfully")
    
    def validate_terraform(self):
        """Validate Terraform configuration"""
        logger.info("Validating Terraform configuration...")
        result = self.run_command("terraform validate")
        if result.returncode != 0:
            logger.error(f"Terraform configuration is invalid: {result.stderr}")
            sys.exit(1)
        logger.info("Terraform configuration is valid")
    
    def apply_terraform(self):
        """Apply Terraform configuration"""
        cmd = "terraform apply -auto-approve -json"
        result = self.run_command(cmd)
        
        # Parse JSON output to find specific errors
        output_lines = result.stdout.strip().split('\n')
        errors = []
        
        for line in output_lines:
            try:
                data = json.loads(line)
                if data.get("@level") == "error":
                    errors.append(data.get("@message", "Unknown error"))
            except json.JSONDecodeError:
                # Some lines might not be JSON
                pass
        
        return result.returncode, errors, result.stderr
    
    def check_capacity_error(self, errors, stderr):
        """Check if errors indicate capacity issues"""
        capacity_indicators = [
            "Out of host capacity",
            "OutOfHostCapacity", 
            "insufficient capacity",
            "no capacity",
            "limit exceeded",
            "quota exceeded",
            "CannotAttachVolume"
        ]
        
        all_error_text = " ".join(errors) + " " + stderr
        
        for indicator in capacity_indicators:
            if indicator.lower() in all_error_text.lower():
                return True
        return False
    
    def deploy_with_retry(self):
        """Main deployment loop with retry logic"""
        self.init_terraform()
        self.validate_terraform()
        
        while True:
            self.attempt += 1
            
            logger.info(f"{'='*60}")
            logger.info(f"Attempt #{self.attempt} - Applying Terraform at {datetime.now()}")
            logger.info(f"{'='*60}")
            
            returncode, errors, stderr = self.apply_terraform()
            
            if returncode == 0:
                logger.info("✅ Deployment SUCCEEDED!")
                
                # Show outputs
                logger.info("Fetching Terraform outputs...")
                output_result = self.run_command("terraform output -json")
                if output_result.returncode == 0:
                    try:
                        outputs = json.loads(output_result.stdout)
                        for key, value in outputs.items():
                            logger.info(f"Output - {key}: {value['value']}")
                    except json.JSONDecodeError:
                        logger.warning("Could not parse Terraform outputs as JSON")
                        logger.info(output_result.stdout)
                
                break
            
            else:
                logger.error("❌ Deployment FAILED")
                
                if errors:
                    logger.error("Error details:")
                    for error in errors:
                        logger.error(f"  - {error}")
                
                if self.check_capacity_error(errors, stderr):
                    logger.info("🔄 Capacity error detected. Will retry in 60 seconds...")
                    logger.info("   (Press Ctrl+C to stop)")
                    
                    try:
                        time.sleep(60)
                    except KeyboardInterrupt:
                        logger.warning("⚠️  Deployment cancelled by user")
                        break
                else:
                    logger.error("Non-capacity error detected. Please check your configuration.")
                    logger.error(f"Full error output: {stderr}")
                    break


def main():
    # Check if terraform directory exists
    if not Path("terraform").exists():
        logger.error("terraform directory not found")
        logger.error("Please ensure you're running this from the project root")
        sys.exit(1)
    
    # Check for environment variables or tfvars file
    required_env_vars = [
        "TF_VAR_tenancy_ocid",
        "TF_VAR_user_ocid", 
        "TF_VAR_fingerprint",
        "TF_VAR_region",
        "TF_VAR_compartment_id",
        "TF_VAR_availability_domain",
        "TF_VAR_ssh_public_key"
    ]
    
    env_vars_set = all(os.environ.get(var) for var in required_env_vars)
    tfvars_path = Path("terraform/terraform.tfvars")
    
    if not env_vars_set and not tfvars_path.exists():
        logger.error("OCI configuration not found")
        logger.error("Please either:")
        logger.error("1. Set environment variables (TF_VAR_tenancy_ocid, etc.)")
        logger.error("2. Copy .env.example to .env and source it")
        logger.error("3. Create terraform/terraform.tfvars from the example")
        sys.exit(1)
    
    if env_vars_set:
        logger.info("Using OCI configuration from environment variables")
    else:
        logger.info("Using OCI configuration from terraform.tfvars")
    
    # Check if terraform is installed
    check_terraform = subprocess.run(
        "terraform version", 
        shell=True, 
        capture_output=True
    )
    if check_terraform.returncode != 0:
        logger.error("Terraform is not installed or not in PATH")
        logger.error("Please install Terraform from https://www.terraform.io/downloads")
        sys.exit(1)
    
    deployer = TerraformDeployer()
    try:
        deployer.deploy_with_retry()
    except Exception as e:
        logger.exception(f"Unexpected error occurred: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()