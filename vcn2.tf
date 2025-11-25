
# vcn2 is example client VCN, you will have your own, most probably created already
# vcn2 will be single stack in your case (IPv6 only)

resource "oci_core_vcn" "vcn2" {
  compartment_id                   = var.compartment_ocid
  display_name                     = "vcn2"
  cidr_block                       = "10.1.0.0/16" # required, but will not be used
  ipv6private_cidr_blocks          = ["fd00:20:0::/48"]
  is_ipv6enabled                   = true
  is_oracle_gua_allocation_enabled = false
  dns_label                        = "vcn2"
}

resource "oci_core_subnet" "vcn2_private_ipv6" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.vcn2.id
  cidr_block                 = "10.1.1.0/24" # required, but will not be used
  ipv6cidr_block             = "fd00:20:0:1::/64"
  display_name               = "vcn2-sub-ulaipv6"
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.vcn2_ipv6_rt.id
  security_list_ids          = [oci_core_default_security_list.def_security_list_vcn2.id]
  dns_label                  = "v2ulasub"
}

# vcn2 IPv6-only subnet RT: ::/0 via DRG
resource "oci_core_route_table" "vcn2_ipv6_rt" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.vcn2.id
  display_name   = "vcn2-ipv6-rt"

  route_rules {
    destination       = "::/0" # recommended to be 64:ff9b::/96 for NAT64, but ::/0 works too
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_drg.drg_only_for_vcn2_and_proxyvcn.id
  }

  # IPv4 route to VCN1 and Proxy VCN for sock5 proxy access
#   route_rules {
#     destination       = oci_core_vcn.vcn1.cidr_block # for VCN1 IPv4 CIDR through LPG
#     destination_type  = "CIDR_BLOCK"
#     network_entity_id = oci_core_local_peering_gateway.vcn2_to_vcn1_lpg.id
#   }

  route_rules {
    destination       = oci_core_vcn.proxy_vcn.cidr_block # for proxyvcn IPv4 CIDR through DRG
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_drg.drg_only_for_vcn2_and_proxyvcn.id
  }
}

# change as per your security requirements
resource "oci_core_default_security_list" "def_security_list_vcn2" {
  compartment_id             = var.compartment_ocid
  manage_default_resource_id = oci_core_vcn.vcn2.default_security_list_id

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
output "vcn2_OCID" {
  value = oci_core_vcn.vcn2.id
}

# resource "oci_core_local_peering_gateway" "vcn2_to_vcn1_lpg" {
#   compartment_id = var.compartment_ocid
#   vcn_id         = oci_core_vcn.vcn2.id
#   display_name   = "vcn2_to_vcn1_lpg"
#   peer_id = oci_core_local_peering_gateway.vcn1_to_vcn2_lpg.id
# }