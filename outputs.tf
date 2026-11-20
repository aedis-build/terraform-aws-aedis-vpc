output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "cidr" {
  description = "IPv4 range of the VPC: the private network route of the Cloudflare tunnel."
  value       = aws_vpc.this.cidr_block
}

output "ipv6_cidr" {
  description = "IPv6 range Amazon assigned to the VPC."
  value       = aws_vpc.this.ipv6_cidr_block
}

output "availability_zones" {
  description = "Zones of the private subnets, in the same order as private_subnet_ids."
  value       = local.azs
}

output "private_subnet_ids" {
  description = "Private subnets, one per zone, in zone order. Workloads go here."
  value       = aws_subnet.private[*].id
}

output "cloudflared_security_group_id" {
  description = "Group for the cloudflared connector: outbound to the Cloudflare edge and to the workloads behind the tunnel."
  value       = aws_security_group.cloudflared.id
}

output "from_cloudflared_security_group_id" {
  description = "Group for workloads reached through the tunnel: inbound only from the connector."
  value       = aws_security_group.from_cloudflared.id
}

output "resolver_ip" {
  description = "Address of the VPC resolver (base + 2): the Local Domain Fallback target for private_zone."
  value       = cidrhost(aws_vpc.this.cidr_block, 2)
}

output "private_zone_id" {
  description = "ID of the private hosted zone, or null."
  value       = one(aws_route53_zone.private[*].zone_id)
}

output "logs_bucket" {
  description = "Bucket with the VPC flow logs and DNS query logs."
  value       = aws_s3_bucket.logs.id
}
