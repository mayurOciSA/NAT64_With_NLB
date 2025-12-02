# Placeholder ULA Clients in VCN1 
resource "oci_core_instance" "ula_test_vcnX_client" {
  availability_domain = data.oci_identity_availability_domains.ad_list.availability_domains[0].name
  compartment_id      = var.compartment_ocid
  display_name        = "ulavcnX"
  shape               = var.instance_shape

  create_vnic_details {
    subnet_id                 = oci_core_subnet.vcnX_private_ipv6.id
    display_name              = "pv"
    assign_public_ip          = false
    assign_private_dns_record = true
    hostname_label            = "ulavcnX"
    assign_ipv6ip             = true
    private_ip = "10.1.1.5"
  }

  shape_config {
    memory_in_gbs = var.instance_memory_in_gbs
    ocpus         = var.instance_ocpus
  }

  source_details {
    source_type = "image"
    source_id   = data.oci_core_images.oracle_linux_images_oci.images[0].id
  }
  metadata = {
    ssh_authorized_keys = var.ssh_public_key
  }
}

output "ula_test_vcnX_client_ipv4" {
  value= oci_core_instance.ula_test_vcnX_client.create_vnic_details[0].private_ip
  depends_on = [ oci_core_instance.ula_test_vcnX_client ]
}