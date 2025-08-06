terraform {
  required_version = ">= 1.0"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 6.0"
    }
  }
}

# Variables for OCI configuration
variable "tenancy_ocid" {
  description = "OCID of the tenancy"
  type        = string
  default     = ""
}

variable "user_ocid" {
  description = "OCID of the user"
  type        = string
  default     = ""
}

variable "fingerprint" {
  description = "Fingerprint for the key pair"
  type        = string
  default     = ""
}

variable "private_key_path" {
  description = "Path to the private key"
  type        = string
  default     = "~/.oci/oci_api_key.pem"
}

variable "region" {
  description = "OCI region"
  type        = string
  default     = ""
}

variable "compartment_id" {
  description = "Compartment OCID where resources will be created"
  type        = string
  default     = ""
}

variable "availability_domain" {
  description = "Availability domain for the instance"
  type        = string
  default     = ""
}

variable "ssh_public_key" {
  description = "SSH public key for instance access"
  type        = string
  default     = ""
}

# Provider configuration
provider "oci" {
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = var.private_key_path
  region           = var.region
}

# Get Ubuntu 22.04 image
data "oci_core_images" "ubuntu_images" {
  compartment_id           = var.compartment_id
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "22.04"
  shape                    = "VM.Standard.A1.Flex"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

# Check for existing VCN
data "oci_core_vcns" "existing_vcns" {
  compartment_id = var.compartment_id
  display_name   = "gateway-vcn"
}

# VCN (Virtual Cloud Network) - Only create if it doesn't exist
resource "oci_core_vcn" "main_vcn" {
  count          = length(data.oci_core_vcns.existing_vcns.virtual_networks) == 0 ? 1 : 0
  compartment_id = var.compartment_id
  display_name   = "gateway-vcn"
  cidr_blocks    = ["10.0.0.0/16"]
  dns_label      = "gatewayvcn"
}

# Reference to VCN (either existing or newly created)
locals {
  vcn_id = length(data.oci_core_vcns.existing_vcns.virtual_networks) > 0 ? data.oci_core_vcns.existing_vcns.virtual_networks[0].id : oci_core_vcn.main_vcn[0].id
}

# Check for existing Internet Gateway
data "oci_core_internet_gateways" "existing_igws" {
  compartment_id = var.compartment_id
  vcn_id         = local.vcn_id
  display_name   = "gateway-igw"
}

# Internet Gateway - Only create if it doesn't exist
resource "oci_core_internet_gateway" "main_igw" {
  count          = length(data.oci_core_internet_gateways.existing_igws.gateways) == 0 ? 1 : 0
  compartment_id = var.compartment_id
  vcn_id         = local.vcn_id
  display_name   = "gateway-igw"
  enabled        = true
}

locals {
  igw_id = length(data.oci_core_internet_gateways.existing_igws.gateways) > 0 ? data.oci_core_internet_gateways.existing_igws.gateways[0].id : oci_core_internet_gateway.main_igw[0].id
}

# Check for existing Route Table
data "oci_core_route_tables" "existing_route_tables" {
  compartment_id = var.compartment_id
  vcn_id         = local.vcn_id
  display_name   = "gateway-route-table"
}

# Route Table - Only create if it doesn't exist
resource "oci_core_route_table" "main_route_table" {
  count          = length(data.oci_core_route_tables.existing_route_tables.route_tables) == 0 ? 1 : 0
  compartment_id = var.compartment_id
  vcn_id         = local.vcn_id
  display_name   = "gateway-route-table"

  route_rules {
    destination       = "0.0.0.0/0"
    network_entity_id = local.igw_id
  }
}

locals {
  route_table_id = length(data.oci_core_route_tables.existing_route_tables.route_tables) > 0 ? data.oci_core_route_tables.existing_route_tables.route_tables[0].id : oci_core_route_table.main_route_table[0].id
}

# Check for existing Security List
data "oci_core_security_lists" "existing_security_lists" {
  compartment_id = var.compartment_id
  vcn_id         = local.vcn_id
  display_name   = "gateway-security-list"
}

# Security List - Only create if it doesn't exist
resource "oci_core_security_list" "main_security_list" {
  count          = length(data.oci_core_security_lists.existing_security_lists.security_lists) == 0 ? 1 : 0
  compartment_id = var.compartment_id
  vcn_id         = local.vcn_id
  display_name   = "gateway-security-list"

  # Allow SSH
  ingress_security_rules {
    protocol = "6" # TCP
    source   = "0.0.0.0/0"

    tcp_options {
      min = 22
      max = 22
    }
  }

  # Allow HTTP
  ingress_security_rules {
    protocol = "6" # TCP
    source   = "0.0.0.0/0"

    tcp_options {
      min = 80
      max = 80
    }
  }

  # Allow HTTPS
  ingress_security_rules {
    protocol = "6" # TCP
    source   = "0.0.0.0/0"

    tcp_options {
      min = 443
      max = 443
    }
  }

  # Allow all outbound traffic
  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }
}

locals {
  security_list_id = length(data.oci_core_security_lists.existing_security_lists.security_lists) > 0 ? data.oci_core_security_lists.existing_security_lists.security_lists[0].id : oci_core_security_list.main_security_list[0].id
}

# Check for existing Subnet
data "oci_core_subnets" "existing_subnets" {
  compartment_id = var.compartment_id
  vcn_id         = local.vcn_id
  display_name   = "gateway-subnet"
}

# Subnet - Only create if it doesn't exist
resource "oci_core_subnet" "main_subnet" {
  count             = length(data.oci_core_subnets.existing_subnets.subnets) == 0 ? 1 : 0
  compartment_id    = var.compartment_id
  vcn_id            = local.vcn_id
  display_name      = "gateway-subnet"
  cidr_block        = "10.0.0.0/24"
  route_table_id    = local.route_table_id
  security_list_ids = [local.security_list_id]
  dns_label         = "gatewaysubnet"
}

locals {
  subnet_id = length(data.oci_core_subnets.existing_subnets.subnets) > 0 ? data.oci_core_subnets.existing_subnets.subnets[0].id : oci_core_subnet.main_subnet[0].id
}

# Compute Instance - This is what we're actually trying to provision
resource "oci_core_instance" "free_instance" {
  availability_domain = var.availability_domain
  compartment_id      = var.compartment_id
  display_name        = "gateway-ubuntu-instance"
  shape               = "VM.Standard.A1.Flex"

  shape_config {
    ocpus         = 1
    memory_in_gbs = 6
  }

  source_details {
    source_type = "image"
    source_id   = data.oci_core_images.ubuntu_images.images[0].id
  }

  create_vnic_details {
    subnet_id        = local.subnet_id
    assign_public_ip = true
    display_name     = "primary-vnic"
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data = base64encode(<<-EOF
      #!/bin/bash
      apt-get update
      apt-get upgrade -y
      
      # Add any additional setup commands here
      # For example:
      # apt-get install -y docker.io docker-compose
      # usermod -aG docker ubuntu
    EOF
    )
  }
}

# Outputs
output "instance_public_ip" {
  value = oci_core_instance.free_instance.public_ip
}

output "instance_id" {
  value = oci_core_instance.free_instance.id
}

output "ssh_command" {
  value = "ssh ubuntu@${oci_core_instance.free_instance.public_ip}"
}