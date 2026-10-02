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