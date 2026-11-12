provider "aws" {
  region = var.aws_region

  # Every resource gets these tags, so it is easy to see what this code made.
  default_tags {
    tags = {
      Project   = "devops-portfolio"
      ManagedBy = "terraform"
    }
  }
}

# Newest Ubuntu 24.04 server image for amd64. The owner ID is Canonical, so an
# image that someone else published under a similar name is never picked.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# The default VPC keeps this small. No network of my own to build.
data "aws_vpc" "default" {
  default = true
}

resource "aws_security_group" "app" {
  name        = "portfolio-app"
  description = "SSH from one address, the app port from anywhere"
  vpc_id      = data.aws_vpc.default.id
}

# Each rule is its own resource. A change to one rule leaves the others alone.
resource "aws_vpc_security_group_ingress_rule" "ssh" {
  security_group_id = aws_security_group.app.id
  description       = "SSH from my address only"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = "${var.my_ip}/32"
}

resource "aws_vpc_security_group_ingress_rule" "app" {
  security_group_id = aws_security_group.app.id
  description       = "App port from anywhere"
  ip_protocol       = "tcp"
  from_port         = var.app_port
  to_port           = var.app_port
  cidr_ipv4         = "0.0.0.0/0"
}

# Terraform removes the default outbound rule of a new group, so it is written
# out here. The server needs it to download packages and the app image.
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.app.id
  description       = "All outbound traffic"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_instance" "app" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.app.id]

  # The outputs need a public address. Asking for it here does not depend on
  # the setting of the default subnet.
  associate_public_ip_address = true

  # IMDSv2 only. A metadata request needs a session token first, which blocks
  # the simple way to read the instance credentials through a forged request.
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = "portfolio-app"
  }
}
