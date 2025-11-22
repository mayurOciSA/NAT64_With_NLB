# OCI NAT64 Proxy VCN with LPG – End-to-End Terraform Deployment Guide

---

## Introduction
This guide will help you deploy a **dual-stack NAT64 Proxy VCN** using **Oracle Cloud Infrastructure (OCI)** with Local Peering Gateway (LPG) integration. Instead of LPG you can also use DRG.

The setup connects an IPv6-only subnet in VCN1 (your production VCN) to IPv4-native resources via a transparent Network Load Balancer, NAT Gateway, and a backend pool (e.g., NAT64 appliances), all residing in a dedicated Proxy VCN. Instead VCN1 you will havve your own already existing VCNs. The focus of this terraform is on proxy VCN, NLB within it and backends performing NAT64.

This entire architecture is deployable by the provided Terraform manifest—with minor adjustments—enabling IPv6-to-IPv4 translation for cloud resources.

---

## I. What Will the User Get? (Deployment Output)

After running this Terraform, you will have:

### VCN1 ("Production VCN")
- **A VCN with IPv6 and IPv4 address space**
- **One private subnet (IPv6-only)** for compute resources
- **A Local Peering Gateway (LPG)** for connection to the Proxy VCN
- **Subnet route table:** All IPv6 traffic (`::/0`) is routed to the LPG (towards the Proxy VCN)

### Proxy VCN
- **A separate VCN dedicated to NAT64 proxying**
- **Private Subnet for Network Load Balancer (NLB)** (dual-stack IPv4/IPv6)
- **Private Subnet for NAT64 Backend(s)** (dual-stack IPv4/IPv6)
- **A Local Peering Gateway (LPG)** for inter-VCN communication
- **A NAT Gateway** for IPv4 internet egress
- **A Network Load Balancer (NLB)**
    - Private, dual-stack, acting in transparent (bump-in-the-wire) mode
- **A sample compute instance** (intended as the NAT64 backend) in backend subnet
- **All three route tables configured**:
    - NLB Subnet: empty
    - Backend Subnet: routes all `0.0.0.0/0` to NAT Gateway (IPv4) and `::/0` to LPG (IPv6)
    - LPG ingress: routes all `::/0` traffic from VCN1 (arriving via LPG) to the NLB's private IPv6 ULA address

### Security Rules
- **Update and change SL/NSGs for all VCNs/subnets as per your needs.**

### LPG Peering
- **LPGs in each VCN are peered** (supporting intra-region, cross-VCN traffic)



### Output
- Outputs include all OCIDs for generated resources and the load balancer's private IP.



---

## II. What Do I Need to Change Before Deploying?

Rename local.tfvars.example to local.tfvars and fill in the placeholders with your values.

---

## III. Deployment Steps

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