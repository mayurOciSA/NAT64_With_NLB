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
    source_type             = "image"
    source_id               = data.oci_core_images.oracle_linux_images_oci.images[0].id
    boot_volume_size_in_gbs = var.instance_boot_volume_size_in_gbs
  }
  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    # TODO REMOVE
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
  value = data.oci_core_ipv6s.backend_nat64_private_ipv6.ipv6s[*].ip_address
}

output "backend_nat64_private_ipv4s" {
  value = data.oci_core_private_ips.backend_nat64_private_ipv4.private_ips[*].ip_address
}

resource "terraform_data" "provision_nat64_backend" {
  count      = var.backend_nat64_count
  depends_on = [oci_core_instance.nat64_backend, terraform_data.SOCK5_tunnel_start]

  provisioner "local-exec" {
    environment = {
      nat64ipv4host = data.oci_core_private_ips.backend_nat64_private_ipv4.private_ips[count.index].ip_address
    }
    command = <<EOT

        # Exit with success if remote node already has nat64_setup.sh script
        if ssh ${local.ssh_proxy_options} ${local.ssh_custom_options} opc@$nat64ipv4host "test -f ~/nat64_setup.sh"; then
          echo "NAT64 Backend already provisioned at $nat64ipv4host"
          exit 0
        fi

        echo "Provisioning NAT64 Backend at $nat64ipv4host"
        scp ${local.ssh_proxy_options} -i ${var.ssh_private_key_local_path} ${path.module}/nat64/nat64_setup.sh opc@$nat64ipv4host:~/nat64_setup.sh
        if [ $? -ne 0 ]; then
          echo "SCP failed for NAT64 $nat64ipv4host"
          exit 1
        fi
        echo "SCP completed for NAT64 $nat64ipv4host"

        mkdir -p ${path.module}/nat64/installation_logs
        ssh ${local.ssh_proxy_options} ${local.ssh_custom_options} \
          opc@$nat64ipv4host \
          "sudo bash ~/nat64_setup.sh" > ${path.module}/nat64/installation_logs/nat64_setup_$(date +'%Y-%m-%d-%H%M')_$nat64ipv4host.log 2>&1
        
        rc=$?
        echo "NAT64 Provisioning completed with exit code $rc for $nat64ipv4host"
        exit $rc
    EOT
  }
}
