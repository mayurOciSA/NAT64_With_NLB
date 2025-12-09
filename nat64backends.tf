# Placeholder NAT64 Backend Instances

resource "oci_core_instance" "nat64_backend" {
  count = var.backend_nat64_count

  availability_domain = data.oci_identity_availability_domains.ad_list.availability_domains[count.index % length(data.oci_identity_availability_domains.ad_list.availability_domains)].name
  compartment_id      = var.compartment_ocid
  display_name        = "nat64_bkend_${count.index}"
  shape               = var.instance_shape

  create_vnic_details {
    subnet_id                 = oci_core_subnet.backend_nat64_subnet.id
    display_name              = "pvnic_${count.index}"
    assign_public_ip          = false
    assign_private_dns_record = true
    hostname_label            = "nbk64${count.index}"
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
    boot_volume_size_in_gbs = var.instance_boot_volume_size_in_gbs
  }
  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    # TODO
    # user_data = base64encode(templatefile("${path.module}/nat64/cloud-init.yaml", {
    #   nat64_script = file("${path.module}/nat64/tayga.install.sh")
    # }))
  }

}

data "oci_core_vnic_attachments" "be_nat64_pvnic_att" {
  count          = var.backend_nat64_count
  compartment_id = var.compartment_ocid
  instance_id    = oci_core_instance.nat64_backend[count.index].id
}

data "oci_core_vnic" "be_nat64_pvnic" {
  count   = var.backend_nat64_count
  vnic_id = data.oci_core_vnic_attachments.be_nat64_pvnic_att[count.index].vnic_attachments[0].vnic_id
}

data "oci_core_private_ips" "backend_nat64_private_ipv4" {
  subnet_id  = oci_core_subnet.backend_nat64_subnet.id
  depends_on = [oci_core_instance.nat64_backend]
}

data "oci_core_ipv6s" "backend_nat64_private_ipv6" {
  subnet_id  = oci_core_subnet.backend_nat64_subnet.id
  depends_on = [oci_core_instance.nat64_backend]
}

output "backend_nat64_private_ipv6s" {
  value = data.oci_core_ipv6s.backend_nat64_private_ipv6.ipv6s[*]
}

output "backend_nat64_private_ipv4s" {
  value = data.oci_core_private_ips.backend_nat64_private_ipv4.private_ips[*]
}

#TODO
# resource "local_file" "rendered_cloud_init_nat64" {
#   filename = "${path.module}/nat64/cloud-init.rendered.yaml"
#   content = templatefile("${path.module}/nat64/cloud-init.yaml", {
#     nat64_script = file("${path.module}/nat64/tayga.install.sh")
#   })
# }

resource "terraform_data" "provision_nat64_backend" {
  count      = var.backend_nat64_count
  depends_on = [oci_core_instance.nat64_backend, terraform_data.SOCK5_tunnel_start]

  provisioner "local-exec" {
    environment = {
      nat64ipv4host = data.oci_core_private_ips.backend_nat64_private_ipv4.private_ips[count.index].ip_address
    }
    command = <<EOT
        set -o pipefail

        echo "Provisioning NAT64 Backend at $nat64ipv4host"
        scp ${local.ssh_proxy_options} -i ${var.ssh_private_key_local_path} ${path.module}/nat64/tayga.install.sh opc@$nat64ipv4host:~/tayga.install.sh
        if [ $? -ne 0 ]; then
          echo "SCP failed for NAT64"
          exit 1
        fi

        ssh ${local.ssh_custom_options} ${local.ssh_proxy_options} \
          opc@$nat64ipv4host \
          "sudo bash ~/tayga.install.sh" 2>&1 | tee ${path.module}/nat64/tayga.install.$nat64ipv4host.log
        rc=$?
        echo "NAT64 Provisioning completed with exit code $rc for $nat64ipv4host"
        # exit $rc
    EOT
  }
}