
# VCN1 is example client VCN, you will have your own, most probably created already
# VCN1 will be single stack in your case (IPv6 only)
resource "oci_core_vcn" "vcn1" {
  compartment_id                   = var.compartment_ocid
  display_name                     = "VCN1"
  cidr_block                       = "10.0.0.0/16" # required, but will not be used
  ipv6private_cidr_blocks          = ["fd00:10:0::/48"]
  is_ipv6enabled                   = true
  is_oracle_gua_allocation_enabled = false
}

resource "oci_core_local_peering_gateway" "vcn1_lpg" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.vcn1.id
  display_name   = "VCN1-LPG"
}

resource "oci_core_subnet" "vcn1_private_ipv6" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.vcn1.id
  cidr_block                 = "10.0.1.0/24" # required, but will not be used
  ipv6cidr_block             = "fd00:10:0:1::/64"
  display_name               = "vcn1-private-subnet-ipv6"
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.vcn1_ipv6_rt.id
  security_list_ids          = [oci_core_default_security_list.def_security_list_vcn1.id]
}

# VCN1 IPv6-only subnet RT: ::/0 via LPG
resource "oci_core_route_table" "vcn1_ipv6_rt" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.vcn1.id
  display_name   = "vcn1-ipv6-rt"

  route_rules {
    destination       = "::/0" # recommended to be 64:ff9b::/96 for NAT64, but ::/0 works too
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_local_peering_gateway.vcn1_lpg.id
  }
}

# change as per your security requirements
resource "oci_core_default_security_list" "def_security_list_vcn1" {
  compartment_id             = var.compartment_ocid
  manage_default_resource_id = oci_core_vcn.vcn1.default_security_list_id

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
    source   = "10.1.0.0/16" # Proxy VCN IPv4 CIDR
  }
  ingress_security_rules {
    protocol = "all"
    source   = "fd00:20:0::/48" # Proxy VCN IPv6 CIDR
  }
  ingress_security_rules {
    protocol = "all"
    source   = "10.0.0.0/16" # VCN1 IPv4 CIDR
  }
  ingress_security_rules {
    protocol = "all"
    source   = "fd00:10:0::/48" # VCN1 IPv6 CIDR
  }
}

# OUTPUTS
output "VCN1_LPG_OCID" {
  value = oci_core_local_peering_gateway.vcn1_lpg.id
}

output "VCN1_OCID" {
  value = oci_core_vcn.vcn1.id
}
