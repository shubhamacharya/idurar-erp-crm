variable "project_name" {}
variable "environment" {}
variable "owner" {}
variable "aws_region" {}
variable "my_ip" {}
variable "mongodb_uri" {}
variable "jwt_secret" {}
variable "ecr_repository_arn" {}
variable "ecr_repo_url" {}
variable "tags" {}

# ── Data sources ──────────────────────────────────────────────────────────────

data "aws_caller_identity" "current" {}

# Latest Amazon Linux 2023 AMI — always up to date, no hardcoded AMI ID
data "aws_ami" "ubuntu_2404" {
  most_recent = true

  owners = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

variable "vpc_id" {
  description = "VPC ID — from networking module"
  type        = string
}

variable "subnet_id" {
  description = "Public subnet ID to launch EC2 into — from networking module"
  type        = string
}

# ── SSM Parameters (secrets store) ───────────────────────────────────────────
# SecureString encrypts at rest using AWS-managed KMS key — free tier.
# EC2 reads these at boot via the IAM role — no plaintext env vars anywhere.

resource "aws_ssm_parameter" "mongodb_uri" {
  name        = "/${var.project_name}/${var.environment}/MONGODB_URI"
  type        = "SecureString"
  value       = var.mongodb_uri
  description = "MongoDB Atlas connection string"

  tags = local.common_tags
}

resource "aws_ssm_parameter" "jwt_secret" {
  name        = "/${var.project_name}/${var.environment}/JWT_SECRET"
  type        = "SecureString"
  value       = var.jwt_secret
  description = "JWT signing secret"

  tags = local.common_tags
}

resource "aws_ssm_parameter" "backend_url" {
  name  = "/${var.project_name}/${var.environment}/BACKEND_PUBLIC_URL"
  type  = "String"
  value = format("http://%s:8888", aws_instance.app.public_ip)

  tags = local.common_tags
}

# ── IAM role for EC2 ──────────────────────────────────────────────────────────
# EC2 assumes this role at boot. Grants access to:
#   - SSM Parameter Store (read secrets)
#   - ECR (pull Docker images)
#   - CloudWatch Logs (ship container logs)
# No access keys needed on the server — the role IS the credential.

resource "aws_iam_role" "ec2_role" {
  name = "${var.project_name}-ec2-role"

  # Trust policy: only EC2 service can assume this role
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "ec2_policy" {
  name = "${var.project_name}-ec2-policy"
  role = aws_iam_role.ec2_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SSMReadSecrets"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath"
        ]
        # Scoped to only this project's parameters
        Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project_name}/*"
      },
      {
        Sid    = "ECRAuth"
        Effect = "Allow"
        Action = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "ECRPull"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage"
        ]
        Resource = [
          var.ecr_repository_arn
        ]
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/idurar/*"
      }
    ]
  })
}

# Instance profile — the bridge between IAM role and EC2 instance
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${var.project_name}-ec2-profile"
  role = aws_iam_role.ec2_role.name

  tags = local.common_tags
}

# ── Security Group ────────────────────────────────────────────────────────────
# Firewall rules for the EC2 instance.
# Principle: allow only what is needed, deny everything else.

resource "aws_security_group" "app" {
  name        = "${var.project_name}-app-sg"
  description = "idurar application security group"
  vpc_id              = var.vpc_id

  # HTTP — frontend served by Nginx
  ingress {
    description = "HTTP frontend"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Backend API port — direct access (will be removed when ALB is added in Phase 5)
  ingress {
    description = "Backend API"
    from_port   = 8888
    to_port     = 8888
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # SSH — locked to your IP only, never open to the world
  ingress {
    description = "SSH from my IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["${var.my_ip}/32"]   # your IP from terraform.tfvars
  }

  # All outbound allowed — EC2 needs to reach ECR, Atlas, SSM, apt repos
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.common_tags
}

# ── EC2 Instance ──────────────────────────────────────────────────────────────

resource "aws_instance" "app" {
  ami                    = data.aws_ami.ubuntu_2404.id
  instance_type          = "t2.micro"          # Free Tier: 750 hrs/month
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name
  vpc_security_group_ids = [aws_security_group.app.id]
  key_name               = aws_key_pair.ec2_key.key_name
  subnet_id              = var.subnet_id

  # Root volume — 8GB default is enough, gp2 is Free Tier eligible
  root_block_device {
    volume_size = 8
    volume_type = "gp2"
    encrypted   = true
  }

  # User data runs once at first boot as root.
  # Installs Docker, logs in to ECR, pulls images, starts containers.
  user_data_base64 = base64encode(templatefile("${path.module}/userdata.sh.tpl", {
    aws_region       = var.aws_region
    project_name     = var.project_name
    environment      = var.environment
    ecr_repo_url  = var.ecr_repo_url
    account_id       = data.aws_caller_identity.current.account_id
  }))

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-app-server"
  })
}

# ── CloudWatch Log Groups ─────────────────────────────────────────────────────
# Pre-create log groups so the EC2 IAM policy can reference them.
# Retention = 7 days — stays within free tier (5GB/month).

resource "aws_cloudwatch_log_group" "backend" {
  name              = "/idurar/backend"
  retention_in_days = 7
  tags              = local.common_tags
}

resource "aws_cloudwatch_log_group" "frontend" {
  name              = "/idurar/frontend"
  retention_in_days = 7
  tags              = local.common_tags
}

# ── Locals ────────────────────────────────────────────────────────────────────

locals {
  common_tags = var.tags
}
