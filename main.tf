terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 7.26.1"
    }
  }
}

provider "oci" {
  region           = var.oci_region
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = var.private_key_path
}


# -------------------
# Variables and Data Sources
# -------------------
variable "tenancy_ocid" {
  description = "Your Tenancy OCID"
  type        = string
}

variable "compartment_ocid" {
  description = "OCI compartment where resources are to be created & maintained"
  type        = string
}

variable "user_ocid" {
  default = ""
}
variable "fingerprint" {
  default = ""
}
variable "private_key_path" {
  default = ""
}
variable "oci_region" {
  description = "OCI region where resources are to be created & maintained"
  type        = string
}

variable "instance_shape" {
  default     = "VM.Standard.A1.Flex"
  description = "Shape for backend instances"
  type        = string
}

variable "instance_ocpus" {
  default     = 3
  description = "OCPU count for backend instances"
  type        = number
}

variable "instance_memory_in_gbs" {
  default     = 8
  description = "RAM size for backend instances"
  type        = number
}

variable "instance_boot_volume_size_in_gbs" {
  default     = 60
  description = "boot_volume_size size for backend instances"
  type        = number
}

variable "ssh_public_key" {
  description = "Contents of SSH public key file. Used to enable login to instance"
  type        = string
}

variable "ssh_private_key_local_path" {
  description = "Local Path of SSH private key file. Used to login to instance, not needed if no ansible or other config management planned"
  type        = string
}

variable "backend_nat64_count" {
  type    = number
  default = 1
}

variable "backend_nat66_count" {
  type    = number
  default = 1
}

data "oci_core_images" "oracle_linux_images_oci" {
  compartment_id           = var.tenancy_ocid
  operating_system         = "Oracle Linux"
  operating_system_version = "9"
  shape                    = var.instance_shape #"VM.Standard.A1.Flex"
  sort_by                  = "TIMECREATED"
  sort_order               = "ASC"
}

# Grab AD data for OCI VCN
data "oci_identity_availability_domains" "ad_list" {
  compartment_id = var.tenancy_ocid
}
