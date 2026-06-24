# terraform/ec2/keypair.tf
# =============================================================================
# Generates an ED25519 SSH key pair entirely within Terraform.
# No manual ssh-keygen needed.
#
# Private key is stored in SSM SecureString — retrieve anytime with:
#   terraform output -raw ssh_private_key
# =============================================================================

resource "tls_private_key" "ec2_key" {
  algorithm = "ED25519"
}

resource "aws_key_pair" "ec2_key" {
  key_name   = "${var.project_name}-key"
  public_key = tls_private_key.ec2_key.public_key_openssh

  tags = local.common_tags
}

# Store private key in SSM SecureString — encrypted at rest, free tier
resource "aws_ssm_parameter" "ssh_private_key" {
  name        = "/${var.project_name}/${var.environment}/SSH_PRIVATE_KEY"
  type        = "SecureString"
  value       = tls_private_key.ec2_key.private_key_openssh
  description = "EC2 SSH private key"

  tags = local.common_tags
}
