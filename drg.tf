# DRG for communication between VCN2 and Proxy VCN
resource "oci_core_drg" "drg_only_for_vcn2_and_proxyvcn" {
  compartment_id = var.compartment_ocid
  display_name   = "drg_only_for_vcn2_and_proxyvcn"
}

# DRG Attachment for VCN2
resource "oci_core_drg_attachment" "vcn2_drg_attachment" {
  drg_id         = oci_core_drg.drg_only_for_vcn2_and_proxyvcn.id
  vcn_id         = oci_core_vcn.vcn2.id
  display_name   = "vcn2-drg-attachment"
}

# DRG Attachment for Proxy VCN
resource "oci_core_drg_attachment" "proxy_vcn_drg_attachment" {
  drg_id       = oci_core_drg.drg_only_for_vcn2_and_proxyvcn.id
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

  lifecycle {
    ignore_changes = [ route_rules  ]
  }
  # Rules added via null_resource ingress_for_vcn2_rt_for_drg below for ECMP
}

locals {
  # First 2 route rules for ECMP to backends for IPv6 traffic to NAT64-ed
  # Next 2 route rules for IPv4 traffic to backends for normal internal traffic
  # Same for both DRG and LPG ingress route tables
  ingress_route_rules_list = [
    {
      destination     = "::0/0"
      destinationType = "CIDR_BLOCK"
      networkEntityId = local.backends_ipv6_ocids[0]
    },
    {
      destination     = "::0/0"
      destinationType = "CIDR_BLOCK"
      networkEntityId = local.backends_ipv6_ocids[1]
    },
    # {
    #   destination     = "${data.oci_core_private_ips.backend_private_ipv4_objects.private_ips[0].ip_address}/32"
    #   destinationType = "CIDR_BLOCK"
    #   networkEntityId = data.oci_core_private_ips.backend_private_ipv4_objects.private_ips[0].id
    # },
    # {
    #   destination     = "${data.oci_core_private_ips.backend_private_ipv4_objects.private_ips[1].ip_address}/32"
    #   destinationType = "CIDR_BLOCK"
    #   networkEntityId = data.oci_core_private_ips.backend_private_ipv4_objects.private_ips[1].id
    # }
  ]
  # Encode the list into a single-line JSON string for the OCI CLI
  ingress_route_rules_json = jsonencode(local.ingress_route_rules_list)
}


resource "null_resource" "ingress_for_vcn2_rt_for_drg" {
  depends_on = [local.backends_ipv6_ocids, 
                oci_core_route_table.proxy_vcn_drg_ingress_rt, 
                data.oci_core_private_ips.backend_private_ipv4_objects,
                # oci_core_local_peering_gateway.proxyvcn_to_vcn1_lpg, 
                # oci_core_route_table.proxy_lpg_ingress_rt, 
                # oci_core_instance.ula_test_vcn1_client, 
                oci_core_instance.ula_test_vcn2_client, 
                oci_core_drg_attachment.proxy_vcn_drg_attachment, oci_core_drg_attachment.vcn2_drg_attachment ]

  provisioner "local-exec" {
    
    command = <<-EOT
      set -e
      region_key=${local.region_key}
      export OCI_CLI_REGION=${var.oci_region}
      
      echo "Enable ECMP on the DRG(proxy_vcn_drg_ingress_rt)'s Ingress Route Table"

      oci raw-request --http-method PUT -\
      -target-uri https://iaas.$OCI_CLI_REGION.oraclecloud.com/20160918/routeTables/${oci_core_route_table.proxy_vcn_drg_ingress_rt.id} \
      --request-body '{"isEcmpEnabled":"true"}' 

      echo "First 2 route rules for ECMP to backends for IPv6 traffic to NAT64-ed"
      echo "Next 2 route rules for IPv4 traffic to backends for normal internal traffic"

      # Update the route table with the new rules

      oci network route-table update --rt-id ${oci_core_route_table.proxy_vcn_drg_ingress_rt.id} --route-rules '${local.ingress_route_rules_json}' --force
     
    EOT
  }
}