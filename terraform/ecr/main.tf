variable "project_name" {}
variable "environment" {}
variable "owner" {}
variable "aws_region" {}

data "aws_caller_identity" "current" {}

output "repository_url" {
  description = "ECR URI for the docker image — use this in your CI pipeline"
  value       = aws_ecr_repository.private_repo.repository_url
}

output "ecr_registry" {
  description = "ECR registry hostname — used in docker login command"
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
}

output "aws_account_id" {
  description = "Your AWS account ID"
  value       = data.aws_caller_identity.current.account_id
}

output "aws_ecr_repository_arn" {
  description = "ARN of repo to attach the policies to repo"
  value = aws_ecr_repository.private_repo.arn
}

resource "aws_ecr_repository" "private_repo" {
  name = var.project_name
  force_delete = true
  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "private_repo" {
  repository = aws_ecr_repository.private_repo.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 1 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 1
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
