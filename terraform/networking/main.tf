# terraform/networking/main.tf
# =============================================================================
# Custom VPC with:
#   - 2 public subnets  (EC2, future ALB) — across 2 AZs for HA
#   - 2 private subnets (future RDS, ECS) — across 2 AZs for HA
#   - Internet Gateway  (public internet access)
#   - Public route table (0.0.0.0/0 → IGW)
#   - Private route table (local only — no internet, for future NAT Gateway)
#
# Free Tier note:
#   VPC, subnets, IGW, route tables are all FREE.
#   NAT Gateway is NOT free — omitted here, added in future phases.
# =============================================================================

# ── Data: available AZs in the region ────────────────────────────────────────
data "aws_availability_zones" "available" {
  state = "available"
}

# ── VPC ───────────────────────────────────────────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true    # required for ECR, SSM, Atlas DNS resolution
  enable_dns_hostnames = true    # gives EC2 instances a public DNS hostname

  tags = merge(var.tags, {
    Name = "${var.project_name}-vpc"
  })
}

# ── Internet Gateway ──────────────────────────────────────────────────────────
# Required for any public subnet to reach the internet
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "${var.project_name}-igw"
  })
}

# ── Public Subnets ────────────────────────────────────────────────────────────
# One per AZ — EC2 instance lives here
# map_public_ip_on_launch = true means EC2 gets a public IP automatically

resource "aws_subnet" "public" {
  count = 2

  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name = "${var.project_name}-public-subnet-${count.index + 1}"
    Tier = "public"
  })
}

# ── Private Subnets ───────────────────────────────────────────────────────────
# One per AZ — reserved for future use (RDS, ECS tasks, Lambda)
# No internet access without NAT Gateway (added in future phase)

resource "aws_subnet" "private" {
  count = 2

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = merge(var.tags, {
    Name = "${var.project_name}-private-subnet-${count.index + 1}"
    Tier = "private"
  })
}

# ── Public Route Table ────────────────────────────────────────────────────────
# Routes all internet traffic through the IGW

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-public-rt"
  })
}

# Associate both public subnets with the public route table
resource "aws_route_table_association" "public" {
  count = 2

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ── Private Route Table ───────────────────────────────────────────────────────
# Local routing only — no internet egress without NAT Gateway
# NAT Gateway will be added in a future phase when needed

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "${var.project_name}-private-rt"
  })
}

# Associate both private subnets with the private route table
resource "aws_route_table_association" "private" {
  count = 2

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
