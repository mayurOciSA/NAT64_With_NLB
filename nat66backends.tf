# Placeholder NAT66 Backend Instances

resource "oci_core_instance" "nat66_backend" {
  count = var.backend_nat66_count

  availability_domain = data.oci_identity_availability_domains.ad_list.availability_domains[count.index % length(data.oci_identity_availability_domains.ad_list.availability_domains)].name
  compartment_id      = var.compartment_ocid
  display_name        = "nat66_bkend_${count.index}"
  shape               = var.instance_shape

  create_vnic_details {
    subnet_id                 = oci_core_subnet.backend_nat66_subnet.id
    display_name              = "pvnic_${count.index}"
    assign_public_ip          = false # No public IPv4s for backend NAT66 instances
    assign_private_dns_record = true
    hostname_label            = "nbk66${count.index}"
    assign_ipv6ip             = true # Assign IPv6 address from subnet's IPv6 CIDR block
    skip_source_dest_check    = true # Needed for NAT66 functionality, as instance will route/forward traffic 
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
    # user_data = base66encode(templatefile("${path.module}/nat66/cloud-init.yaml", {
    #   nat66_script = file("${path.module}/nat66/nat66.setup.sh")
    # }))
  }
}


data "oci_core_vnic_attachments" "be_nat66_pvnic_att" {
  count          = var.backend_nat66_count
  compartment_id = var.compartment_ocid
  instance_id    = oci_core_instance.nat66_backend[count.index].id
}

variable "is_assign_secondary_ipv6_to_backend_nat66" {
  description = "Do you want to assign secondary IPv6 to backend NAT66 instances?"
  type        = bool
  default     = true
}
resource "oci_core_ipv6" "secondary_ipv6" {
  count   = var.backend_nat66_count
  vnic_id = data.oci_core_vnic_attachments.be_nat66_pvnic_att[count.index].vnic_attachments[0].vnic_id
}

data "oci_core_vnic" "be_nat66_pvnic" {
  count   = var.backend_nat66_count
  vnic_id = data.oci_core_vnic_attachments.be_nat66_pvnic_att[count.index].vnic_attachments[0].vnic_id
}

data "oci_core_private_ips" "backend_nat66_private_ipv4" {
  subnet_id  = oci_core_subnet.backend_nat66_subnet.id
  depends_on = [oci_core_instance.nat66_backend]
}

data "oci_core_ipv6s" "backend_nat66_private_ipv6" {
  subnet_id  = oci_core_subnet.backend_nat66_subnet.id
  depends_on = [oci_core_instance.nat66_backend]
}

output "backend_nat66_private_ipv6s" {
  value = data.oci_core_ipv6s.backend_nat66_private_ipv6.ipv6s[*].ip_address
}

output "backend_nat66_private_ipv4s" {
  value = data.oci_core_private_ips.backend_nat66_private_ipv4.private_ips[*].ip_address
}

resource "terraform_data" "provision_nat66_backend" {
  count      = var.backend_nat66_count
  depends_on = [oci_core_instance.nat66_backend, terraform_data.SOCK5_tunnel_start, oci_core_ipv6.secondary_ipv6]


  provisioner "local-exec" {
    environment = {
      nat66ipv4host = data.oci_core_private_ips.backend_nat66_private_ipv4.private_ips[count.index].ip_address
    }
    command = <<EOT
        
        export nat66ipv4host=$nat66ipv4host
        echo "Provisioning NAT66 Backend at $nat66ipv4host"

        # Exit with success if remote node already has nat66_setup.sh script
        if ssh ${local.ssh_proxy_options} ${local.ssh_custom_options} opc@$nat66ipv4host "test -f ~/nat66_setup.sh"; then
          echo "NAT66 Backend already provisioned at $nat66ipv4host"
          exit 0
        fi

        scp ${local.ssh_proxy_options} -i ${var.ssh_private_key_local_path} \
          ${path.module}/nat66/nat66_setup.sh opc@$nat66ipv4host:~/nat66_setup.sh
        if [ $? -ne 0 ]; then
          echo "SCP failed for NAT66 $nat66ipv4host"
          exit 1
        fi
        echo "SCP completed for NAT66 $nat66ipv4host"
        
        exit 0
        mkdir -p ${path.module}/nat66/installation_logs
        ssh ${local.ssh_proxy_options} ${local.ssh_custom_options} \
          opc@$nat66ipv4host \
          "sudo bash ~/nat66_setup.sh" > ${path.module}/nat66/installation_logs/nat66_setup_$(date +'%Y-%m-%d-%H%M')_$nat66ipv4host.log 2>&1

        rc=$?
        echo "NAT66 Provisioning completed with exit code $rc for $nat66ipv4host"
        exit $rc
    EOT
  }
}
