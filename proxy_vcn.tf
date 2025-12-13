# Proxy VCN and LPG

variable "proxy_vcn_ipv4_cidr" {
  description = "The IPv4 CIDR block for the Proxy VCN."
}

variable "proxy_vcn_ipv6_cidr" {
  description = "The IPv6 CIDR block for the Proxy VCN."
}

variable "nlb_subnet_ipv4_cidr" {
  description = "The IPv4 CIDR block for the NLB subnet."
}

variable "nlb_subnet_ipv6_cidr" {
  description = "The IPv6 CIDR block for the NLB subnet."
}

variable "backend_nat64_subnet_ipv4_cidr" {
  description = "The IPv4 CIDR block for the backend_nat64 subnet."
}

variable "backend_nat64_subnet_ipv6_cidr" {
  description = "The IPv6 CIDR block for the backend_nat64 subnet."
}

resource "oci_core_vcn" "proxy_vcn" {
  compartment_id                   = var.compartment_ocid
  display_name                     = "Proxy-VCN"
  cidr_block                       = var.proxy_vcn_ipv4_cidr
  ipv6private_cidr_blocks          = [var.proxy_vcn_ipv6_cidr]
  is_ipv6enabled                   = true
  is_oracle_gua_allocation_enabled = true # OCI assigned GUA block (always a /56)
  dns_label                        = "pvcn"
}

# NLB Subnet
resource "oci_core_subnet" "nlb_subnet" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.proxy_vcn.id
  cidr_block                 = var.nlb_subnet_ipv4_cidr
  ipv6cidr_block             = var.nlb_subnet_ipv6_cidr
  display_name               = "proxy-nlb-subnet"
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.nlb_subnet_rt.id
  security_list_ids          = [oci_core_default_security_list.def_security_list_pv.id]
  dns_label                  = "nlbsb"
}
# backend_nat64 Subnet
resource "oci_core_subnet" "backend_nat64_subnet" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.proxy_vcn.id
  cidr_block                 = var.backend_nat64_subnet_ipv4_cidr
  ipv6cidr_block             = var.backend_nat64_subnet_ipv6_cidr
  display_name               = "proxy-backend_nat64-subnet"
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.backend_nat64_subnet_rt.id
  security_list_ids          = [oci_core_default_security_list.def_security_list_pv.id]
  dns_label                  = "benatsixfoursb"
}

# NAT Gateway for Proxy VCN
resource "oci_core_nat_gateway" "nat_gw" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.proxy_vcn.id
  display_name   = "proxy-nat-gateway"
  block_traffic  = false
}

# Route Tables (Proxy VCN)
# 1. NLB Subnet route table (empty)
resource "oci_core_route_table" "nlb_subnet_rt" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.proxy_vcn.id
  display_name   = "proxy-nlb-rt"
}

# 2. backend_nat64 subnet route table
resource "oci_core_route_table" "backend_nat64_subnet_rt" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.proxy_vcn.id
  display_name   = "proxy-backend_nat64-rt"

  route_rules { # IPv4 to OCI NATGW for outbound internet traffic
    destination       = "0.0.0.0/0"
    network_entity_id = oci_core_nat_gateway.nat_gw.id
  }
  route_rules {                    # All IPv6 to DRG for return path, ingress traffic from Internet => NATGW => backend_nat64 ...Then fwd to DRG
    destination       = "fc00::/7" # destination will be ULA post reversal of NAT64 on return path
    network_entity_id = oci_core_drg.drg_vcnX_and_proxyvcn.id
  }
}

# change as per your security requirements
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
    source   = var.vcnX_ipv4_cidr
  }
  ingress_security_rules {
    protocol = "all"
    source   = var.vcnX_ipv6_cidr
  }
  #Self
  ingress_security_rules {
    protocol = "all"
    source   = var.proxy_vcn_ipv4_cidr
  }
  ingress_security_rules {
    protocol = "all"
    source   = var.proxy_vcn_ipv6_cidr
  }
}

## BACKEND_NAT66 SUBNET

variable "backend_nat66_subnet_ipv4_cidr" {
  description = "The IPv4 CIDR block for the backend_nat64 subnet."
}

data "oci_core_vcn" "proxy_vcn_data" {
  vcn_id = oci_core_vcn.proxy_vcn.id
}

locals {
  proxy_vcn_gua_prefix = [for block in oci_core_vcn.proxy_vcn.ipv6cidr_blocks : block if strcontains(block, "/56")][0]
}

# backend_nat66 Subnet
resource "oci_core_subnet" "backend_nat66_subnet" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.proxy_vcn.id
  cidr_block                 = var.backend_nat66_subnet_ipv4_cidr
  ipv6cidr_block             = cidrsubnet("${local.proxy_vcn_gua_prefix}", 8, 1) # add 8 to 56 to get /64, then subnet /64 (e.g., 2001:...:0100::/64)
  display_name               = "proxy-backend_nat66-subnet"
  prohibit_public_ip_on_vnic = false # no public IPv4 addresses on VNICs
  route_table_id             = oci_core_route_table.backend_nat66_subnet_rt.id
  security_list_ids          = [oci_core_default_security_list.def_security_list_pv.id]
  dns_label                  = "benatsixsixsb"
}

# 3. backend_nat66 subnet route table
resource "oci_core_route_table" "backend_nat66_subnet_rt" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.proxy_vcn.id
  display_name   = "proxy-backend_nat66-rt"

  # IPv4 to Internet Gateway for outbound internet traffic, for package downloads only
  route_rules {
    destination       = "0.0.0.0/0"
    network_entity_id = oci_core_nat_gateway.nat_gw.id
  }

  # GUA IPv6 to Internet Gateway for outbound internet traffic, for traffic already NAT66-ed by backend_nat66 nodes
  route_rules {
    destination       = "2000::/3"
    network_entity_id = oci_core_internet_gateway.proxy_igw.id
  }

  # All IPv6 ULA to DRG for traffic, for post NAT66 of {ingress/response/inbound traffic from internet/IGW}
  route_rules {
    destination       = "fc00::/7"
    network_entity_id = oci_core_drg.drg_vcnX_and_proxyvcn.id
  }
}

resource "oci_core_internet_gateway" "proxy_igw" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.proxy_vcn.id
  display_name   = "proxy-internet-gateway"
  enabled        = true
}

# Bastion Subnet
variable "bastion_subnet_ipv4_cidr" {
  description = "The IPv4 CIDR block for the bastion_subnet."
}

resource "oci_core_subnet" "bastion_subnet" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.proxy_vcn.id
  cidr_block                 = var.bastion_subnet_ipv4_cidr
  display_name               = "proxy-babastion-subnet"
  prohibit_public_ip_on_vnic = true # no public IPv4 addresses on VNICs
  route_table_id             = oci_core_route_table.bastion_subnet_rt.id
  security_list_ids          = [oci_core_default_security_list.def_security_list_pv.id]
  dns_label                  = "bastionsb"
}

# 3. bastion_subnet route table
resource "oci_core_route_table" "bastion_subnet_rt" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.proxy_vcn.id
  display_name   = "proxy-bastion_subnet_rt"

  route_rules { # for SOCK5 Proxy to reach ULA Clients in VCN X
    destination       = oci_core_subnet.vcnX_private_ipv6.cidr_block
    network_entity_id = oci_core_drg.drg_vcnX_and_proxyvcn.id
  }
}
