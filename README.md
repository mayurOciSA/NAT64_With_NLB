# OCI NAT64 Proxy VCN with just DRG and ECMP enabled Ingress Route Table, without NLB – End-to-End Terraform Deployment Guide

## Table of Contents

- [Introduction](#introduction)
- [Diagram](#diagram)
- [What Will the User Get? (Deployment Output)](#what-will-the-user-get-deployment-output)
- [What Do I Need to Change Before Deploying?](#what-do-i-need-to-change-before-deploying)
- [Deployment Steps](#deployment-steps)
- [Trade off between ECMP vs NLB.](#trade-off-between-ecmp-vs-nlb)
- [Testing](#testing)

---

## Introduction
This guide will help you deploy a **dual-stack NAT64 Proxy VCN** using **Oracle Cloud Infrastructure (OCI)** with DRG integration. 

The setup connects an IPv6-only subnet in VCN X (your production VCN) to IPv4-native resources via a transparent NAT Gateway and a backend pool (e.g., NAT64 appliances), all residing in a dedicated Proxy VCN. Instead VCN X you will havve your own already existing VCNs. The focus of this terraform is on proxy VCN, its DRG ingress/transit route table and backends performing NAT64. *For testing purposes only*, backends are installed with Tayga.

This entire architecture is deployable by the provided Terraform minor adjustments—enabling IPv6-to-IPv4 translation for cloud resources.

## Diagram

<img src="diagrams/NAT64.drawio.svg" alt="NAT64 Diagram" style="border: 2px solid black;"/>

### Note: The diagram above illustrates a NAT64 setup by using multiple backend NAT64/Tayga instances and ECMP (Equal-Cost Multi-Path) routing on the DRG Ingress/Transit Route Table to *crduely* load balance traffic across backends.

---

## What Will the User Get? (Deployment Output)

After running this Terraform, you will have:

### VCN X ("Production VCN")
- **A VCN with IPv6 and IPv4 address space**
- **One private subnet (IPv6-only)** for compute resources
- **A DRG** for connection to the Proxy VCN
- **Subnet route table:** All IPv6 traffic (`::/0`) is routed to the DRG (towards the Proxy VCN)

### Proxy VCN
- **A separate VCN dedicated to NAT64 proxying**
- **Private Subnet for NAT64 Backend(s)** (dual-stack IPv4/IPv6)
- **A DRG** for inter-VCN communication
- **A NAT Gateway** for IPv4 internet egress
- **A sample compute instance with Tayga preinstalled with cloud init** (intended as the NAT64 backend) in backend subnet
- **All 2 route tables configured**:
    - Backend Subnet: routes all `0.0.0.0/0` to NAT Gateway (IPv4) and `::/0` to LPG (IPv6)
    - ECMP enabled DRG ingress route table: routes all `::/0` traffic from VCN X (arriving via DRG) to the ULA IPv6 addresses of each of the NAT64 Tayga instances. ECMP does 5-tuple based loa balancing among backend nodes.

### Security Rules
- **Update and change SL/NSGs for all VCNs/subnets as per your needs.**

### DRG Peering
- **DRG has VCN attachments for both VCN X and VCN Proxy, hence peering them** (supporting intra-region, cross-VCN traffic)


### Bastion for SOCK5 access
- **We also create bastion for SOCK5 access to SSH into sample ULA client node and if needed into Tayga Backend nodes. Commands for sock5 setup and SSH will also be given to you** 

### Output
- Outputs include all OCIDs for generated resources & their private/ULA IPs.

---

## What Do I Need to Change Before Deploying?

Rename local.tfvars.example to local.tfvars and fill in the placeholders with your values.

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

## Trade off between ECMP vs NLB.
ECMP based load balancing is crude but can work for certain usecases. The 2 downsides are:  1)When pool of backends is scaled up or down, in flight connections will get dropped, as flow based hashing done by DRG ingress route table for Proxy VCN changes aka it is not sticky for in-flight connections 2) You will need your own health check for NAT64 nodes.

## Testing
From UlaClient node in VCN1 do the following:

### Testing ICMPv6 flows:
```shell
ping6 64:ff9b::8.8.8.8 # Ping Google DNS via NAT64

mtr 64:ff9b::8.8.8.8

mtr 64:ff9b::23.219.5.221 # Ping www.Oracle.com
```
With mtr you will see backend Tayga server's IPv6 address in the list of hops, as chosen by ECMP for that flow.

### Testing TCP/HTTPs flows:

```Shell
IPv4_ADDR=$(dig +short ams.download.datapacket.com A | tail -1)
echo $IPv4_ADDR
curl -6 --resolve ams.download.datapacket.com:443:[64:ff9b::$IPv4_ADDR] https://ams.download.datapacket.com/100mb.bin -o 100mb.bin
```
Note, the `--resolve` parameter is needed for HTTPs, otherwise SNI expected by webserver won't be populated, and curl won't work. 
With DNS64 of Telesis, they won't need `--resolve`.

#### Negative Test
After turning off traffic on NATGW, above curl should stop working.