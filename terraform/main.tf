terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

module "networking" {
  source       = "./networking"
  project_name = var.project_name
  environment  = var.environment
  vpc_cidr     = "10.0.0.0/16"
  tags         = local.common_tags
}

module "registry" {
  source       = "./ecr"
  project_name = var.project_name
  environment  = var.environment
  owner        = var.owner
  aws_region   = var.aws_region
}

module "iam" {
  source             = "./iam_user"
  project_name       = var.project_name
  environment        = var.environment
  owner              = var.owner
  aws_region         = var.aws_region
  ecr_repository_arn = module.registry.aws_ecr_repository_arn
  tags               = local.common_tags
}

module "ec2" {
  source             = "./ec2"
  project_name       = var.project_name
  environment        = var.environment
  owner              = var.owner
  aws_region         = var.aws_region
  my_ip              = var.my_ip
  mongodb_uri        = var.mongodb_uri
  jwt_secret         = var.jwt_secret
  ecr_repository_arn = module.registry.aws_ecr_repository_arn
  ecr_repo_url       = module.registry.repository_url
  tags               = local.common_tags

  # Networking — from networking module
  vpc_id    = module.networking.vpc_id
  subnet_id = module.networking.public_subnet_ids[0]
}

locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = var.owner
  }
}
