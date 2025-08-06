terraform {
  required_version = ">= 1.0"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 7.11"
    }
  }
}

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

variable "compartment_ocid" {
  description = "Compartment OCID where resources will be created"
  type        = string
  default     = ""
}

variable "ssh_public_key" {
  description = "SSH public key for instance access"
  type        = string
  default     = ""
}

variable "instance_shape" {
  default = "VM.Standard.A1.Flex"
}

variable "instance_ocpus" {
  default = 1
}

variable "instance_shape_config_memory_in_gbs" {
  default = 6
}

# Image OCIDs per region - using Oracle Linux for compatibility
variable "flex_instance_image_ocid" {
  type = map(string)
  default = {
    us-phoenix-1   = "ocid1.image.oc1.phx.aaaaaaaa6hooptnlbfwr5lwemqjbu3uqidntrlhnt45yihfj222zahe7p3wq"
    us-ashburn-1   = "ocid1.image.oc1.iad.aaaaaaaa6tp7lhyrcokdtf7vrbmxyp2pctgg4uxvt4jz4vc47qoc2ec4anha"
    eu-frankfurt-1 = "ocid1.image.oc1.eu-frankfurt-1.aaaaaaaadvi77prh3vjijhwe5xbd6kjg3n5ndxjcpod6om6qaiqeu3csof7a"
    uk-london-1    = "ocid1.image.oc1.uk-london-1.aaaaaaaaw5gvriwzjhzt2tnylrfnpanz5ndztyrv3zpwhlzxdbkqsjfkwxaq"
  }
}

provider "oci" {
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = var.private_key_path
  region           = var.region
}

# Get availability domain - this is critical
data "oci_identity_availability_domain" "ad" {
  compartment_id = var.tenancy_ocid
  ad_number      = 1
}

# VCN
resource "oci_core_vcn" "test_vcn" {
  cidr_block     = "10.1.0.0/16"
  compartment_id = var.compartment_ocid
  display_name   = "GatewayTestVcn"
  dns_label      = "gatewaytestvcn"
}

# Internet Gateway
resource "oci_core_internet_gateway" "test_internet_gateway" {
  compartment_id = var.compartment_ocid
  display_name   = "GatewayTestInternetGateway"
  vcn_id         = oci_core_vcn.test_vcn.id
}

# Use default route table instead of creating new one
resource "oci_core_default_route_table" "default_route_table" {
  manage_default_resource_id = oci_core_vcn.test_vcn.default_route_table_id
  display_name               = "DefaultRouteTable"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.test_internet_gateway.id
  }
}

# Subnet - using availability domain from data source
resource "oci_core_subnet" "test_subnet" {
  availability_domain = data.oci_identity_availability_domain.ad.name
  cidr_block          = "10.1.20.0/24"
  display_name        = "GatewayTestSubnet"
  dns_label           = "gatewaytestsubnet"
  security_list_ids   = [oci_core_vcn.test_vcn.default_security_list_id]
  compartment_id      = var.compartment_ocid
  vcn_id              = oci_core_vcn.test_vcn.id
  route_table_id      = oci_core_vcn.test_vcn.default_route_table_id
  dhcp_options_id     = oci_core_vcn.test_vcn.default_dhcp_options_id
}

# Compute Instance - following Oracle's exact pattern
resource "oci_core_instance" "test_instance" {
  availability_domain = data.oci_identity_availability_domain.ad.name
  compartment_id      = var.compartment_ocid
  display_name        = "GatewayTestInstance"
  shape               = var.instance_shape

  shape_config {
    ocpus         = var.instance_ocpus
    memory_in_gbs = var.instance_shape_config_memory_in_gbs
  }

  create_vnic_details {
    subnet_id                 = oci_core_subnet.test_subnet.id
    display_name              = "Primaryvnic"
    assign_public_ip          = true
    assign_private_dns_record = true
    hostname_label            = "gatewaytest"
  }

  source_details {
    source_type             = "image"
    source_id               = var.flex_instance_image_ocid[var.region]
    boot_volume_size_in_gbs = "60"  # Explicitly set boot volume size
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data = base64encode(<<-EOF
      #!/bin/bash
      yum update -y
      yum install -y git curl wget
    EOF
    )
  }

  timeouts {
    create = "60m"
  }
}

# Outputs
output "instance_public_ip" {
  value = oci_core_instance.test_instance.public_ip
}

output "instance_id" {
  value = oci_core_instance.test_instance.id
}

output "ssh_command" {
  value = "ssh opc@${oci_core_instance.test_instance.public_ip}"
}