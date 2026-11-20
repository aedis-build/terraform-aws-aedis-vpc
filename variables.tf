variable "name" {
  description = "Name of the network: prefix of every resource and of the logs bucket (lowercase letters, digits and hyphens)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$", var.name))
    error_message = "name must have 3 to 32 lowercase letters, digits or hyphens, starting and ending with a letter or digit."
  }
}

variable "cidr" {
  description = "IPv4 range of the VPC. Each private subnet takes a /20 of it; each public subnet (only with egress) a /24 at the top. Keep it apart from 172.26.0.0/16 (Lightsail) and from the ranges your Cloudflare private network already routes."
  type        = string
  default     = "10.20.0.0/16"

  validation {
    condition     = can(cidrhost(var.cidr, 0)) && tonumber(split("/", var.cidr)[1]) <= 18
    error_message = "cidr must be a valid IPv4 range of /18 or larger."
  }
}

variable "azs" {
  description = "Number of availability zones (1 to 3). Each one gets a private subnet; with egress = \"nat-gateway\" each also gets its own NAT gateway."
  type        = number
  default     = 2

  validation {
    condition     = var.azs >= 1 && var.azs <= 3
    error_message = "azs must be 1, 2 or 3."
  }
}

variable "egress" {
  description = <<-EOT
    How the private subnets reach the internet over IPv4. IPv6 always leaves through an egress-only internet gateway
    (no cost) unless egress is none.
    - none: no internet at all; only the S3 and DynamoDB gateway endpoints.
    - nat-instance: one NAT instance (nat_instance_type) in one public subnet, about USD 7/month with its public IPv4.
      A single instance: when it stops, every private subnet loses IPv4 egress.
    - nat-gateway: one managed NAT gateway per zone, about USD 37/month each before data processing.
  EOT
  type        = string
  default     = "nat-instance"

  validation {
    condition     = contains(["none", "nat-instance", "nat-gateway"], var.egress)
    error_message = "egress must be none, nat-instance or nat-gateway."
  }
}

variable "nat_instance_type" {
  description = "Instance type of the NAT instance (arm64, Graviton)."
  type        = string
  default     = "t4g.nano"
}

variable "logs_retention_days" {
  description = "Days the logs bucket keeps VPC flow logs and DNS query logs."
  type        = number
  default     = 90

  validation {
    condition     = var.logs_retention_days >= 1
    error_message = "logs_retention_days must be at least 1."
  }
}

variable "blocked_domains" {
  description = "Domains the DNS Firewall answers with NXDOMAIN for every resource in the VPC. A leading \"*.\" blocks the subdomains (list the apex too). Example: the control plane of a vendor that must never be reached."
  type        = list(string)
  default     = []
}

variable "managed_domain_list_ids" {
  description = "IDs (rslvr-fdl-...) of AWS managed domain lists to block, e.g. AWSManagedDomainsAggregateThreatList. They differ per region: aws route53resolver list-firewall-domain-lists --query \"FirewallDomainLists[?ManagedOwnerName=='Route 53 Resolver DNS Firewall']\"."
  type        = list(string)
  default     = []
}

variable "s3_external_buckets" {
  description = "Buckets of other accounts the private subnets may read through the S3 gateway endpoint (names). Every other S3 request through it must target this account, which also blocks AWS-owned buckets future workloads may need: ECR image layers, SSM Agent updates, Amazon Linux repositories."
  type        = list(string)
  default     = []
}

variable "private_zone" {
  description = "Name of a Route 53 private hosted zone attached to the VPC (e.g. int.example.com), or null for none. WARP clients resolve it through Local Domain Fallback pointed at resolver_ip (output)."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags added to every resource."
  type        = map(string)
  default     = {}
}
