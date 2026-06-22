# terraform/outputs.tf
# Root module outputs — sourced from child modules.
# push-secrets-to-github.sh reads these directly.

output "aws_region" {
  description = "AWS region"
  value       = var.aws_region
}

# ECR — single repo
output "ecr_repo_url" {
  description = "Single ECR repository URL — used as ECR_REPO_URL GitHub Secret"
  value       = module.registry.repository_url
}

output "ecr_registry" {
  description = "ECR registry hostname"
  value       = module.registry.ecr_registry
}

# IAM — GitHub Actions credentials
output "github_actions_access_key_id" {
  description = "AWS_ACCESS_KEY_ID — add as GitHub Secret"
  value       = module.iam.github_actions_access_key_id
}

output "github_actions_secret_access_key" {
  description = "AWS_SECRET_ACCESS_KEY — add as GitHub Secret"
  value       = module.iam.github_actions_secret_access_key
  sensitive   = true
}

output "github_actions_iam_user" {
  description = "IAM username created for GitHub Actions"
  value       = module.iam.github_actions_iam_user
}

# EC2 — populated after Phase 3 apply
output "ec2_public_ip" {
  description = "EC2 public IP — used as EC2_HOST GitHub Secret"
  value       = module.ec2.ec2_public_ip
}

output "app_url" {
  description = "Frontend URL"
  value       = module.ec2.app_url
}

output "ssh_command" {
  description = "SSH command to connect to EC2"
  value       = module.ec2.ssh_command
}
