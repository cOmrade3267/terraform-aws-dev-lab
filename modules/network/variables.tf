variable "name_prefix" {
  type        = string
  description = "Prefix for all resource Name tags in this module, e.g. 'dev' or 'staging'"
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the VPC"
}

variable "public_subnet_cidr" {
  type        = string
  description = "CIDR block for the public subnet"
}

variable "private_subnet_cidr" {
  type        = string
  description = "CIDR block for the private subnet"
}

variable "availability_zone" {
  type        = string
  description = "Availability zone for both subnets"
}

