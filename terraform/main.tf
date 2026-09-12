terraform {
  required_version = ">= 1.0"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 7.11"
    }
  }

  # Declaring the backend lets `terraform init -backend-config=path=...`
  # point state at the mounted /state volume. Without this block Terraform
  # ignores the flag and writes state into the container's temp directory,
  # where it is lost on every restart.
  backend "local" {}
}

# Variables
variable "tenancy_ocid" {}
variable "user_ocid" {}
variable "fingerprint" {}
variable "private_key_path" {}
variable "region" {}
variable "compartment_ocid" {}
variable "ssh_public_key" {}

# Naming convention: every resource is named <service>-<environment>[-kind]
# and tagged so the inventory check can tell managed resources from orphans.
variable "service" {
  description = "Service name, from TIN_SERVICE_NAME"
  type        = string
  default     = "gateway"
}

variable "environment" {
  description = "Deployment environment, from TIN_SERVICE_ENVIRONMENT"
  type        = string
  default     = "prod"
}

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

variable "ubuntu_version" {
  description = "Canonical Ubuntu release for new instances. Ignored for existing ones (see lifecycle)."
  type        = string
  default     = "22.04"
}

variable "user_data_template" {
  description = "Path to the cloud-init template rendered into user_data"
  type        = string
  default     = "/app/setup_secure_tunnel.sh.tpl"
}

locals {
  name = "${var.service}-${var.environment}"
  # DNS labels must be alphanumeric and are stable across environments so
  # that renaming an environment never forces network replacement.
  dns_stem = replace(var.service, "-", "")
  tags = {
    "service"     = var.service
    "environment" = var.environment
    "managed-by"  = "terraform"
  }
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
  operating_system_version = var.ubuntu_version
  shape                    = "VM.Standard.A1.Flex"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

# VCN
resource "oci_core_vcn" "gateway_vcn" {
  compartment_id = var.compartment_ocid
  display_name   = "${local.name}-vcn"
  cidr_block     = "10.0.0.0/16"
  dns_label      = "${local.dns_stem}vcn"
  freeform_tags  = local.tags
}

# Internet Gateway
resource "oci_core_internet_gateway" "gateway_igw" {
  compartment_id = var.compartment_ocid
  display_name   = "${local.name}-igw"
  vcn_id         = oci_core_vcn.gateway_vcn.id
  freeform_tags  = local.tags
}

# Route Table
resource "oci_core_default_route_table" "gateway_rt" {
  manage_default_resource_id = oci_core_vcn.gateway_vcn.default_route_table_id
  display_name               = "${local.name}-route-table"
  freeform_tags              = local.tags

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.gateway_igw.id
  }
}

# Security List (allow SSH and common ports)
resource "oci_core_default_security_list" "gateway_sl" {
  manage_default_resource_id = oci_core_vcn.gateway_vcn.default_security_list_id
  display_name               = "${local.name}-security-list"
  freeform_tags              = local.tags

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

  # Allow WireGuard. This rule was added by hand in the console; it is
  # declared here so an apply does not remove it.
  ingress_security_rules {
    description = "Wireguard"
    protocol    = "17"
    source      = "0.0.0.0/0"
    udp_options {
      min = 51820
      max = 51820
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
  display_name        = "${local.name}-subnet"
  cidr_block          = "10.0.0.0/24"
  dns_label           = "${local.dns_stem}subnet"
  availability_domain = data.oci_identity_availability_domain.ad.name
  freeform_tags       = local.tags
}

# Single Instance (Free Tier A1 Flex)
resource "oci_core_instance" "gateway_instance" {
  availability_domain = data.oci_identity_availability_domain.ad.name
  compartment_id      = var.compartment_ocid
  display_name        = local.name
  shape               = "VM.Standard.A1.Flex"
  freeform_tags       = local.tags

  shape_config {
    ocpus         = 1
    memory_in_gbs = 6
  }

  # 50 GB is the smallest boot volume OCI will create. The Always Free
  # allowance is 200 GB across all boot and block volumes in the home region,
  # so one 50 GB boot volume is a quarter of it.
  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu_images.images[0].id
    boot_volume_size_in_gbs = "50"
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.gateway_subnet.id
    display_name     = "primary-vnic"
    assign_public_ip = true
    hostname_label   = local.name
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data = base64encode(templatefile(var.user_data_template, {
      domain   = var.domain
      email    = var.email
      hostname = var.service # boxes are named by service alone, like the live gateway
    }))
  }

  lifecycle {
    # These only matter at first boot. Letting drift in them force a
    # replacement would destroy a working instance because Canonical
    # published a newer image or the cloud-init template was edited.
    ignore_changes = [
      source_details[0].source_id,
      metadata,
      create_vnic_details[0].hostname_label,
    ]
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

output "boot_volume_id" {
  value = oci_core_instance.gateway_instance.boot_volume_id
}

output "ssh_command" {
  value = "ssh ubuntu@${oci_core_instance.gateway_instance.public_ip}"
}
