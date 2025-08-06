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

# VCN (Virtual Cloud Network)
resource "oci_core_vcn" "main_vcn" {
  compartment_id = var.compartment_id
  display_name   = "gateway-vcn"
  cidr_blocks    = ["10.0.0.0/16"]
  dns_label      = "gatewayvcn"
}

# Internet Gateway
resource "oci_core_internet_gateway" "main_igw" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main_vcn.id
  display_name   = "gateway-igw"
  enabled        = true
}

# Route Table
resource "oci_core_route_table" "main_route_table" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main_vcn.id
  display_name   = "gateway-route-table"

  route_rules {
    destination       = "0.0.0.0/0"
    network_entity_id = oci_core_internet_gateway.main_igw.id
  }
}

# Security List
resource "oci_core_security_list" "main_security_list" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main_vcn.id
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

# Subnet
resource "oci_core_subnet" "main_subnet" {
  compartment_id    = var.compartment_id
  vcn_id            = oci_core_vcn.main_vcn.id
  display_name      = "gateway-subnet"
  cidr_block        = "10.0.0.0/24"
  route_table_id    = oci_core_route_table.main_route_table.id
  security_list_ids = [oci_core_security_list.main_security_list.id]
  dns_label         = "gatewaysubnet"
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
    subnet_id        = oci_core_subnet.main_subnet.id
    assign_public_ip = true
    display_name     = "primary-vnic"
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    "user_data"         = "#!/bin/bash\napt-get update\napt-get upgrade -y\n# Add any additional setup commands here\n# For example:\n# apt-get install -y docker.io docker-compose\n# usermod -aG docker ubuntu\n"
  }

  depends_on = [
    oci_core_subnet.main_subnet,
    oci_core_internet_gateway.main_igw,
    oci_core_route_table.main_route_table
  ]
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