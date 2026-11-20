# Plan of the module with no credentials and no network: the provider is mocked.
mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = { names = ["us-east-1a", "us-east-1b", "us-east-1c", "us-east-1d"] }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-1" }
  }
  mock_data "aws_ssm_parameter" {
    defaults = { insecure_value = "ami-0123456789abcdef0" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{}" }
  }
  mock_resource "aws_vpc" {
    defaults = {
      ipv6_cidr_block        = "2600:1f18:abcd:1200::/56"
      default_network_acl_id = "acl-0123456789abcdef0"
    }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::lab-network-logs-123456789012" }
  }
}

variables {
  name = "lab"
}

run "default_is_private_with_one_nat_instance" {
  command = plan

  assert {
    condition     = [for s in aws_subnet.private : s.cidr_block] == ["10.20.0.0/20", "10.20.16.0/20"]
    error_message = "two private /20 at the bottom of the range, one per zone"
  }
  assert {
    condition     = alltrue([for s in aws_subnet.private : !s.map_public_ip_on_launch])
    error_message = "private subnets never hand out public addresses"
  }
  assert {
    condition     = length(aws_subnet.public) == 1 && aws_subnet.public[0].cidr_block == "10.20.255.0/24" && !aws_subnet.public[0].map_public_ip_on_launch
    error_message = "nat-instance needs a single public /24 at the top of the range, with no automatic public addresses"
  }
  assert {
    condition     = length(aws_instance.nat) == 1 && aws_instance.nat[0].metadata_options[0].http_tokens == "required" && aws_instance.nat[0].root_block_device[0].encrypted && !aws_instance.nat[0].source_dest_check
    error_message = "the NAT instance requires IMDSv2, encrypts its disk and forwards traffic"
  }
  assert {
    condition     = length(aws_route.private_nat_instance) == 2 && length(aws_nat_gateway.this) == 0
    error_message = "every private route table goes through the NAT instance; no NAT gateway"
  }
  assert {
    condition     = length(aws_route.private_ipv6) == 2 && length(aws_egress_only_internet_gateway.this) == 1
    error_message = "IPv6 leaves through the egress-only gateway"
  }
  assert {
    condition     = aws_route53_resolver_firewall_config.this.firewall_fail_open == "DISABLED"
    error_message = "the DNS Firewall fails closed"
  }
  assert {
    condition     = length(aws_route53_resolver_firewall_rule.blocked) == 0 && length(aws_route53_resolver_firewall_domain_list.blocked) == 0
    error_message = "no blocked list when no domain is given"
  }
  assert {
    condition     = aws_flow_log.this.traffic_type == "ALL" && aws_flow_log.this.log_destination_type == "s3"
    error_message = "flow logs record all traffic in the logs bucket"
  }
  assert {
    condition     = aws_s3_bucket_public_access_block.logs.restrict_public_buckets && aws_s3_bucket.logs.bucket == "lab-network-logs-123456789012"
    error_message = "the logs bucket is private and named after the network and the account"
  }
  assert {
    condition     = length(aws_vpc_security_group_egress_rule.cloudflared) == 6
    error_message = "cloudflared leaves only on 7844 TCP/UDP and 443 TCP, IPv4 and IPv6"
  }
  assert {
    condition     = aws_s3_bucket_versioning.logs.versioning_configuration[0].status == "Enabled"
    error_message = "the logs bucket keeps versions, so a deleted log stays recoverable"
  }
  assert {
    condition     = length(aws_vpc_endpoint.gateway) == 2 && anytrue([for c in data.aws_iam_policy_document.endpoint["s3"].statement[0].condition : c.variable == "aws:ResourceAccount"])
    error_message = "the gateway endpoints only reach this account's buckets and tables"
  }
  assert {
    condition     = output.resolver_ip == "10.20.0.2"
    error_message = "the VPC resolver is the base address plus two"
  }
}

run "none_is_isolated" {
  command = plan

  variables {
    egress = "none"
  }

  assert {
    condition     = length(aws_internet_gateway.this) + length(aws_egress_only_internet_gateway.this) + length(aws_subnet.public) + length(aws_instance.nat) == 0
    error_message = "with egress none there is no gateway, no public subnet and no NAT"
  }
  assert {
    condition     = length(aws_route.private_ipv6) + length(aws_route.private_nat_instance) + length(aws_route.private_nat_gateway) == 0
    error_message = "with egress none the private route tables have no default route"
  }
  assert {
    condition     = length(aws_vpc_endpoint.gateway) == 2
    error_message = "S3 and DynamoDB stay reachable through the gateway endpoints"
  }
}

run "nat_gateway_per_zone" {
  command = plan

  variables {
    egress = "nat-gateway"
    azs    = 3
    cidr   = "10.30.0.0/18"
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 3 && length(aws_instance.nat) == 0
    error_message = "one NAT gateway per zone, no NAT instance"
  }
  assert {
    condition     = [for s in aws_subnet.public : s.cidr_block] == ["10.30.63.0/24", "10.30.62.0/24", "10.30.61.0/24"]
    error_message = "public /24s are taken from the top of the range, apart from the private /20s"
  }
  assert {
    condition     = [for s in aws_subnet.private : s.cidr_block] == ["10.30.0.0/20", "10.30.16.0/20", "10.30.32.0/20"]
    error_message = "three private /20s at the bottom of an /18"
  }
}

run "blocked_domains" {
  command = plan

  variables {
    blocked_domains         = ["openbot.run", "*.openbot.run"]
    managed_domain_list_ids = ["rslvr-fdl-0123456789abcdef"]
  }

  assert {
    condition     = aws_route53_resolver_firewall_domain_list.blocked[0].domains == toset(["openbot.run", "*.openbot.run"])
    error_message = "the given domains form the blocked list"
  }
  assert {
    condition     = aws_route53_resolver_firewall_rule.blocked[0].action == "BLOCK" && aws_route53_resolver_firewall_rule.blocked[0].block_response == "NXDOMAIN"
    error_message = "blocked domains answer NXDOMAIN"
  }
  assert {
    condition     = length(aws_route53_resolver_firewall_rule.managed) == 1 && aws_route53_resolver_firewall_rule.managed[0].priority == 200
    error_message = "each managed list becomes a blocking rule after the custom one"
  }
}

run "private_zone" {
  command = plan

  variables {
    private_zone = "int.example.com"
  }

  assert {
    condition     = aws_route53_zone.private[0].name == "int.example.com"
    error_message = "the private zone is created when named"
  }
}

run "rejects_unknown_egress" {
  command = plan

  variables {
    egress = "internet-gateway"
  }

  expect_failures = [var.egress]
}

run "rejects_small_range" {
  command = plan

  variables {
    cidr = "10.20.0.0/24"
  }

  expect_failures = [var.cidr]
}
