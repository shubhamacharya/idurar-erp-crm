output "backend_repository_url" {
  description = "ECR URI for the backend image — use this in your CI pipeline"
  value       = aws_ecr_repository.backend.repository_url
}

output "frontend_repository_url" {
  description = "ECR URI for the frontend image — use this in your CI pipeline"
  value       = aws_ecr_repository.frontend.repository_url
}

output "aws_account_id" {
  description = "Your AWS account ID"
  value       = data.aws_caller_identity.current.account_id
}

output "aws_region" {
  description = "Region where ECR repositories were created"
  value       = var.aws_region
}

output "ecr_registry" {
  description = "ECR registry hostname — used in docker login command"
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
}

output "github_actions_iam_user" {
  description = "IAM username created for GitHub Actions"
  value       = aws_iam_user.github_actions.name
}

output "github_actions_access_key_id" {
  description = "AWS_ACCESS_KEY_ID — add this as a GitHub Secret"
  value       = aws_iam_access_key.github_actions.id
}

output "github_actions_secret_access_key" {
  description = "AWS_SECRET_ACCESS_KEY — add this as a GitHub Secret (sensitive)"
  value       = aws_iam_access_key.github_actions.secret
  sensitive   = true
}

# ── Data sources ──────────────────────────────────────────────────────────────

data "aws_caller_identity" "current" {}
