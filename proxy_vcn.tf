# Proxy VCN and LPG

resource "oci_core_vcn" "proxy_vcn" {
  compartment_id          = var.compartment_ocid
  display_name            = "Proxy-VCN"
  cidr_block              = "10.1.0.0/16"
  ipv6private_cidr_blocks = ["fd00:20:0::/48"]
  is_ipv6enabled = true
  is_oracle_gua_allocation_enabled = false
  dns_label = "pvcn"
}

resource "oci_core_local_peering_gateway" "proxy_lpg" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.proxy_vcn.id
  display_name   = "Proxy-LPG"
  peer_id        = oci_core_local_peering_gateway.vcn1_lpg.id
  route_table_id = oci_core_route_table.proxy_lpg_ingress_rt.id
}

# LPG ingress route table ("all IPv6 traffic to NLB private IP")
resource "oci_core_route_table" "proxy_lpg_ingress_rt" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.proxy_vcn.id
  display_name   = "proxy-vcn-lpg-ingress-rt"
  route_rules {
      destination      = "::/0"
      destination_type = "CIDR_BLOCK"
      network_entity_id = data.oci_core_ipv6s.nlb_private_ipv6.ipv6s[0].id
  }
  depends_on = [ oci_network_load_balancer_network_load_balancer.nlb ]
}

# 1. NLB Subnet
resource "oci_core_subnet" "nlb_subnet" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.proxy_vcn.id
  cidr_block                 = "10.1.1.0/24"
  ipv6cidr_block             = "fd00:20:0:100::/64"
  display_name               = "proxy-nlb-subnet"
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.nlb_subnet_rt.id
  security_list_ids = [oci_core_default_security_list.def_security_list_pv.id]
  dns_label = "nlbsb"
}
# 2. Backend Subnet
resource "oci_core_subnet" "backend_subnet" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.proxy_vcn.id
  cidr_block                 = "10.1.2.0/24"
  ipv6cidr_block             = "fd00:20:0:200::/64"
  display_name               = "proxy-backend-subnet"
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.backend_subnet_rt.id
  security_list_ids = [oci_core_default_security_list.def_security_list_pv.id]
  dns_label = "backendsb"
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

# 2. Backend subnet route table
resource "oci_core_route_table" "backend_subnet_rt" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.proxy_vcn.id
  display_name   = "proxy-backend-rt"

  route_rules { # IPv4 to NAT Gateway for outbound internet traffic
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.nat_gw.id
  }
  route_rules { # All IPv6 to LPG for return path, for post NAT64 of ingress traffic from internet via NATGW
    destination       = "::/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_local_peering_gateway.proxy_lpg.id
  }

  route_rules { # # To route backend's response to Health check query coming from NLB
    destination       = "fd00:20:0:100::100/128" # NLB IPv6 private IP
    destination_type  = "CIDR_BLOCK"
    network_entity_id = data.oci_core_ipv6s.nlb_private_ipv6.ipv6s[0].id
  }
    route_rules { # # To route backend's response to Health check query coming from NLB, not used in this setup 
    destination       = "10.1.1.25/32" # NLB IPv4 private IP
    destination_type  = "CIDR_BLOCK"
    network_entity_id = data.oci_core_private_ips.nlb_private_ipv4.private_ips[0].id
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
    source   = "10.0.0.0/16" # VCN1 IPv4 CIDR
  }
  ingress_security_rules {
    protocol = "all"
    source   = "fd00:10:0::/48" # VCN1 IPv6 CIDR
  }
    ingress_security_rules {
    protocol = "all"
    source   = "10.1.0.0/16" # Proxy VCN IPv4 CIDR
  }
  ingress_security_rules {
    protocol = "all"
    source   = "fd00:20:0::/48" # Proxy VCN IPv6 CIDR
  }
}


output "Proxy_LPG_OCID" {
  value = oci_core_local_peering_gateway.proxy_lpg.id
}
output "Proxy_VCN_OCID" {
  value = oci_core_vcn.proxy_vcn.id
}