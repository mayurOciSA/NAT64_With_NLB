# Placeholder NAT64 Backend Instances

resource "oci_core_instance" "nat64_backend" {
  count = var.backend_count

  availability_domain = data.oci_identity_availability_domains.ad_list.availability_domains[count.index % length(data.oci_identity_availability_domains.ad_list.availability_domains)].name
  compartment_id      = var.compartment_ocid
  display_name        = "nat64_bkend_${count.index}"
  shape               = var.instance_shape

  create_vnic_details {
    subnet_id                 = oci_core_subnet.backend_subnet.id
    display_name              = "pvnic_${count.index}"
    assign_public_ip          = false
    assign_private_dns_record = true
    hostname_label            = "nbk${count.index}"
    assign_ipv6ip             = true
    skip_source_dest_check    = true # Needed for NAT64 functionality, as instance will route/forward traffic 
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
    user_data          = base64encode(file("${path.module}/tayga/cloud-init.yaml"))
  }
}

data "oci_core_vnic_attachments" "be_pvnic_att" {
  count          = var.backend_count
  compartment_id = var.compartment_ocid
  instance_id    = oci_core_instance.nat64_backend[count.index].id
}

data "oci_core_vnic" "be_pvnic" {
  count   = var.backend_count
  vnic_id = data.oci_core_vnic_attachments.be_pvnic_att[count.index].vnic_attachments[0].vnic_id
}

output "backends_ipv4" {
  value= [for backend in oci_core_instance.nat64_backend : backend.create_vnic_details[0].private_ip]
  depends_on = [ oci_core_instance.nat64_backend ]
}

