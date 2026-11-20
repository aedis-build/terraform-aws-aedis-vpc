data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

locals {
  azs     = slice(data.aws_availability_zones.available.names, 0, var.azs)
  prefix  = tonumber(split("/", var.cidr)[1])
  publics = { none = 0, nat-instance = 1, nat-gateway = var.azs }[var.egress]
  online  = var.egress != "none"
  tags    = merge(var.tags, { "aedis:network" = var.name })
}

# --- VPC, closed by default ---------------------------------------------------------------------------------------

resource "aws_vpc" "this" {
  cidr_block                       = var.cidr
  assign_generated_ipv6_cidr_block = true
  enable_dns_support               = true
  enable_dns_hostnames             = true

  tags = merge(local.tags, { Name = var.name })
}

# The default security group and network ACL of every VPC allow traffic; the module takes them over with no rules, so
# nothing that lands on them by accident talks to anything.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.name}-default-closed" })
}

resource "aws_default_network_acl" "this" {
  default_network_acl_id = aws_vpc.this.default_network_acl_id
  tags                   = merge(local.tags, { Name = "${var.name}-default-closed" })

  lifecycle {
    ignore_changes = [subnet_ids]
  }
}

# The subnets use their own ACL. ACLs are stateless, so return traffic would need the whole ephemeral range anyway:
# the boundary is the security groups, which are stateful and start with nothing allowed.
resource "aws_network_acl" "this" {
  vpc_id     = aws_vpc.this.id
  subnet_ids = concat(aws_subnet.private[*].id, aws_subnet.public[*].id)
  tags       = merge(local.tags, { Name = var.name })

  ingress {
    rule_no    = 100
    action     = "allow"
    protocol   = "-1"
    from_port  = 0
    to_port    = 0
    cidr_block = "0.0.0.0/0"
  }
  ingress {
    rule_no         = 101
    action          = "allow"
    protocol        = "-1"
    from_port       = 0
    to_port         = 0
    ipv6_cidr_block = "::/0"
  }
  egress {
    rule_no    = 100
    action     = "allow"
    protocol   = "-1"
    from_port  = 0
    to_port    = 0
    cidr_block = "0.0.0.0/0"
  }
  egress {
    rule_no         = 101
    action          = "allow"
    protocol        = "-1"
    from_port       = 0
    to_port         = 0
    ipv6_cidr_block = "::/0"
  }
}

resource "aws_subnet" "private" {
  count = var.azs

  vpc_id                                         = aws_vpc.this.id
  availability_zone                              = local.azs[count.index]
  cidr_block                                     = cidrsubnet(var.cidr, 20 - local.prefix, count.index)
  ipv6_cidr_block                                = cidrsubnet(aws_vpc.this.ipv6_cidr_block, 8, count.index)
  assign_ipv6_address_on_creation                = true
  map_public_ip_on_launch                        = false
  enable_resource_name_dns_a_record_on_launch    = true
  enable_resource_name_dns_aaaa_record_on_launch = true

  tags = merge(local.tags, { Name = "${var.name}-private-${local.azs[count.index]}", "aedis:tier" = "private" })
}

# Public subnets exist only to hold the NAT: nothing else is meant to run there.
resource "aws_subnet" "public" {
  count = local.publics

  vpc_id                          = aws_vpc.this.id
  availability_zone               = local.azs[count.index]
  cidr_block                      = cidrsubnet(var.cidr, 24 - local.prefix, pow(2, 24 - local.prefix) - 1 - count.index)
  ipv6_cidr_block                 = cidrsubnet(aws_vpc.this.ipv6_cidr_block, 8, 128 + count.index)
  assign_ipv6_address_on_creation = false
  map_public_ip_on_launch         = false

  tags = merge(local.tags, { Name = "${var.name}-public-${local.azs[count.index]}", "aedis:tier" = "public" })
}

# --- Egress ----------------------------------------------------------------------------------------------------------

resource "aws_internet_gateway" "this" {
  count  = local.online ? 1 : 0
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = var.name })
}

resource "aws_egress_only_internet_gateway" "this" {
  count  = local.online ? 1 : 0
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = var.name })
}

resource "aws_route_table" "public" {
  count  = local.online ? 1 : 0
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.name}-public" })

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this[0].id
  }
  route {
    ipv6_cidr_block = "::/0"
    gateway_id      = aws_internet_gateway.this[0].id
  }
}

resource "aws_route_table_association" "public" {
  count          = local.publics
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public[0].id
}

resource "aws_route_table" "private" {
  count  = var.azs
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.name}-private-${local.azs[count.index]}" })
}

resource "aws_route_table_association" "private" {
  count          = var.azs
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

resource "aws_route" "private_ipv6" {
  count                       = local.online ? var.azs : 0
  route_table_id              = aws_route_table.private[count.index].id
  destination_ipv6_cidr_block = "::/0"
  egress_only_gateway_id      = aws_egress_only_internet_gateway.this[0].id
}

resource "aws_eip" "nat" {
  count  = var.egress == "nat-gateway" ? var.azs : 0
  domain = "vpc"
  tags   = merge(local.tags, { Name = "${var.name}-nat-${local.azs[count.index]}" })
}

resource "aws_nat_gateway" "this" {
  count         = var.egress == "nat-gateway" ? var.azs : 0
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags          = merge(local.tags, { Name = "${var.name}-${local.azs[count.index]}" })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route" "private_nat_gateway" {
  count                  = var.egress == "nat-gateway" ? var.azs : 0
  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[count.index].id
}

data "aws_ssm_parameter" "al2023_arm64" {
  count = var.egress == "nat-instance" ? 1 : 0
  name  = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

resource "aws_security_group" "nat" {
  count       = var.egress == "nat-instance" ? 1 : 0
  name        = "${var.name}-nat"
  description = "NAT instance: accepts only the VPC range, leaves to the internet."
  vpc_id      = aws_vpc.this.id
  tags        = merge(local.tags, { Name = "${var.name}-nat" })
}

resource "aws_vpc_security_group_ingress_rule" "nat_from_vpc" {
  count             = var.egress == "nat-instance" ? 1 : 0
  security_group_id = aws_security_group.nat[0].id
  description       = "Traffic of the private subnets to translate."
  ip_protocol       = "-1"
  cidr_ipv4         = var.cidr
}

resource "aws_vpc_security_group_egress_rule" "nat_out" {
  count             = var.egress == "nat-instance" ? 1 : 0
  security_group_id = aws_security_group.nat[0].id
  description       = "Translated traffic to the internet (filtered upstream by the workloads' own groups)."
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_instance" "nat" {
  count = var.egress == "nat-instance" ? 1 : 0

  ami                         = data.aws_ssm_parameter.al2023_arm64[0].insecure_value
  instance_type               = var.nat_instance_type
  subnet_id                   = aws_subnet.public[0].id
  vpc_security_group_ids      = [aws_security_group.nat[0].id]
  associate_public_ip_address = true
  source_dest_check           = false
  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/templates/nat-instance.sh", {
    vpc_cidr = var.cidr
  })

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  root_block_device {
    encrypted   = true
    volume_type = "gp3"
    volume_size = 8
  }

  tags = merge(local.tags, { Name = "${var.name}-nat" })

  lifecycle {
    # A newer AMI must not replace the NAT by surprise: it updates itself with dnf-automatic.
    ignore_changes = [ami]
  }
}

resource "aws_route" "private_nat_instance" {
  count                  = var.egress == "nat-instance" ? var.azs : 0
  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.nat[0].primary_network_interface_id
}

# Gateway endpoints cost nothing and keep S3 and DynamoDB traffic off the NAT. Their policy keeps that traffic in this
# account: a workload holding someone else's credentials cannot copy data to a bucket or table of another account
# through them. The endpoint carries only this region's S3: a bucket in another region goes through the NAT instead.
data "aws_iam_policy_document" "endpoint" {
  for_each = toset(["s3", "dynamodb"])

  statement {
    sid       = "OwnAccountOnly"
    actions   = ["${each.key}:*"]
    resources = ["*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  dynamic "statement" {
    for_each = each.key == "s3" && length(var.s3_external_buckets) > 0 ? [1] : []

    content {
      sid       = "ExternalBuckets"
      actions   = ["s3:GetObject", "s3:ListBucket"]
      resources = flatten([for b in var.s3_external_buckets : ["arn:aws:s3:::${b}", "arn:aws:s3:::${b}/*"]])

      principals {
        type        = "*"
        identifiers = ["*"]
      }
    }
  }
}

resource "aws_vpc_endpoint" "gateway" {
  for_each = toset(["s3", "dynamodb"])

  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.${each.key}"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id
  policy            = data.aws_iam_policy_document.endpoint[each.key].json
  tags              = merge(local.tags, { Name = "${var.name}-${each.key}" })
}

# --- Logs: flow logs and DNS queries, in one private bucket ----------------------------------------------------------

resource "aws_s3_bucket" "logs" {
  bucket = "${var.name}-network-logs-${data.aws_caller_identity.current.account_id}"
  tags   = local.tags
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket                  = aws_s3_bucket.logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Versioning keeps a deleted or overwritten log recoverable for the retention period.
resource "aws_s3_bucket_versioning" "logs" {
  bucket = aws_s3_bucket.logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    id     = "expire"
    status = "Enabled"
    filter {}

    expiration {
      days = var.logs_retention_days
    }
    noncurrent_version_expiration {
      noncurrent_days = var.logs_retention_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.logs]
}

data "aws_iam_policy_document" "logs" {
  statement {
    sid       = "TlsOnly"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.logs.arn, "${aws_s3_bucket.logs.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid       = "LogDeliveryWrite"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.logs.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  statement {
    sid       = "LogDeliveryCheck"
    actions   = ["s3:GetBucketAcl", "s3:ListBucket"]
    resources = [aws_s3_bucket.logs.arn]

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_s3_bucket_policy" "logs" {
  bucket = aws_s3_bucket.logs.id
  policy = data.aws_iam_policy_document.logs.json

  depends_on = [aws_s3_bucket_public_access_block.logs]
}

resource "aws_flow_log" "this" {
  vpc_id               = aws_vpc.this.id
  traffic_type         = "ALL"
  log_destination_type = "s3"
  log_destination      = aws_s3_bucket.logs.arn
  tags                 = merge(local.tags, { Name = var.name })

  depends_on = [aws_s3_bucket_policy.logs]
}

resource "aws_route53_resolver_query_log_config" "this" {
  name            = var.name
  destination_arn = aws_s3_bucket.logs.arn
  tags            = local.tags

  depends_on = [aws_s3_bucket_policy.logs]
}

resource "aws_route53_resolver_query_log_config_association" "this" {
  resolver_query_log_config_id = aws_route53_resolver_query_log_config.this.id
  resource_id                  = aws_vpc.this.id
}

# --- DNS Firewall ----------------------------------------------------------------------------------------------------

resource "aws_route53_resolver_firewall_domain_list" "blocked" {
  count   = length(var.blocked_domains) > 0 ? 1 : 0
  name    = "${var.name}-blocked"
  domains = var.blocked_domains
  tags    = local.tags
}

resource "aws_route53_resolver_firewall_rule_group" "this" {
  name = var.name
  tags = local.tags
}

resource "aws_route53_resolver_firewall_rule" "blocked" {
  count                   = length(var.blocked_domains) > 0 ? 1 : 0
  name                    = "${var.name}-blocked"
  firewall_rule_group_id  = aws_route53_resolver_firewall_rule_group.this.id
  firewall_domain_list_id = aws_route53_resolver_firewall_domain_list.blocked[0].id
  priority                = 100
  action                  = "BLOCK"
  block_response          = "NXDOMAIN"
}

resource "aws_route53_resolver_firewall_rule" "managed" {
  count                   = length(var.managed_domain_list_ids)
  name                    = "${var.name}-managed-${count.index}"
  firewall_rule_group_id  = aws_route53_resolver_firewall_rule_group.this.id
  firewall_domain_list_id = var.managed_domain_list_ids[count.index]
  priority                = 200 + count.index
  action                  = "BLOCK"
  block_response          = "NXDOMAIN"
}

resource "aws_route53_resolver_firewall_rule_group_association" "this" {
  name                   = var.name
  firewall_rule_group_id = aws_route53_resolver_firewall_rule_group.this.id
  vpc_id                 = aws_vpc.this.id
  priority               = 101
  tags                   = local.tags
}

# Fail closed: when the firewall cannot answer, queries are refused instead of going through unfiltered.
resource "aws_route53_resolver_firewall_config" "this" {
  resource_id        = aws_vpc.this.id
  firewall_fail_open = "DISABLED"
}

# --- Zero Trust: the cloudflared connector and what it may reach -----------------------------------------------------

resource "aws_security_group" "cloudflared" {
  name        = "${var.name}-cloudflared"
  description = "cloudflared connector: no inbound, outbound only to the Cloudflare edge."
  vpc_id      = aws_vpc.this.id
  tags        = merge(local.tags, { Name = "${var.name}-cloudflared" })
}

# Tunnel connections use 7844 (TCP and UDP/QUIC); 443 reaches the Cloudflare API and the software updates.
resource "aws_vpc_security_group_egress_rule" "cloudflared" {
  for_each = {
    for r in setproduct(["0.0.0.0/0", "::/0"], [["tcp", 7844], ["udp", 7844], ["tcp", 443]]) :
    "${r[1][0]}-${r[1][1]}-${r[0]}" => { cidr = r[0], protocol = r[1][0], port = r[1][1] }
  }

  security_group_id = aws_security_group.cloudflared.id
  description       = "Cloudflare edge"
  ip_protocol       = each.value.protocol
  from_port         = each.value.port
  to_port           = each.value.port
  cidr_ipv4         = strcontains(each.value.cidr, ":") ? null : each.value.cidr
  cidr_ipv6         = strcontains(each.value.cidr, ":") ? each.value.cidr : null
}

resource "aws_security_group" "from_cloudflared" {
  name        = "${var.name}-from-cloudflared"
  description = "Workloads reached through the tunnel: inbound only from the cloudflared connector."
  vpc_id      = aws_vpc.this.id
  tags        = merge(local.tags, { Name = "${var.name}-from-cloudflared" })
}

resource "aws_vpc_security_group_ingress_rule" "from_cloudflared" {
  security_group_id            = aws_security_group.from_cloudflared.id
  description                  = "cloudflared connector"
  ip_protocol                  = "-1"
  referenced_security_group_id = aws_security_group.cloudflared.id
}

resource "aws_vpc_security_group_egress_rule" "cloudflared_to_workloads" {
  security_group_id            = aws_security_group.cloudflared.id
  description                  = "Workloads behind the tunnel"
  ip_protocol                  = "-1"
  referenced_security_group_id = aws_security_group.from_cloudflared.id
}

resource "aws_route53_zone" "private" {
  count = var.private_zone == null ? 0 : 1
  name  = var.private_zone
  tags  = local.tags

  vpc {
    vpc_id = aws_vpc.this.id
  }
}
