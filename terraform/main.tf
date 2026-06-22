terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

module "registry" {
  source       = "./ecr"
  project_name = var.project_name
  environment  = var.environment
  owner        = var.owner
  aws_region   = var.aws_region
}

module "iam" {
  source       = "./iam_user"
  project_name = var.project_name
  environment  = var.environment
  owner        = var.owner
  aws_region   = var.aws_region
  ecr_repository_arn = module.registry.aws_ecr_repository_arn
  tags = local.common_tags
}

module "ec2" {
  source       = "./ec2"
  project_name = var.project_name
  environment  = var.environment
  owner        = var.owner
  aws_region   = var.aws_region
  my_ip = var.my_ip
  mongodb_uri = var.mongodb_uri
  ecr_repository_arn = module.registry.aws_ecr_repository_arn
  ecr_repo_url = module.registry.repository_url
  jwt_secret = var.jwt_secret
  tags = local.common_tags

}

locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = var.owner
  }
}