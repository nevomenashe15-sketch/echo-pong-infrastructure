# =============================================================================
# VPC
# =============================================================================
# Layout, /16 split into /20s so there is room for growth without renumbering:
#   public  : one /20 per AZ, ALBs + NAT Gateways only. No workloads.
#   private : one /20 per AZ, EKS nodes and pods. No route to an IGW.
#
# There is no dedicated "intra"/database tier: the app is stateless and has no
# RDS/ElastiCache dependency. Adding an unused third tier now would be three
# more route tables to review for no benefit.
# =============================================================================

locals {
  az_count = length(var.azs)

  # Deterministic, index-based subnetting. cidrsubnet(<vpc /16>, 4, n) yields
  # /20s: n = 0..(az_count-1) public, n = 8.. private. The gap keeps the two
  # classes visually distinct in the console and route tables.
  public_subnet_cidrs  = [for i in range(local.az_count) : cidrsubnet(var.vpc_cidr, 4, i)]
  private_subnet_cidrs = [for i in range(local.az_count) : cidrsubnet(var.vpc_cidr, 4, i + 8)]

  nat_gateway_count = var.single_nat_gateway ? 1 : local.az_count
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true # required for VPC interface endpoints' private DNS

  tags = merge(var.tags, { Name = var.name_prefix })
}

# Explicitly strip the default security group down to nothing. AWS creates it
# with an allow-all-from-self rule and it cannot be deleted; leaving it
# permissive is a standing finding in every CIS benchmark.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name_prefix}-default-DO-NOT-USE" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = var.name_prefix })
}

# -----------------------------------------------------------------------------
# Subnets
# -----------------------------------------------------------------------------
resource "aws_subnet" "public" {
  count = local.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.public_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  # Nothing in a public subnet should get an automatic public IP. The only
  # things placed here are ALBs (which get their own EIPs via the service) and
  # NAT Gateways (explicit EIP association below).
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name                                        = "${var.name_prefix}-public-${var.azs[count.index]}"
    Tier                                        = "public"
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  })
}

resource "aws_subnet" "private" {
  count = local.az_count

  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.private_subnet_cidrs[count.index]
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name                                        = "${var.name_prefix}-private-${var.azs[count.index]}"
    Tier                                        = "private"
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    # Karpenter discovers which subnets it may launch nodes into via this tag.
    # The matching EC2NodeClass selector lives in echo-pong-gitops.
    "karpenter.sh/discovery" = var.cluster_name
  })
}

# -----------------------------------------------------------------------------
# NAT
# -----------------------------------------------------------------------------
# DECISION (see docs/architecture.md): prod runs one NAT Gateway per AZ so that
# losing an AZ does not take egress away from the surviving AZs. dev runs a
# single NAT Gateway: it is ~USD 32/month cheaper per removed gateway and dev
# has no availability SLO. The tradeoff in dev is that an AZ failure in the AZ
# holding the NAT Gateway removes ALL private-subnet egress, including image
# pulls, until the gateway is recreated.
resource "aws_eip" "nat" {
  count      = local.nat_gateway_count
  domain     = "vpc"
  depends_on = [aws_internet_gateway.this]

  tags = merge(var.tags, { Name = "${var.name_prefix}-nat-${count.index}" })
}

resource "aws_nat_gateway" "this" {
  count = local.nat_gateway_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  depends_on    = [aws_internet_gateway.this]

  tags = merge(var.tags, { Name = "${var.name_prefix}-nat-${count.index}" })
}

# -----------------------------------------------------------------------------
# Route tables -- one per subnet class per AZ
# -----------------------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name_prefix}-public" })
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count = local.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# One private route table per AZ even when single_nat_gateway = true, so that
# flipping the flag is a route change rather than a subnet re-association.
resource "aws_route_table" "private" {
  count = local.az_count

  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name_prefix}-private-${var.azs[count.index]}" })
}

resource "aws_route" "private_default" {
  count = local.az_count

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[var.single_nat_gateway ? 0 : count.index].id
}

resource "aws_route_table_association" "private" {
  count = local.az_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# -----------------------------------------------------------------------------
# VPC endpoints
# -----------------------------------------------------------------------------
# WHY BOTH ECR INTERFACE ENDPOINTS *AND* THE S3 GATEWAY ENDPOINT:
# An `ecr:GetAuthorizationToken` + `BatchGetImage` call goes to the ECR API
# (com.amazonaws.<region>.ecr.api) and the layer download is negotiated through
# com.amazonaws.<region>.ecr.dkr -- but ECR then returns a presigned *S3* URL
# and the container runtime fetches the actual layer blobs from S3. Without the
# S3 gateway endpoint the layer pull falls back to the NAT Gateway, so you pay
# NAT data-processing on every image byte and the endpoints buy you nothing.
# Both are required; neither is sufficient alone.
resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.name_prefix}-vpce"
  description = "Ingress to interface VPC endpoints from inside the VPC"
  vpc_id      = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpce" })
}

resource "aws_vpc_security_group_ingress_rule" "vpc_endpoints_https" {
  security_group_id = aws_security_group.vpc_endpoints.id
  description       = "HTTPS from anywhere inside this VPC"
  cidr_ipv4         = aws_vpc.this.cidr_block
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

# Endpoints are AWS-managed ENIs; they initiate nothing. The egress rule exists
# only because a security group with no egress rule blocks return traffic in
# some edge cases and scanners flag the empty group.
resource "aws_vpc_security_group_egress_rule" "vpc_endpoints_all" {
  security_group_id = aws_security_group.vpc_endpoints.id
  description       = "Endpoint ENI responses back into the VPC"
  cidr_ipv4         = aws_vpc.this.cidr_block
  ip_protocol       = "-1"
}

data "aws_region" "current" {}

locals {
  interface_endpoints = {
    "ecr.api"              = "com.amazonaws.${data.aws_region.current.name}.ecr.api"
    "ecr.dkr"              = "com.amazonaws.${data.aws_region.current.name}.ecr.dkr"
    "sts"                  = "com.amazonaws.${data.aws_region.current.name}.sts"
    "secretsmanager"       = "com.amazonaws.${data.aws_region.current.name}.secretsmanager"
    "logs"                 = "com.amazonaws.${data.aws_region.current.name}.logs"
    "eks-auth"             = "com.amazonaws.${data.aws_region.current.name}.eks-auth"
    "ec2"                  = "com.amazonaws.${data.aws_region.current.name}.ec2"
    "elasticloadbalancing" = "com.amazonaws.${data.aws_region.current.name}.elasticloadbalancing"
  }
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoints

  vpc_id              = aws_vpc.this.id
  service_name        = each.value
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-${each.key}" })
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = merge(var.tags, { Name = "${var.name_prefix}-s3" })
}

# -----------------------------------------------------------------------------
# Flow logs
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name              = "/aws/vpc/${var.name_prefix}/flow-logs"
  retention_in_days = var.flow_log_retention_days
  kms_key_id        = var.kms_key_arn

  tags = var.tags
}

data "aws_iam_policy_document" "flow_logs_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name               = "${var.name_prefix}-vpc-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.flow_logs[0].arn}:*"]
  }
}

resource "aws_iam_role_policy" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name   = "write-flow-logs"
  role   = aws_iam_role.flow_logs[0].id
  policy = data.aws_iam_policy_document.flow_logs[0].json
}

resource "aws_flow_log" "this" {
  count = var.enable_flow_logs ? 1 : 0

  vpc_id                   = aws_vpc.this.id
  traffic_type             = var.flow_log_traffic_type
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.flow_logs[0].arn
  iam_role_arn             = aws_iam_role.flow_logs[0].arn
  max_aggregation_interval = 60

  tags = merge(var.tags, { Name = var.name_prefix })
}
