# DRG for communication between VCN2 and Proxy VCN
resource "oci_core_drg" "drg_vcnX_and_proxyvcn" {
  compartment_id = var.compartment_ocid
  display_name   = "drg_for_vcnX_and_proxyvcn"
}

# DRG Attachment for VCN2
resource "oci_core_drg_attachment" "vcnX_drg_attachment" {
  drg_id       = oci_core_drg.drg_vcnX_and_proxyvcn.id
  vcn_id       = oci_core_vcn.vcnX.id
  display_name = "vcnX-drg-attachment"
}

# DRG Attachment for Proxy VCN
resource "oci_core_drg_attachment" "proxy_vcn_drg_attachment" {
  drg_id       = oci_core_drg.drg_vcnX_and_proxyvcn.id
  display_name = "proxy-vcn-drg-attachment"
  network_details {
    id   = oci_core_vcn.proxy_vcn.id
    type = "VCN"
    # This VCN route table handles traffic coming *from* the DRG *into* the proxy_vcn.
    route_table_id = oci_core_route_table.proxy_vcn_drg_ingress_rt.id
  }
}

# Route table in Proxy VCN to direct traffic from DRG to backends via ECMP
resource "oci_core_route_table" "proxy_vcn_drg_ingress_rt" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.proxy_vcn.id
  display_name   = "proxy-vcn-drg-ingress-rt"

  route_rules {
    destination       = "64:ff9b::/96" # for NAT64, will pass through NLB for NAT64
    network_entity_id = data.oci_core_ipv6s.nlb_nat64_private_ipv6.ipv6s[0].id
  }
  route_rules {
    destination       = "2000::/3" # or Just put GUA to cover all traffic to IPv6 internet, will pass through NLB for NAT66
    network_entity_id = data.oci_core_ipv6s.nlb_nat66_private_ipv6.ipv6s[0].id
  }
}
