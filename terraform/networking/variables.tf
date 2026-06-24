# terraform/networking/variables.tf

variable "project_name" {
  description = "Project name — used as prefix for all resource names"
  type        = string
}

variable "environment" {
  description = "Deployment environment"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"

  # Subnet layout with default 10.0.0.0/16:
  #   public-1:  10.0.0.0/24   (AZ a)
  #   public-2:  10.0.1.0/24   (AZ b)
  #   private-1: 10.0.10.0/24  (AZ a)
  #   private-2: 10.0.11.0/24  (AZ b)
}

variable "tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default     = {}
}
