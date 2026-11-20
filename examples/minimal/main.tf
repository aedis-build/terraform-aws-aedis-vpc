# The smallest network: the defaults (10.20.0.0/16, two zones, one NAT instance at about USD 7/month, 90 days of
# logs). For AI agents, use terraform-aws-aedis-agents instead: it creates its own VPC with this module and the
# blocked domains agents need.
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

  name = "example"
}

output "network" {
  value = module.network
}
