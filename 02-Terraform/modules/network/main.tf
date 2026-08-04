# ==============================================================================
# Network Module — VPC, Subnets, IGW, NAT, Route Tables, NACLs, Flow Logs
# ==============================================================================
#
#   Internet
#      │
#      ▼
#   ┌──────────────────── Internet Gateway ─────────────────────┐
#   │                                                            │
#   │  PUBLIC  10.0.1.0/24 (AZ-a)      10.0.2.0/24 (AZ-b)       │
#   │    · Jenkins EC2 (Elastic IP)                              │
#   │    · NAT Gateway                                           │
#   │    · Internet-facing ALB (created by the Ingress)          │
#   │            │                                               │
#   │            │ NAT (outbound only)                           │
#   │            ▼                                               │
#   │  PRIVATE 10.0.10.0/24 (AZ-a)     10.0.11.0/24 (AZ-b)      │
#   │    · EKS worker node 1            · EKS worker node 2      │
#   │    · No public IP — unreachable from the internet          │
#   └────────────────────────────────────────────────────────────┘
#
# Two layers of network control are applied, and they are NOT redundant:
#
#   Security Groups  attach to ENIs, are STATEFUL (a reply to an allowed
#                    outbound request is automatically permitted), and support
#                    allow rules only.
#   Network ACLs     attach to SUBNETS, are STATELESS (return traffic needs its
#                    own explicit rule), and support both allow and DENY.
#
# NACLs are the coarse subnet-level backstop; Security Groups do the precise
# per-instance filtering. The project brief requires a Network ACL, and defence
# in depth requires both.
# ==============================================================================

# ------------------------------------------------------------------------------
# VPC
# ------------------------------------------------------------------------------
resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr

  # Both are mandatory for EKS. Without DNS support, in-cluster service
  # discovery and the EFS/EBS CSI drivers fail to resolve AWS API endpoints.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-vpc"
  })
}

# ------------------------------------------------------------------------------
# Internet Gateway — the VPC's door to the public internet
# ------------------------------------------------------------------------------
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-igw"
  })
}

# ------------------------------------------------------------------------------
# Public subnets
# ------------------------------------------------------------------------------
resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidrs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.public_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  # Anything launched here (the Jenkins instance) receives a public IPv4
  # address automatically.
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-public-${var.availability_zones[count.index]}"
    Tier = "public"

    # --- EKS / AWS Load Balancer Controller discovery tags ---
    # The controller lists subnets and filters on these tags to decide where to
    # place a load balancer. Omit them and Ingress creation fails with
    # "couldn't auto-discover subnets" — one of the most common EKS Ingress bugs.
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  })
}

# ------------------------------------------------------------------------------
# Private subnets
# ------------------------------------------------------------------------------
resource "aws_subnet" "private" {
  count = length(var.private_subnet_cidrs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  # Explicitly false: worker nodes must not be directly addressable.
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-private-${var.availability_zones[count.index]}"
    Tier = "private"

    # internal-elb marks these subnets as the placement target for INTERNAL
    # (VPC-only) load balancers, the counterpart to role/elb above.
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  })
}

# ------------------------------------------------------------------------------
# NAT Gateway — outbound-only internet access for the private subnets
# ------------------------------------------------------------------------------
# Worker nodes need egress to pull container images from ECR, reach the EKS API,
# and download OS packages — but must never be reachable from the internet.
# A NAT Gateway performs source NAT for outbound flows and drops all
# unsolicited inbound connections.
#
# count: 1 shared gateway, or one per AZ. Per-AZ removes the cross-AZ dependency
# (and the cross-AZ data transfer charge) at roughly $32/month per extra AZ.
# ------------------------------------------------------------------------------
resource "aws_eip" "nat" {
  count = var.single_nat_gateway ? 1 : length(var.public_subnet_cidrs)

  domain = "vpc"

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-nat-eip-${count.index + 1}"
  })

  # The EIP cannot be associated with a NAT Gateway until the IGW exists and is
  # attached, otherwise the apply fails with InvalidGateway.NotAttached.
  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  count = var.single_nat_gateway ? 1 : length(var.public_subnet_cidrs)

  allocation_id = aws_eip.nat[count.index].id

  # A NAT Gateway lives in a PUBLIC subnet — that is what gives it a route to
  # the IGW. Placing it in a private subnet is a common mistake that produces a
  # gateway with no internet path.
  subnet_id = aws_subnet.public[count.index].id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-nat-${count.index + 1}"
  })

  depends_on = [aws_internet_gateway.this]
}

# ------------------------------------------------------------------------------
# Route tables — public
# ------------------------------------------------------------------------------
# One shared table: every public subnet takes the same default route to the IGW.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-public-rt"
  })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ------------------------------------------------------------------------------
# Route tables — private
# ------------------------------------------------------------------------------
# One table PER private subnet, even when sharing a single NAT Gateway. This
# costs nothing and means switching single_nat_gateway to false later only
# changes the route target — no subnet has to be re-associated.
resource "aws_route_table" "private" {
  count = length(var.private_subnet_cidrs)

  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-private-rt-${var.availability_zones[count.index]}"
  })
}

resource "aws_route" "private_nat" {
  count = length(var.private_subnet_cidrs)

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"

  # With a shared gateway every subnet points at NAT #0; otherwise each private
  # subnet uses the NAT Gateway sitting in its own AZ.
  nat_gateway_id = var.single_nat_gateway ? aws_nat_gateway.this[0].id : aws_nat_gateway.this[count.index].id
}

resource "aws_route_table_association" "private" {
  count = length(aws_subnet.private)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ==============================================================================
# Network ACLs
# ==============================================================================
# Reminder: NACLs are STATELESS. Every flow needs a rule in BOTH directions.
# When a client in a public subnet opens a connection, the server's reply
# arrives on an ephemeral port (1024-65535) — so an ephemeral-port ingress rule
# is required even though nothing "listens" on those ports.
#
# Rules are evaluated in ascending rule_no order and the first match wins.
# ==============================================================================

# ------------------------------------------------------------------------------
# Public subnet NACL
# ------------------------------------------------------------------------------
resource "aws_network_acl" "public" {
  vpc_id     = aws_vpc.this.id
  subnet_ids = aws_subnet.public[*].id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-public-nacl"
  })
}

# --- Inbound ---

# HTTP / HTTPS to the internet-facing ALB in front of the frontend service.
resource "aws_network_acl_rule" "public_in_http" {
  network_acl_id = aws_network_acl.public.id
  rule_number    = 100
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 80
  to_port        = 80
}

resource "aws_network_acl_rule" "public_in_https" {
  network_acl_id = aws_network_acl.public.id
  rule_number    = 110
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 443
  to_port        = 443
}

# Return traffic for connections initiated FROM this subnet — the NAT Gateway's
# outbound flows and the Jenkins server's package downloads all come back here.
resource "aws_network_acl_rule" "public_in_ephemeral" {
  network_acl_id = aws_network_acl.public.id
  rule_number    = 120
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 1024
  to_port        = 65535
}

# SSH and the Jenkins UI. Deliberately left at 0.0.0.0/0 at the NACL layer and
# locked down precisely in the Jenkins Security Group instead: a NACL cannot
# express "only my current home IP" without being edited on every IP change,
# whereas the SG can. The SG is the enforcing layer here.
resource "aws_network_acl_rule" "public_in_admin" {
  network_acl_id = aws_network_acl.public.id
  rule_number    = 130
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 22
  to_port        = 22
}

resource "aws_network_acl_rule" "public_in_jenkins" {
  network_acl_id = aws_network_acl.public.id
  rule_number    = 140
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 8080
  to_port        = 9000
}

# --- Outbound ---
# Unrestricted: the ALB must reach worker nodes on arbitrary NodePorts, and the
# NAT Gateway must reach arbitrary internet destinations.
resource "aws_network_acl_rule" "public_out_all" {
  network_acl_id = aws_network_acl.public.id
  rule_number    = 100
  egress         = true
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 0
  to_port        = 0
}

# ------------------------------------------------------------------------------
# Private subnet NACL
# ------------------------------------------------------------------------------
resource "aws_network_acl" "private" {
  vpc_id     = aws_vpc.this.id
  subnet_ids = aws_subnet.private[*].id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-private-nacl"
  })
}

# --- Inbound ---

# All traffic originating inside the VPC: control-plane-to-kubelet (10250),
# pod-to-pod across nodes, ALB health checks, and CoreDNS lookups.
resource "aws_network_acl_rule" "private_in_vpc" {
  network_acl_id = aws_network_acl.private.id
  rule_number    = 100
  egress         = false
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = var.vpc_cidr
  from_port      = 0
  to_port        = 0
}

# Replies to outbound connections made through the NAT Gateway — image pulls
# from ECR, EKS API calls, and OS package downloads.
#
# NOTE this rule is the reason a private NACL cannot simply "deny the internet":
# the responses genuinely arrive from arbitrary public source addresses. What
# keeps the subnet private is the absence of an inbound route, not this rule.
resource "aws_network_acl_rule" "private_in_ephemeral" {
  network_acl_id = aws_network_acl.private.id
  rule_number    = 110
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 1024
  to_port        = 65535
}

# --- Outbound ---
resource "aws_network_acl_rule" "private_out_all" {
  network_acl_id = aws_network_acl.private.id
  rule_number    = 100
  egress         = true
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 0
  to_port        = 0
}

# ==============================================================================
# VPC Flow Logs
# ==============================================================================
# Records metadata for every accepted and rejected flow in the VPC. This is the
# only way to answer "why can't the frontend pod reach the auth service?" after
# the fact — a REJECT entry pinpoints whether a Security Group or a NACL dropped
# the packet, which is otherwise invisible.
# ==============================================================================

resource "aws_cloudwatch_log_group" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name              = "/aws/vpc/${var.name_prefix}/flow-logs"
  retention_in_days = var.flow_logs_retention_days

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-flow-logs"
  })
}

# Trust policy: allow the VPC Flow Logs service to assume this role.
data "aws_iam_policy_document" "flow_logs_assume_role" {
  count = var.enable_flow_logs ? 1 : 0

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

  name               = "${var.name_prefix}-flow-logs-role"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume_role[0].json

  tags = var.tags
}

# Permission policy: the minimum set of CloudWatch Logs actions the service
# needs. Scoped to this log group only rather than "Resource": "*".
data "aws_iam_policy_document" "flow_logs_permissions" {
  count = var.enable_flow_logs ? 1 : 0

  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
    ]
    resources = [
      aws_cloudwatch_log_group.flow_logs[0].arn,
      "${aws_cloudwatch_log_group.flow_logs[0].arn}:*",
    ]
  }
}

resource "aws_iam_role_policy" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name   = "${var.name_prefix}-flow-logs-policy"
  role   = aws_iam_role.flow_logs[0].id
  policy = data.aws_iam_policy_document.flow_logs_permissions[0].json
}

resource "aws_flow_log" "this" {
  count = var.enable_flow_logs ? 1 : 0

  vpc_id = aws_vpc.this.id

  # ALL captures both ACCEPT and REJECT. Capturing only ACCEPT would hide
  # exactly the events you need when debugging a connectivity failure.
  traffic_type = "ALL"

  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.flow_logs[0].arn
  iam_role_arn         = aws_iam_role.flow_logs[0].arn

  # 1-minute aggregation instead of the 10-minute default, so logs are useful
  # during an active incident rather than ten minutes after it.
  max_aggregation_interval = 60

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-flow-log"
  })
}
