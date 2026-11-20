# Every option of the module, on a fictitious production network: three zones, a NAT gateway per zone, the AWS managed
# threat lists blocked, a vendor's domains blocked and a private zone for the WARP clients. The comments say what the
# cheaper choice is.
terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.73.0"
    }
  }
}

# Credentials from the environment (AWS_PROFILE or SSO); never a profile in code.
provider "aws" {
  region = "us-east-1"
}

module "network" {
  # Outside this repository: source = "aedis-build/aedis-vpc/aws" and version = "<exact release, e.g. 1.0.0>".
  source = "../.."

  name = "example-prod"
  cidr = "10.40.0.0/16"
  azs  = 3

  # nat-gateway: about USD 37/month per zone. nat-instance (the default): one t4g.nano, about USD 7/month in all.
  egress = "nat-gateway"

  logs_retention_days = 365

  blocked_domains = ["vendor.example", "*.vendor.example"]

  # aws route53resolver list-firewall-domain-lists --query "FirewallDomainLists[?ManagedOwnerName=='Route 53 Resolver DNS Firewall']"
  managed_domain_list_ids = ["rslvr-fdl-0123456789abcdef"]

  private_zone = "int.example.com"

  tags = { project = "example" }
}

output "network" {
  value = module.network
}
