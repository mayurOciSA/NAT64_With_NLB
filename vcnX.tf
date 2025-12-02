
# vcnX is example client VCN, you will have your own, most probably created already
# vcnX will be single stack in your case (IPv6 only)

variable "vcnX_cidr_block" {
  description = "IPv4 CIDR for vcnX. Required by OCI but not used in single-stack IPv6 setup."
  type        = string
  default     = "10.1.0.0/16"
}

variable "vcnX_ipv6_cidr_block" {
  description = "IPv6 CIDR for vcnX"
  type        = string
  default     = "fd00:20:0::/48"
}

variable "vcnX_subnet_cidr_block" {
  description = "IPv4 CIDR for the vcnX subnet. Required by OCI but not used."
  type        = string
  default     = "10.1.1.0/24"
}

variable "vcnX_subnet_ipv6_cidr_block" {
  description = "IPv6 CIDR for the vcnX subnet"
  type        = string
  default     = "fd00:20:0:1::/64"
}

resource "oci_core_vcn" "vcnX" {
  compartment_id                   = var.compartment_ocid
  display_name                     = "vcnX"
  cidr_block                       = var.vcnX_cidr_block       # required, but will not be used
  ipv6private_cidr_blocks          = [var.vcnX_ipv6_cidr_block]
  is_ipv6enabled                   = true
  is_oracle_gua_allocation_enabled = false
  dns_label                        = "vcnX"
}

resource "oci_core_subnet" "vcnX_private_ipv6" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.vcnX.id
  cidr_block                 = var.vcnX_subnet_cidr_block # required, but will not be used
  ipv6cidr_block             = var.vcnX_subnet_ipv6_cidr_block
  display_name               = "vcnX-sub-ulaipv6"
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.vcnX_ipv6_rt.id
  security_list_ids          = [oci_core_default_security_list.def_security_list_vcnX.id]
  dns_label                  = "v2ulasub"
}

# vcnX IPv6-only subnet RT: ::/0 via DRG
resource "oci_core_route_table" "vcnX_ipv6_rt" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.vcnX.id
  display_name   = "vcnX-ipv6-rt"

  route_rules {
    destination       = "::/0" # recommended to be 64:ff9b::/96 for NAT64, but ::/0 works too
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_drg.drg_only_for_vcnX_and_proxyvcn.id
  }
  route_rules {
    destination       = oci_core_vcn.proxy_vcn.cidr_block # for proxyvcn IPv4 CIDR through DRG
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_drg.drg_only_for_vcnX_and_proxyvcn.id
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
    source   = "0.0.0.0/0" 
  }
  ingress_security_rules {
    protocol = "all"
    source   = "::0/0" 
  }
}

# OUTPUTS
output "vcnX_OCID" {
  value = oci_core_vcn.vcnX.id
}
