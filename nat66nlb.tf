resource "oci_network_load_balancer_network_load_balancer" "nlb_nat66" {
  compartment_id                 = var.compartment_ocid
  display_name                   = "proxy-nlb-nat66"
  subnet_id                      = oci_core_subnet.nlb_subnet.id
  is_private                     = true
  is_preserve_source_destination = true
  is_symmetric_hash_enabled      = true
  nlb_ip_version                 = "IPV4_AND_IPV6"

  assigned_ipv6         = cidrhost(var.nlb_subnet_ipv6_cidr, 20)
  assigned_private_ipv4 = cidrhost(var.nlb_subnet_ipv4_cidr, 20)
}

resource "oci_network_load_balancer_listener" "listener_nat66" {
  default_backend_set_name = oci_network_load_balancer_backend_set.nlb-bes-nat66.name
  name                     = "nat66_listener"
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.nlb_nat66.id
  protocol                 = "ANY" # = TCP+UDP+ICMP
  ip_version               = "IPV6"
  port                     = 0

  # # l3ip_idle_timeout = 1800
  # # tcp_idle_timeout  = 1800
  # # udp_idle_timeout  = 1800
}

resource "oci_network_load_balancer_backend_set" "nlb-bes-nat66" {
  name                                  = "nlb-bes-nat66"
  network_load_balancer_id              = oci_network_load_balancer_network_load_balancer.nlb_nat66.id
  policy                                = "FIVE_TUPLE"
  is_instant_failover_enabled           = true
  is_instant_failover_tcp_reset_enabled = true
  is_fail_open                          = false
  is_preserve_source                    = true # # Preserve source IP for backend instances
  ip_version                            = "IPV6"

  health_checker { #change as needed
    port               = "22"
    protocol           = "TCP"
    timeout_in_millis  = 10000
    interval_in_millis = 10000
    retries            = 3
  }
}

resource "oci_network_load_balancer_backend" "nlb-nat66-be" {
  count = var.backend_nat66_count

  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.nlb_nat66.id
  backend_set_name         = oci_network_load_balancer_backend_set.nlb-bes-nat66.name
  ip_address               = data.oci_core_vnic.be_nat66_pvnic[count.index].ipv6addresses[0]
  port                     = 0
  is_backup                = false
  is_drain                 = false
  is_offline               = false
  weight                   = 1
}

output "nlb_nat66_ips" {
  value = [oci_network_load_balancer_network_load_balancer.nlb_nat66.assigned_ipv6, oci_network_load_balancer_network_load_balancer.nlb_nat66.assigned_private_ipv4]
}

data "oci_core_ipv6s" "nlb_nat66_private_ipv6" {
  subnet_id  = oci_core_subnet.nlb_subnet.id
  ip_address = cidrhost(var.nlb_subnet_ipv6_cidr, 20)
  depends_on = [oci_network_load_balancer_network_load_balancer.nlb_nat66]
}
