# Aedis AWS VPC module

Terraform module (provider `hashicorp/aws` v6) for a VPC that is private by construction and ready for Cloudflare Zero
Trust: workloads live in private subnets with no inbound path from the internet, people reach them through a
`cloudflared` tunnel behind Cloudflare Access, and every packet and DNS query leaves a record. It is built to be cheap
while small (no NAT gateway by default) and to grow by changing two variables.

## Usage

```hcl
module "network" {
  source  = "aedis-build/aedis-vpc/aws"
  version = "1.0.0" # an exact release; releases are immutable

  name            = "example"
  cidr            = "10.20.0.0/16"
  blocked_domains = ["vendor.example", "*.vendor.example"]
}
```

Credentials come from the caller's environment (`AWS_PROFILE`, IAM Identity Center); the module declares no provider
configuration and no backend. Reference of every option: [`examples/complete`](examples/complete/main.tf);
`terraform test` plans the module with the provider mocked, with no credentials. The defaults alone:
[`examples/minimal`](examples/minimal/main.tf). For AI agents, [`terraform-aws-aedis-agents`](https://github.com/aedis-build/terraform-aws-aedis-agents) creates its own VPC with this module.

## What it builds

| Piece | How | Why |
|---|---|---|
| VPC | IPv4 range of your choice plus an Amazon IPv6 /56, DNS on | dual stack keeps IPv6 egress free |
| Private subnets | one /20 per zone (`azs`, 1 to 3), never a public address | where every workload goes |
| Public subnets | only with egress: one /24 at the top of the range for the NAT instance, or one per zone for NAT gateways | they hold the NAT and nothing else |
| Default security group and network ACL | taken over with **no rules** | anything attached to them by mistake talks to nothing |
| Subnet ACL | allows all; the boundary is the security groups (stateful, empty by default) | ACLs are stateless and would need the whole ephemeral range anyway |
| IPv4 egress (`egress`) | `none`, `nat-instance` (default) or `nat-gateway` | see [Cost](#cost) |
| IPv6 egress | egress-only internet gateway, no cost (off with `egress = "none"`) | outbound only by design |
| Gateway endpoints | S3 and DynamoDB, no cost, with a policy that only reaches this account (plus `s3_external_buckets`, read only) | keep that traffic off the NAT and data inside the account (same region only: other regions go through the NAT) |
| Flow logs | all traffic, to a private S3 bucket (TLS only, SSE-S3, versioned, `logs_retention_days`) | who talked to which address, and a deleted log stays recoverable |
| DNS query logs | every query of the VPC, same bucket | which names each workload resolved |
| DNS Firewall | `blocked_domains` and the AWS managed lists you name answer NXDOMAIN; **fails closed** | a workload cannot resolve what it must never reach |
| `cloudflared` group | no inbound; outbound only 7844 TCP/UDP and 443 TCP, plus the workloads behind it | the connector of the tunnel |
| `from_cloudflared` group | inbound only from the `cloudflared` group | attach it to every workload reached through the tunnel |
| Private zone | optional (`private_zone`) | names for WARP clients, see below |

### NAT instance

An Amazon Linux 2023 `t4g.nano` with IMDSv2 required, an encrypted disk and no key pair. It forwards and masquerades
only what comes from the VPC range (nftables, forward policy drop), accepts no connection itself (input policy drop)
and installs its security updates every day (`dnf-automatic`, with the release set to `latest` so updates are not
locked to the AMI's release). Kernel updates take effect only after a reboot of the instance. It is a single instance: while it is stopped, the private subnets have no IPv4 egress. Move to
`egress = "nat-gateway"` when that matters.

### DNS Firewall

The firewall answers `NXDOMAIN` for each domain of `blocked_domains` (list the apex and `*.` the subdomains) and of
each managed list in `managed_domain_list_ids`. Managed list IDs differ per region:

```bash
aws route53resolver list-firewall-domain-lists \
  --query "FirewallDomainLists[?ManagedOwnerName=='Route 53 Resolver DNS Firewall'].[Name,Id]" --output text
```

It fails closed: if the firewall cannot evaluate a query, the query is refused. It is a block list and filters names,
not addresses: a process that connects to an IP literal or resolves through DNS-over-HTTPS is not stopped by it. Treat it
as a guard for well-behaved software and a record of intent; the security groups (and, for hostile code, an egress
proxy with an allow list) are the real boundary.

## Zero Trust

The VPC opens no inbound path. People reach workloads through Cloudflare:

```
person (WARP + Access) → Cloudflare → cloudflared (tunnel, outbound only) → workload in a private subnet
```

- Run `cloudflared` on an instance of its own with `cloudflared_security_group_id`, and attach
  `from_cloudflared_security_group_id` to the workloads it serves. Never give that group to a host that runs untrusted
  code or content (an agents host): anything on it would reach every workload behind the tunnel without Access.
- Public hostnames of the tunnel, each behind an Access application, need no private DNS.
- For private network routing (WARP clients reaching `10.x` addresses), route `cidr` (output) through the tunnel. To
  give those clients names, set `private_zone` and point a Local Domain Fallback entry for it at `resolver_ip`
  (output): the query travels through the tunnel and the VPC resolver answers it from inside the VPC. Avoid a Route 53
  Resolver inbound endpoint for this: two ENIs cost about USD 180/month.

## Cost

Monthly, us-east-1, before traffic:

| Choice | Cost |
|---|---|
| VPC, subnets, gateways, endpoints, security groups, DNS Firewall rule group | USD 0 |
| `egress = "none"` | USD 0 |
| `egress = "nat-instance"` (t4g.nano, 8 GB gp3, public IPv4) | about USD 7 |
| `egress = "nat-gateway"` | about USD 37 per zone plus USD 0.045 per GB processed |
| Flow logs and DNS query logs to S3 | cents at small volume (delivery and storage) |
| DNS Firewall | per million queries; cents at small volume |
| Private zone | USD 0.50 |

## Out of the module

| What | Who owns it |
|---|---|
| The Cloudflare tunnel, its routes and the Access applications | the Cloudflare side (dashboard or the Aedis Cloudflare module) |
| The workloads, their instances and their own security groups | the caller (for example `terraform-aws-aedis-agents`) |
| Account-wide controls (CloudTrail, EBS encryption by default, GuardDuty, budgets) | the account baseline |
