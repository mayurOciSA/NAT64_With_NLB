# OCI Bastion Service for SOCKS5 access to VCN2

resource "oci_bastion_bastion" "socks5_bastion" {
  bastion_type     = "STANDARD"
  compartment_id   = var.compartment_ocid 
  target_subnet_id = oci_core_subnet.vcnX_private_ipv6.id

  dns_proxy_status = "ENABLED" 

  name                        = "socks5-proxy-bastion"
  client_cidr_block_allow_list = ["0.0.0.0/0"] # Restrict this to your public IP range for security
  max_session_ttl_in_seconds  = 10800 # 3 hours
}

resource "oci_bastion_session" "socks5_session" {
  bastion_id = oci_bastion_bastion.socks5_bastion.id
  key_details {
    public_key_content = var.ssh_public_key # Your SSH public key content
  }
  
  # SOCKS5 Session Type
  target_resource_details {
    session_type = "DYNAMIC_PORT_FORWARDING"
    # No target IP or port is required for DYNAMIC_PORT_FORWARDING
  }

  # Optional
  display_name           = "dynamic-socks5-session"
  key_type               = "PUB"
  session_ttl_in_seconds = 10800 # Match or be less than bastion's max_session_ttl_in_seconds
}

data "oci_bastion_session" "sock5_session" {
    session_id = oci_bastion_session.socks5_session.id
}

locals {
  ssh_no_host_key_check_options = " -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
  sock5_ssh_tunnel_command = replace(
    replace(
      replace(data.oci_bastion_session.sock5_session.ssh_metadata["command"], "ssh", "ssh ${local.ssh_no_host_key_check_options}"),
      "<privateKey>", var.ssh_private_key_local_path),
    "<localPort>", "8888"
  ) 
}

output "ssh_commands_via_proxy" {
  description = "A list of SSH commands to connect to private instances via the SOCKS5 proxy."
  value = <<-EOT
        # Make sure the SOCKS5 tunnel is running in another terminal first:
        ${local.sock5_ssh_tunnel_command} ${local.ssh_no_host_key_check_options}

        # --- VCN2 ULA Client Instance ---
        ssh ${local.ssh_no_host_key_check_options} -o "ProxyCommand nc -X 5 -x 127.0.0.1:8888 %h %p" opc@${oci_core_instance.ula_test_vcnX_client.create_vnic_details[0].private_ip}

        # --- Backend Instances ---
        %{for ip in data.oci_core_private_ips.backend_private_ipv4_objects.private_ips~}
        ssh ${local.ssh_no_host_key_check_options} -o "ProxyCommand nc -X 5 -x 127.0.0.1:8888 %h %p" opc@${ip.ip_address}
        %{endfor~}
EOT
}
