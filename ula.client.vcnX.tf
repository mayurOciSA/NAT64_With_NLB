# Placeholder ULA Clients in VCN1 
variable "ula_test_vcnX_client_count" {
  description = "Number of test clients you want as ULA Clients"
  default     = 2
}

resource "oci_core_instance" "ula_test_vcnX_client" {
  count               = var.ula_test_vcnX_client_count
  availability_domain = data.oci_identity_availability_domains.ad_list.availability_domains[0].name
  compartment_id      = var.compartment_ocid
  display_name        = "UlaTestClient${count.index}"
  shape               = var.instance_shape

  create_vnic_details {
    subnet_id                 = oci_core_subnet.vcnX_private_ipv6.id
    display_name              = "pv"
    assign_public_ip          = false
    assign_private_dns_record = true
    hostname_label            = "uclient${count.index}"
    assign_ipv6ip             = true
  }

  shape_config {
    memory_in_gbs = var.instance_memory_in_gbs
    ocpus         = var.instance_ocpus
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.oracle_linux_images_oci.images[0].id
    boot_volume_size_in_gbs = var.instance_boot_volume_size_in_gbs
  }
  metadata = {
    ssh_authorized_keys = var.ssh_public_key
  }
}

data "oci_core_private_ips" "ula_test_vcnX_client_private_ipv4" {
  subnet_id  = oci_core_subnet.vcnX_private_ipv6.id
  depends_on = [oci_core_instance.ula_test_vcnX_client]
}

output "ula_test_client_private_ipv4s" {
  value      = data.oci_core_private_ips.ula_test_vcnX_client_private_ipv4.private_ips[*].ip_address
  depends_on = [oci_core_instance.ula_test_vcnX_client]
}
