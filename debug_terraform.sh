#!/bin/bash

# Script to debug terraform apply with full request logging

echo "Setting up debug environment..."
export TF_LOG=TRACE
export TF_LOG_PATH=/tmp/terraform-trace.log
export OCI_GO_SDK_DEBUG=v

# Set terraform variables from environment
export TF_VAR_tenancy_ocid="${OCI_TENANCY_OCID}"
export TF_VAR_user_ocid="${OCI_USER_OCID}"
export TF_VAR_fingerprint="${OCI_FINGERPRINT}"
export TF_VAR_region="${OCI_REGION}"
export TF_VAR_compartment_id="${OCI_COMPARTMENT_ID}"
export TF_VAR_availability_domain="${OCI_AVAILABILITY_DOMAIN}"

# Handle private key
if [ -f "/secrets/oci_api_key.pem" ]; then
    cp /secrets/oci_api_key.pem /tmp/oci_api_key.pem
    chmod 600 /tmp/oci_api_key.pem
    export TF_VAR_private_key_path="/tmp/oci_api_key.pem"
elif [ -f "/run/secrets/oci_private_key" ]; then
    cp /run/secrets/oci_private_key /tmp/oci_api_key.pem
    chmod 600 /tmp/oci_api_key.pem
    export TF_VAR_private_key_path="/tmp/oci_api_key.pem"
fi

# Handle SSH key
if [ -f "/secrets/id_oci.pub" ]; then
    export TF_VAR_ssh_public_key=$(cat /secrets/id_oci.pub)
fi

cd terraform

echo "Running terraform init..."
if ! terraform init; then
    echo "ERROR: Terraform init failed! Check provider configuration."
    exit 1
fi
echo "✓ Terraform init successful"

echo "Running terraform fmt check..."
if ! terraform fmt -check -diff; then
    echo "WARNING: Terraform formatting issues detected. Run 'terraform fmt' to fix."
fi

echo "Running terraform validate..."
if ! terraform validate; then
    echo "ERROR: Terraform validation failed! Exiting before hitting OCI APIs."
    exit 1
fi
echo "✓ Terraform validation passed"

echo "Running terraform plan with trace logging..."
terraform plan -no-color > /tmp/plan.txt 2>&1

echo "Checking plan output..."
cat /tmp/plan.txt

echo ""
echo "Searching for request details in trace log..."
grep -A 20 -B 5 "LaunchInstance\|Request Body\|shape_config\|metadata" /tmp/terraform-trace.log | head -200

echo ""
echo "Running terraform show to display exact resource configuration..."
terraform show -json /tmp/tfplan 2>/dev/null | jq '.planned_values.root_module.resources[] | select(.type=="oci_core_instance")' 2>/dev/null

echo ""
echo "Attempting terraform apply with trace logging..."
terraform apply -auto-approve 2>&1 | tee /tmp/apply.log

echo ""
echo "Extracting error details from trace log..."
grep -A 30 "400-CannotParseRequest\|Request Body\|request body" /tmp/terraform-trace.log | tail -100