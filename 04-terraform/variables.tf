variable "aws_region" {
  description = "AWS region for every resource."
  type        = string
  default     = "eu-central-1"
}

variable "instance_type" {
  description = "EC2 instance type for the server."
  type        = string
  default     = "t3.micro"
}

variable "my_ip" {
  description = "The one public IPv4 address that may connect over SSH, without a mask, for example 203.0.113.10."
  type        = string

  validation {
    # Four numbers from 0 to 255 joined by dots, and nothing else.
    # The /32 is added in main.tf, so a mask here would break the rule.
    condition     = can(regex("^((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\\.){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])$", var.my_ip))
    error_message = "The my_ip value must be a single IPv4 address without a mask, for example 203.0.113.10."
  }
}

variable "key_name" {
  description = "Name of an EC2 key pair that already exists in the region. Its public key goes onto the server."
  type        = string
}

variable "app_port" {
  description = "TCP port the app listens on. The security group opens it to everyone."
  type        = number
  default     = 8000

  validation {
    # A whole number from 1 to 65535, and not 22. The app rule is open to everyone,
    # so 22 would open SSH to everyone, while SSH may only come from my_ip.
    condition     = var.app_port == floor(var.app_port) && var.app_port >= 1 && var.app_port <= 65535 && var.app_port != 22
    error_message = "The app_port value must be a whole number from 1 to 65535 and not 22. Port 22 is SSH, which only my_ip may reach."
  }
}
