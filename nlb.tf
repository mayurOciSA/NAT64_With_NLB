resource "oci_network_load_balancer_network_load_balancer" "nlb" {
  compartment_id                 = var.compartment_ocid
  display_name                   = "proxy-nlb"
  subnet_id                      = oci_core_subnet.nlb_subnet.id
  is_private                     = true
  is_preserve_source_destination = true
  is_symmetric_hash_enabled      = true
  nlb_ip_version                 = "IPV4_AND_IPV6"
  assigned_ipv6                  = "fd00:20:0:100::100"
  assigned_private_ipv4          = "10.1.1.25"
}

resource "oci_network_load_balancer_listener" "listener" {
  default_backend_set_name = oci_network_load_balancer_backend_set.nlb-bes-nat64.name
  name                     = "nat64_listener"
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.nlb.id
  protocol                 = "ANY" # = TCP+UDP+ICMP
  ip_version               = "IPV6"
  port                     = 0

  # # l3ip_idle_timeout = 1800
  # # tcp_idle_timeout  = 1800
  # # udp_idle_timeout  = 1800
}

resource "oci_network_load_balancer_backend_set" "nlb-bes-nat64" {
  name                                  = "nlb-bes-nat64"
  network_load_balancer_id              = oci_network_load_balancer_network_load_balancer.nlb.id
  policy                                = "FIVE_TUPLE"
  is_instant_failover_enabled           = true
  is_instant_failover_tcp_reset_enabled = true
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

resource "oci_network_load_balancer_backend" "nlb-be" {
  count = var.backend_count

  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.nlb.id
  backend_set_name         = oci_network_load_balancer_backend_set.nlb-bes-nat64.name
  ip_address               = data.oci_core_vnic.be_pvnic[count.index].ipv6addresses[0]
  port                     = 0
  is_backup                = false
  is_drain                 = false
  is_offline               = false
  weight                   = 1
}

data "oci_network_load_balancer_network_load_balancer" "nlb" {
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.nlb.id
}


data "oci_core_private_ips" "nlb_private_ipv4" {
  ip_address = "10.1.1.25"
  subnet_id  = oci_core_subnet.nlb_subnet.id
  depends_on = [data.oci_network_load_balancer_network_load_balancer.nlb]
}

data "oci_core_ipv6s" "nlb_private_ipv6" {
  ip_address = "fd00:20:0:100::100"
  subnet_id  = oci_core_subnet.nlb_subnet.id
  depends_on = [data.oci_network_load_balancer_network_load_balancer.nlb]
}
