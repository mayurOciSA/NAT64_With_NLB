# OCI Bastion Service for SOCKS5 access to VCN2

resource "oci_bastion_bastion" "socks5_bastion" {
  bastion_type     = "STANDARD"
  compartment_id   = var.compartment_ocid
  target_subnet_id = oci_core_subnet.bastion_subnet.id # Subnet where Bastion will be deployed, TODO: create a dedicated subnet for bastion

  dns_proxy_status = "ENABLED"

  name                         = "socks5-proxy-bastion"
  client_cidr_block_allow_list = ["0.0.0.0/0"] # Restrict this to your public IP range for security
  max_session_ttl_in_seconds   = 10800         # 3 hours
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

data "oci_bastion_session" "sock5_session_obj" {
  session_id = oci_bastion_session.socks5_session.id
}

locals {
  ssh_custom_options = " -o ConnectionAttempts=3 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -i ${var.ssh_private_key_local_path}"
  ssh_proxy_options  = " -o \"ProxyCommand nc -X 5 -x 127.0.0.1:8888 %h %p\" "
  sock5_ssh_tunnel_command = replace(
    replace(
      replace(data.oci_bastion_session.sock5_session_obj.ssh_metadata["command"], "ssh", "ssh ${local.ssh_custom_options}"),
    "<privateKey>", var.ssh_private_key_local_path),
    "<localPort>", "8888"
  )
}

output "ssh_commands_via_proxy" {
  description = "A list of SSH commands to connect to private instances via the SOCKS5 proxy."
  value       = <<-EOT
        # Make sure the SOCKS5 tunnel is running in another terminal first:
        ${local.sock5_ssh_tunnel_command} ${local.ssh_custom_options}

        # --- VCN X ULA Client Instance ---
        ssh ${local.ssh_custom_options} ${local.ssh_proxy_options} opc@${oci_core_instance.ula_test_vcnX_client.create_vnic_details[0].private_ip}

        # --- Backend NAT64 Instances ---
        %{for ip in data.oci_core_private_ips.backend_nat64_private_ipv4.private_ips~}
        ssh ${local.ssh_custom_options} ${local.ssh_proxy_options} opc@${ip.ip_address}
        %{endfor~}

        # --- Backend NAT66 Instances ---
        %{for ip in data.oci_core_private_ips.backend_nat66_private_ipv4.private_ips~}
        ssh ${local.ssh_custom_options} ${local.ssh_proxy_options} opc@${ip.ip_address}
        %{endfor~}

        EOT
}

# Start SOCK5 Tunnel and wait for success
resource "terraform_data" "SOCK5_tunnel_start" {
  depends_on = [data.oci_bastion_session.sock5_session_obj]

  provisioner "local-exec" {
    command = <<EOT
    set -e # Exit immediately if a command exits with a non-zero status.

    echo "Attempting to start SOCKS5 SSH Tunnel..."
    echo "Command: ${local.sock5_ssh_tunnel_command}"
    sleep 10

    # Execute the SSH command synchronously in the background, redirecting output
    # The 'sleep' and 'wait' commands are used to keep the provisioner running 
    # and fail only if the SSH command itself fails immediately (e.g., bad connection).
    # Since we can't fully check the health of the tunnel inside 'local-exec' 
    # without a specific health check script, we rely on the SSH command's 
    # exit code and a short wait time.

    ${local.sock5_ssh_tunnel_command} > /tmp/socks5_tunnel.log 2>&1 &
    
    # Capture the PID of the background process
    TUNNEL_PID=$!

    echo "Tunnel started with PID: $TUNNEL_PID. Waiting 5 seconds for establishment..."
    
    # Wait for a few seconds to let the tunnel try to establish
    sleep 5
    
    # Check if the process is still running. This is a basic health check.
    if ! ps -p $TUNNEL_PID > /dev/null; then
        echo "Error: SOCKS5 Tunnel process with PID $TUNNEL_PID is not running or failed to launch."
        cat /tmp/socks5_tunnel.log
        exit 1
    fi

    echo "SOCKS5 Tunnel appears to be running."

    # NOTE: You MUST kill this process in a subsequent `null_resource` or `terraform_data`
    # provisioner with a 'destroy' block, otherwise it will remain orphaned.
    
    EOT
  }
}

