# Proxy VCN and LPG

resource "oci_core_vcn" "proxy_vcn" {
  compartment_id                   = var.compartment_ocid
  display_name                     = "Proxy-VCN"
  cidr_block                       = "10.255.0.0/16"
  ipv6private_cidr_blocks          = ["fd00:abcd:0::/48"]
  is_ipv6enabled                   = true
  is_oracle_gua_allocation_enabled = false
  dns_label                        = "pvcn"
}

# resource "oci_core_local_peering_gateway" "proxyvcn_to_vcn1_lpg" {
#   compartment_id = var.compartment_ocid
#   vcn_id         = oci_core_vcn.proxy_vcn.id
#   display_name   = "proxyvcn_to_vcn1_lpg"
#   peer_id        = oci_core_local_peering_gateway.vcn1_to_proxyvcn_lpg.id
#   route_table_id = oci_core_route_table.proxy_lpg_ingress_rt.id
# }

# LPG ingress route table ("all IPv6 traffic to NLB private IP")
# resource "oci_core_route_table" "proxy_lpg_ingress_rt" {
#   compartment_id = var.compartment_ocid
#   vcn_id         = oci_core_vcn.proxy_vcn.id
#   display_name   = "proxy-vcn-lpg-ingress-rt"
#   lifecycle {
#     ignore_changes = [ route_rules ]
#   }
# }

data "oci_identity_regions" "all_regions" {
}

locals {
  region_key = [for region in data.oci_identity_regions.all_regions.regions : region.key if region.name == var.oci_region][0]
}


# ECMP not supported on LPGs, skipping enabling ECMP on LPG ingress route table
# resource "null_resource" "ingress_rt_of_proxyvcn_to_vcn1_lpg" {
#   depends_on = [oci_core_local_peering_gateway.proxyvcn_to_vcn1_lpg, 
#                 local.backends_ipv6_ocids, 
#                 oci_core_route_table.proxy_lpg_ingress_rt, 
#                 data.oci_core_private_ips.backend_private_ipv4_objects, 
#                 oci_core_instance.ula_test_vcn1_client, oci_core_instance.ula_test_vcn2_client, 
#                 oci_core_drg_attachment.proxy_vcn_drg_attachment, oci_core_drg_attachment.vcn2_drg_attachment ]

#   provisioner "local-exec" {
    
#     command = <<-EOT
      
#       exit 0
#       set -e
#       region_key=${local.region_key}
#       export OCI_CLI_REGION=${var.oci_region}
      
#       echo "Enable ECMP on the LPG(proxy_lpg_ingress_rt)'s Ingress Route Table"
#       oci raw-request --http-method PUT -\
#       -target-uri https://iaas.$OCI_CLI_REGION.oraclecloud.com/20160918/routeTables/${oci_core_route_table.proxy_lpg_ingress_rt.id} \
#       --request-body '{"isEcmpEnabled":"true"}' 

#       # Update the route table with the new rules
#       # oci network route-table update --rt-id ${oci_core_route_table.proxy_lpg_ingress_rt.id} --route-rules '${local.ingress_route_rules_json}' --force
     
#     EOT
#   }
# }


# Backend Subnet
resource "oci_core_subnet" "backend_subnet" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.proxy_vcn.id
  cidr_block                 = "10.255.0.0/24"
  ipv6cidr_block             = "fd00:abcd:0:200::/64"
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
    route_type = "STATIC"
  }

  # route_rules { # All IPv6 to LPG for return path, for vcn1 ULA, for post NAT64 of ingress traffic from internet via NATGW
  #   destination       = "fd00:10:0::/48" #oci_core_vcn.vcn1.ipv6private_cidr_blocks[0]
  #   destination_type  = "CIDR_BLOCK"
  #   network_entity_id = oci_core_local_peering_gateway.proxyvcn_to_vcn1_lpg.id
  #   route_type = "STATIC"
  # }

  route_rules { # All IPv6 to DRG for return path, for vcn2 ULA, for post NAT64 of ingress traffic from internet via NATGW
    destination       = "fd00:20:0::/48" #oci_core_vcn.vcn2.ipv6private_cidr_blocks[0]
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_drg.drg_only_for_vcn2_and_proxyvcn.id
    route_type = "STATIC"
  }

  #### IPv4 routes for internal communication for SOCK5 ####

  # route_rules { # internal IPv4 traffic to VCN1 via LPG
  #   destination       =  "10.0.1.0/24" # oci_core_subnet.vcn1_private_ipv6.cidr_block
  #   destination_type  = "CIDR_BLOCK"
  #   network_entity_id = oci_core_local_peering_gateway.proxyvcn_to_vcn1_lpg.id
  # }

  route_rules { # internal IPv4 traffic to VCN2 via DRG
    destination       = "10.1.1.0/24" #oci_core_vcn.vcn2.cidr_block
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_drg.drg_only_for_vcn2_and_proxyvcn.id
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


