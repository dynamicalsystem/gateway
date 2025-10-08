terraform {
  required_version = ">= 1.0"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 7.11"
    }
  }
}

# Variables
variable "tenancy_ocid" {}
variable "user_ocid" {}
variable "fingerprint" {}
variable "private_key_path" {}
variable "region" {}
variable "compartment_ocid" {}
variable "ssh_public_key" {}

# Tunnel configuration variables
variable "domain" {
  description = "Your domain for production website"
  type        = string
  default     = "yourdomain.com"
}

variable "email" {
  description = "Email for Let's Encrypt certificates"
  type        = string
  default     = "admin@yourdomain.com"
}

# Provider
provider "oci" {
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = var.private_key_path
  region           = var.region
}

# Get availability domain
data "oci_identity_availability_domain" "ad" {
  compartment_id = var.tenancy_ocid
  ad_number      = 1
}

# Get Ubuntu image
data "oci_core_images" "ubuntu_images" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "22.04"
  shape                    = "VM.Standard.A1.Flex"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

# VCN
resource "oci_core_vcn" "gateway_vcn" {
  compartment_id = var.compartment_ocid
  display_name   = "gateway-vcn"
  cidr_block     = "10.0.0.0/16"
  dns_label      = "gatewayvcn"
}

# Internet Gateway
resource "oci_core_internet_gateway" "gateway_igw" {
  compartment_id = var.compartment_ocid
  display_name   = "gateway-igw"
  vcn_id         = oci_core_vcn.gateway_vcn.id
}

# Route Table
resource "oci_core_default_route_table" "gateway_rt" {
  manage_default_resource_id = oci_core_vcn.gateway_vcn.default_route_table_id
  display_name               = "gateway-route-table"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.gateway_igw.id
  }
}

# Security List (allow SSH and common ports)
resource "oci_core_default_security_list" "gateway_sl" {
  manage_default_resource_id = oci_core_vcn.gateway_vcn.default_security_list_id
  display_name               = "gateway-security-list"

  # Allow SSH
  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"
    tcp_options {
      min = 22
      max = 22
    }
  }

  # Allow HTTP
  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"
    tcp_options {
      min = 80
      max = 80
    }
  }

  # Allow HTTPS
  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"
    tcp_options {
      min = 443
      max = 443
    }
  }

  # Allow all outbound
  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }
}

# Subnet
resource "oci_core_subnet" "gateway_subnet" {
  compartment_id      = var.compartment_ocid
  vcn_id              = oci_core_vcn.gateway_vcn.id
  display_name        = "gateway-subnet"
  cidr_block          = "10.0.0.0/24"
  dns_label           = "gatewaysubnet"
  availability_domain = data.oci_identity_availability_domain.ad.name
}

# Single Instance (Free Tier A1 Flex)
resource "oci_core_instance" "gateway_instance" {
  availability_domain = data.oci_identity_availability_domain.ad.name
  compartment_id      = var.compartment_ocid
  display_name        = "gateway-instance"
  shape               = "VM.Standard.A1.Flex"

  shape_config {
    ocpus         = 1
    memory_in_gbs = 6
  }

  # Max 20 for free tier
  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu_images.images[0].id
    boot_volume_size_in_gbs = "20"
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.gateway_subnet.id
    display_name     = "primary-vnic"
    assign_public_ip = true
    hostname_label   = "gateway"
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data = base64encode(templatefile("/app/setup_secure_tunnel.sh.tpl", {
      domain = var.domain
      email  = var.email
    }))
  }

  timeouts {
    create = "60m"
  }
}

# Outputs
output "instance_public_ip" {
  value = oci_core_instance.gateway_instance.public_ip
}

output "instance_id" {
  value = oci_core_instance.gateway_instance.id
}

output "ssh_command" {
  value = "ssh ubuntu@${oci_core_instance.gateway_instance.public_ip}"
}