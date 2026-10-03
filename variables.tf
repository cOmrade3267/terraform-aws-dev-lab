variable "host_os" {
  type    = string
  default = "linux"
}
variable "my_ip" {
  type        = string
  description = "My public IP in CIDR form, e.g. 203.0.113.5/32"

  validation {
    condition     = can(cidrhost(var.my_ip, 0)) && endswith(var.my_ip, "/32")
    error_message = "my_ip must be a single IP in CIDR form ending in /32."
  }
}
variable "trusted_user" {
  type    = string
  default = "terraform-demo"

  validation {
    condition     = length(var.trusted_user) > 0 && !can(regex("\\*", var.trusted_user))
    error_message = "trusted_user must be a specific IAM user name, not empty or a wildcard."
  }
}

variable "role_name" {
  type        = string
  description = "Name of the lab role"
  default     = "mtc_labreadonly"
}

variable "role_policy_arn" {
  type        = string
  description = "Managed policy attached to the lab role"
  default     = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}