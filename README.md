# Solution for NAT64 and NAT66 with DRG & NLB on OCI

## Table of Contents
1. [Introduction](#introduction)
2. [Solution Architecture](#solution-architecture)
3. [Deployment Output](#deployment-output)
   - [VCN X ("Production VCN")](#vcn-x-production-vcn)
   - [Dynamic Routing Gateway (DRG)](#dynamic-routing-gateway-drg)
   - [Proxy VCN](#proxy-vcn)
4. [Configuration with TF variables](#configuration-with-tf-variables)
5. [Deployment Steps](#deployment-steps)
6. [Testing NAT64](#testing-nat64)
7. [Testing NAT66](#testing-nat66)
8. [Limitations/Future Extensions](#limitationsfuture-extensions)

---

## Introduction
This Terraform setup will help you deploy a NAT64 and NAT66 solution on **Oracle Cloud Infrastructure (OCI)** with Dynamic Routing Gateway (DRG) & Network Load Balancers (NLBs). Instead of DRG you can also use Local Peering Gateway (LPG).

The setup connects an ULA-IPv6-only subnet in VCN X (placeholder for your production ULA only network on OCI) to both 
1) Public IPv4 internet via NAT64 NVAs via OCI NAT Gateway(NATGW) &
2) Public GUA internet via NAT66 NVAs via OCI Internet Gateway(IGW).

Solution is self-contained in a seperate VCN called Proxy VCN. Proxy VCN has 3 private subnets. One for two NLBs, 2nd for NAT64 backend(s)/NVAs & 3rd for NAT66 backend(s)/NVAs. Each NLB is private, dual-stack, acting in transparent (bump-in-the-wire) mode with IPv6 ULA address. 

The focus of this terraform is on Proxy VCN, NLBs within it and backends performing NAT64/NAT66. Needless to say, there should no overlap of IP addresses in VCN X(your ULA VCNs) and Proxy VCN.

For production grade setup, further tuning might be required for backend NVAs doing NAT64/NAT66 translation. It is left to users to manage their NAT64/NAT66 NVAs as per their production needs. Read section on Limitations/Future Extensions.

Why NLB?

With NLB:  1)When pool of backends is scaled up or down, in flight connections will remain sticky 2) You will also get health check for NAT64/NAT66 NVAs. Both these are handled by NLB, when it fronts NAT64 or NAT66 NVAs transparently.

---
## Solution Architecture

<img src="diagrams/NAT64_NAT66.drawio.svg" width='160%' height='150%' alt="NAT64 & NAT66  on OCI" style="border: 2px solid black;"/>

### Note: The diagram above illustrates both custom NAT64 & NAT66 Architecture by using multiple backend NAT64/NAT66 instances, NLBs, &  Ingress Route Table for DRG.

## Deployment Output

After running this Terraform, you will have:

### VCN X ("Production VCN")
- **A VCN with IPv6 and IPv4 address space**
- **One private subnet (IPv6-only)** for compute resources
- **A VCN attachment to DRG** for connection to the Proxy VCN
- **Subnet route table:** All GUA IPv6(`2000::/3`) traffic and NAT64 RFC 6052 prefix(`64:ff9b::/96`) traffic is routed to the DRG (towards the Proxy VCN)

### Dynamic Routing Gateway (DRG)
- **A Dynamic Routing Gateway (DRG)** for inter-VCN communication
- **Ingress/Transit Route Table:** Routes all GUA IPv6(`2000::/3`) traffic from VCN X to the NLB fronting NAT66 NVAs and NAT64 RFC 6052 prefix(`64:ff9b::/96`) traffic from VCN X to the NLB fronting NAT64 NVAs

### Proxy VCN
- **A separate (dual-stack IPv4/IPv6)VCN dedicated to NAT64 and NAT66 proxying**
- **Private Subnet for Network Load Balancer (NLB)s**(needs only IPv6). For two NLBs acting in transparent (bump-in-the-wire) mode
- **Private Subnet for NAT64 Backend(s)** (dual-stack IPv4/IPv6), backends run `Tayga` for stateless NAT64 and use Linux kernel(using `iptables`) to add statefulness to NAT64.
Each backend has exactly one interface/VNIC, which is its primary interface with only one private IPv4 address and one ULA IPv6 address.
- **Private Subnet for NAT66 Backend(s)** (needs only IPv6), backends use Linux kernel(using `nftables` and `conntrack`) to run stateful NAT66. If backend node has multiple GUA IPv6 addresses, it will hash or load balance the flow depending on source and destination IPv6 addresses of the flow. Each backend has exactly one interface/VNIC, which is its primary interface with only one private IPv4 address and can have one or more configurable number of GUA IPV6 addresses. All GUA IPv6 addresses will be used for NAT66 translation, with hash based load balancing.
- **Private Subnet for Bastion**(needs only IPv4). Bastion is created in seperate IPv4 only private subnet in Proxy VCN.
- **A VCN attachment to DRG** for connection to the VCN X.  
- **A NAT Gateway** for IPv4 internet egress, for NAT64-ed traffic
- **A Internet Gateway** for IPv4 internet egress, for NAT66-ed traffic    - 
- **All three route tables configured**:
    - NLB Subnet: Empty, meaning default implcit covering only intra-VCN routability.
    - NAT64 Backend Subnet: routes all `0.0.0.0/0` to NAT Gateway (IPv4) and ULA IPv6(`fc00::/7`) to DRG (IPv6)
    - NAT66 Backend Subnet: routes all GUA IPv6(`2000::/3`) to Internet Gateway (IPv4) and ULA IPv6(`fc00::/7`) to DRG (IPv6)
 
### Security Rules
- **Update and change SL/NSGs for all VCNs/subnets as per your needs.**

### Bastion
- **Bastion is created with SOCKS5 proxy** for easy access to all nodes, in VCN X and Proxy VCN. For bastion access, use SSH with SOCKS5 proxy.
We also start SOCKS5 proxy to bastion node from your local machine. And also output all SSH commands to connect to all nodes.
Bastion is created in seperate IPv4 only private subnet in Proxy VCN.

***Same proxy is also used execute setup scripts on all backend nodes of NAT64/NAT66, over SSH.*** You can alternatively use CloudInit or Ansible to setup NAT64/NAT66 NVAs.

### Output
- Outputs include OCIDs and IPv4s/IPv6s of key generated resources.
- You will see setup logs of NAT64/NAT66 NVAs in the directory `${path.module}/nat64/installation_logs` and `${path.module}/nat66/installation_logs`.
---

## Configuration with TF variables

Solution is highly configurable with variables.
Rename `local.tfvars.example` to `local.tfvars` and fill in the placeholders with your values.

---

## Deployment Steps

### 1. Initialize Terraform
```bash
terraform init
```
### 2. Run Terraform Plan
```bash
terraform plan --var-file=local.tfvars 
```
### 3. Run Terraform Apply
```bash
terraform apply --var-file=local.tfvars --auto-approve
```
### 4. When needed for teardown
```bash
terraform destroy --var-file=local.tfvars --auto-approve
```


## Testing NAT64
From UlaClient node in VCN X do the following:

### Testing ICMPv6 flows:
```shell
ping6 64:ff9b::8.8.8.8 # Ping Google DNS via NAT64

mtr 64:ff9b::8.8.8.8

mtr 64:ff9b::23.219.5.221 # Ping www.Oracle.com
```
With mtr you will see backend Tayga server's ULA IPv6 address in the list of hops, as chosen by ECMP for that flow.

### Testing TCP/HTTPs flows:

```Shell
IPv4_ADDR=$(dig +short ams.download.datapacket.com A | tail -1)
echo $IPv4_ADDR
curl -6 --resolve ams.download.datapacket.com:443:[64:ff9b::$IPv4_ADDR] https://ams.download.datapacket.com/100mb.bin -o 100mb.bin


IPv4_ADDR=$(dig +short ash-speed.hetzner.com A | tail -1)
echo $IPv4_ADDR
curl -6 --resolve ash-speed.hetzner.com:443:[64:ff9b::$IPv4_ADDR] https://ash-speed.hetzner.com/10GB.bin -o 10GB.bin

```
Or
```Shell
IPv4_ADDR=$(dig +short ams.download.datapacket.com A | tail -1)
echo $IPv4_ADDR

curl -6 -s -o /dev/null -w "
DNS Lookup Time: %{time_namelookup}s
TCP Connect Time (cumulative): %{time_connect}s
TLS Handshake Time (cumulative): %{time_appconnect}s
Time it took for the server to start transferring data: %{time_starttransfer}
Total Time: %{time_total}s

Calculated TCP Handshake Duration: %{time_connect}s
Calculated TLS Handshake Duration: %{time_appconnect}s minus %{time_connect}s 
" --resolve ams.download.datapacket.com:443:[64:ff9b::$IPv4_ADDR] https://ams.download.datapacket.com/100mb.bin 

```

Note, the `--resolve` parameter is needed for HTTPs, otherwise SNI expected by webserver won't be populated, and curl won't work. 
With your own DNS64 setup, you won't need `--resolve`.

#### See all NAT64's ULA IPv6 as 2nd hop for TCP flows:
With following `mtr` command, you should see ULA IPv6 of each of backend NAT64, showing load balancing @NLB. This is due to mutliple source ports used by `mtr` for tcp probing.

```shell
mtr -T -P 443 64:ff9b::23.219.5.221
```
If you want src port control, install traceroute on ULA clients and execute the following command. Here you should see only one hop chosen for that TCP flow.
```Shell
traceroute -T -O info --sport=50845 -p 443 64:ff9b::23.219.5.221
```

### Testing UDP flows:

```shell
mtr -u 64:ff9b::23.219.5.221
```

#### Negative Test
After turning off traffic on NATGW, above curl should stop working.

IPv4_ADDR=$(dig +short ams.download.datapacket.com A | tail -1)
echo $IPv4_ADDR
curl -6 --resolve ams.download.datapacket.com:443:[64:ff9b::$IPv4_ADDR] https://ams.download.datapacket.com/100mb.bin -o 100mb.bin


## Testing NAT66

### Testing ICMPv6 flows:
From ULA clients, run basic pings. Ping should work.
```shell
ping -6 -c 1 www.cloudflare.com
```

On backendnat66, verify SNATing from ULA to NAT66 NVA's GUA, for the same above flow
```shell
sudo conntrack -E -f ipv6 --src-nat
```

From ULA clients, check MTU is 1500 for internet bound traffic. Following should fail, and you should see `ICMPv6 packet too big` error from a NAT66 NVA.
```shell
ping -6 -c 1 -M do -s 3000 www.google.com
```

Check NAT66 NVA reply to mtr as intermediate hop. 
Note you will only see the one of the IPv6 GUA of the NAT66 NVA, which is added as backend's IPv6 address to the NAT66 NLB.
```shell
mtr -6 www.cloudflare.com
```

### Testing TCP/HTTPs flows:
Download and checksum of file located in Amsterdam, Execute the same command from your devbox and checksum should match
```shell
curl -6 https://ams.download.datapacket.com/100mb.bin | sha1sum
```

Download and checksum of file located in Singapore, Execute the same command from your devbox and checksum should match
```shell
curl -6  https://sin-speed.hetzner.com/1GB.bin | sha1sum
```

Also execute above commands from multiple different ULA Clients at the same time, to make sure NAT66 works for concurrent connections.

#### See all NAT66 NVA's GUA as 2nd hop for TCP flows:
For the following mtr, you will see multiple 2nd hops, as multiple source ports are used by mtr for TCP probing. For 2nd hop, you should all the IPv6 GUAs of the NAT66 NVA, which are added as backend's IPv6 address to the NAT66 NLB.
```shell
mtr -6 -T -P 443 www.cloudflare.com
```

### Testing UDP flows:

```shell
mtr -6 -u www.cloudflare.com
```
Alternatively use HTTP3 with QUIC for UDP testing.

## Limitations/Future Extensions
- Users are expected to adjust shape or #OCPU of backend nodes where NAT64 software is installed as per their bandwidth needs.
- Users are expected to adjust the # of backends nodes as per their bandwidth needs. Total bandwidth in Gbps provided by setup is ~(#OCPU of each backend node)*(# backend nodes)
- Users are expected to adjust the SL/NSG rules, as per security needs. Also if needed harden OL9 installation.
- The setup chooses latest OL9 version as OS for backends for a given region, if you want hardcoded OS image, please alter the code.
- For production grade NAT64 setup, further tuning might be required for Tayga, esp timeouts for con-tracking, poolsize of virtual IPv4s used by Tayga, log exports for Tayga etc, contrack table size etc. It is left to users to manage their NAT64 NVAs. 
- For production grade NAT66 setup, further tuning might be required timeouts for con-tracking, number of GUAs on each NAT66 NVA, log exports for NAT66 etc, contrack table size etc. It is left to users to manage their NAT66 NVAs. 
- Setup appropriate healthchecks for backends.
- The setup has not been tested for long running connections say for connections running longer than 15 minutes.
- Installation script for NAT64(Tayga) and for NAT66 is only tested for OL9.
- Technically, setup of both NAT64 and NAT66 is possible on the same backends. I plan to add that in the future. That will eliminate the need for separate backends/NLBs/subnets for NAT64 and NAT66.
- It is recommended to use different public keys for NAT64/NAT66 NVAs and for Bastion, for better security.