# Proxy VCN and LPG

variable "proxy_vcn_cidr_block" {
  description = "IPv4 CIDR for the Proxy VCN"
  type        = string
  default     = "10.255.0.0/16"
}

variable "proxy_vcn_ipv6_cidr_block" {
  description = "IPv6 CIDR for the Proxy VCN"
  type        = string
  default     = "fd00:abcd:0::/48"
}

variable "backend_subnet_cidr_block" {
  description = "IPv4 CIDR for the backend subnet in Proxy VCN"
  type        = string
  default     = "10.255.1.0/24"
}

variable "backend_subnet_ipv6_cidr_block" {
  description = "IPv6 CIDR for the backend subnet in Proxy VCN"
  type        = string
  default     = "fd00:abcd:0:200::/64"
}

resource "oci_core_vcn" "proxy_vcn" {
  compartment_id                   = var.compartment_ocid
  display_name                     = "Proxy-VCN"
  cidr_block                       = var.proxy_vcn_cidr_block
  ipv6private_cidr_blocks          = [var.proxy_vcn_ipv6_cidr_block]
  is_ipv6enabled                   = true
  is_oracle_gua_allocation_enabled = false
  dns_label                        = "pvcn"
}


data "oci_identity_regions" "all_regions" {
}

locals {
  region_key = [for region in data.oci_identity_regions.all_regions.regions : region.key if region.name == var.oci_region][0]
}


# Backend Subnet
resource "oci_core_subnet" "backend_subnet" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.proxy_vcn.id
  cidr_block                 = var.backend_subnet_cidr_block
  ipv6cidr_block             = var.backend_subnet_ipv6_cidr_block
  display_name               = "proxy-backend-subnet"
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.backend_subnet_rt.id
  security_list_ids          = [oci_core_default_security_list.def_security_list_pv.id]
  dns_label                  = "backendsb"
}

# NAT Gateway for Proxy VCN
resource "oci_core_nat_gateway" "nat_gw" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.proxy_vcn.id
  display_name   = "proxy-nat-gateway"
  block_traffic  = false
}

# Backend subnet route table
resource "oci_core_route_table" "backend_subnet_rt" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.proxy_vcn.id
  display_name   = "proxy-backend-rt"

  route_rules { # IPv4 to NAT Gateway for outbound internet traffic
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.nat_gw.id
  }

  route_rules { # All IPv6 to DRG for return path, for vcnX ULA, for post NAT64 of ingress traffic from internet via NATGW
    destination       = var.vcnX_ipv6_cidr_block
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_drg.drg_only_for_vcnX_and_proxyvcn.id
  }

  route_rules { # internal IPv4 traffic to vcnX via DRG
    destination       = var.vcnX_cidr_block
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_drg.drg_only_for_vcnX_and_proxyvcn.id
  }
  
}

# Change as per your security requirements
resource "oci_core_default_security_list" "def_security_list_pv" {
  compartment_id             = var.compartment_ocid
  manage_default_resource_id = oci_core_vcn.proxy_vcn.default_security_list_id

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }
  egress_security_rules {
    destination = "::0/0"
    protocol    = "all"
  }

  ingress_security_rules {
    protocol = "all"
    source   = "0.0.0.0/0" 
  }
  ingress_security_rules {
    protocol = "all"
    source   = "::0/0" 
  }
}
