variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-south-1"
}

variable "project_name" {
  description = "Project name — used as prefix for all resource names"
  type        = string
  default     = "idurar"
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "production"

  validation {
    condition     = contains(["development", "staging", "production"], var.environment)
    error_message = "Must be one of: development, staging, production"
  }
}

variable "owner" {
  description = "Owner tag"
  type        = string
}

variable "my_ip" {
  description = "Your public IP for SSH access. Get it from: curl ifconfig.me"
  type        = string

  validation {
    condition     = can(regex("^(\\d{1,3}\\.){3}\\d{1,3}$", var.my_ip))
    error_message = "Must be a valid IPv4 address e.g. 103.21.54.12"
  }
}

variable "mongodb_uri" {
  description = "MongoDB Atlas connection string — stored in SSM SecureString"
  type        = string
  sensitive   = true
}

variable "jwt_secret" {
  description = "JWT signing secret — minimum 32 characters"
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.jwt_secret) >= 32
    error_message = "JWT secret must be at least 32 characters long"
  }
}

