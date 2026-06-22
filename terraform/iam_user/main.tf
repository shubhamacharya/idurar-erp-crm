# ── IAM User for GitHub Actions ───────────────────────────────────────────────
# Least-privilege: only ECR push permissions, nothing else.

variable "project_name" {}
variable "environment" {}
variable "owner" {}
variable "aws_region" {}
variable "tags" {}
variable "ecr_repository_arn" {}

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

resource "aws_iam_user" "github_actions" {
  name = "${var.project_name}-github-actions"
  tags = var.tags
}

resource "aws_iam_user_policy" "github_actions_ecr" {
  name = "${var.project_name}-ecr-push-policy"
  user = aws_iam_user.github_actions.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECRAuth"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken"
        ]
        Resource = "*"
      },
      {
        Sid    = "ECRPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:DescribeRepositories",
          "ecr:ListImages"
        ]
        Resource = [
          var.ecr_repository_arn
        ]
      }
    ]
  })
}

resource "aws_iam_access_key" "github_actions" {
  user = aws_iam_user.github_actions.name
}