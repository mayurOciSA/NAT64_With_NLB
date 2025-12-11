
# vcnX CIDRs
variable "vcnX_ipv4_cidr" {
  description = "The IPv4 CIDR block for vcnX."
  default     = "10.0.0.0/16"
}

variable "vcnX_ipv6_cidr" {
  description = "The IPv6 CIDR block for vcnX."
  default     = "fd00:10:0::/48"
}

variable "vcnX_private_subnet_ipv4_cidr" {
  description = "The IPv4 CIDR block for the vcnX private subnet."
  default     = "10.0.1.0/24"
}

variable "vcnX_private_subnet_ipv6_cidr" {
  description = "The IPv6 CIDR block for the vcnX private subnet."
  default     = "fd00:10:0:1::/64"
}

# vcnX is example client VCN, you will have your own, most probably created already
# vcnX will be single stack in your case (IPv6 only)
resource "oci_core_vcn" "vcnX" {
  compartment_id                   = var.compartment_ocid
  display_name                     = "vcnX"
  cidr_block                       = var.vcnX_ipv4_cidr # required, but will not be used
  ipv6private_cidr_blocks          = [var.vcnX_ipv6_cidr]
  is_ipv6enabled                   = true
  is_oracle_gua_allocation_enabled = false
  dns_label                        = "vcnX"
}

resource "oci_core_subnet" "vcnX_private_ipv6" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.vcnX.id
  cidr_block                 = var.vcnX_private_subnet_ipv4_cidr # required, but will not be used
  ipv6cidr_block             = var.vcnX_private_subnet_ipv6_cidr
  display_name               = "vcnX-private-subnet-ipv6"
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.vcnX_ipv6_rt.id
  security_list_ids          = [oci_core_default_security_list.def_security_list_vcnX.id]
  dns_label                  = "ulasub"
}

# vcnX IPv6-only subnet RT: ::/0 via DRG
resource "oci_core_route_table" "vcnX_ipv6_rt" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.vcnX.id
  display_name   = "vcnX-ipv6-rt"

  route_rules {
    destination       = "64:ff9b::/96" # for NAT64
    network_entity_id = oci_core_drg.drg_vcnX_and_proxyvcn.id
  }

  route_rules {
    destination       = "2000::/3" # GUA for all traffic to IPv6 internet, will pass through NAT66
    network_entity_id = oci_core_drg.drg_vcnX_and_proxyvcn.id
  }

  # route_rules for pvt IPv4 added for bastions access
  route_rules {
    destination       = var.proxy_vcn_ipv4_cidr
    network_entity_id = oci_core_drg.drg_vcnX_and_proxyvcn.id
  }
}

# change as per your security requirements
resource "oci_core_default_security_list" "def_security_list_vcnX" {
  compartment_id             = var.compartment_ocid
  manage_default_resource_id = oci_core_vcn.vcnX.default_security_list_id

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
    source   = var.proxy_vcn_ipv4_cidr
  }
  ingress_security_rules {
    protocol = "all"
    source   = var.proxy_vcn_ipv6_cidr
  }

  #Self
  ingress_security_rules {
    protocol = "all"
    source   = var.vcnX_ipv4_cidr
  }
  ingress_security_rules {
    protocol = "all"
    source   = var.vcnX_ipv6_cidr
  }
}
