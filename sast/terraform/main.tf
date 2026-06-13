terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-6.1-x86_64"]
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

locals {
  ami_id = var.ami_id != "" ? var.ami_id : data.aws_ami.amazon_linux.id
}

resource "aws_security_group" "sast_sg" {
  name        = "sast-security-group"
  description = "Security group for SAST backend service"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH from anywhere"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SAST service port"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "sast_server" {
  ami                         = local.ami_id
  instance_type               = var.instance_type
  subnet_id                   = tolist(data.aws_subnets.public.ids)[0]
  vpc_security_group_ids      = [aws_security_group.sast_sg.id]
  associate_public_ip_address = true
  iam_instance_profile        = "LabInstanceProfile"
  key_name                    = "vockey"
  user_data_replace_on_change = true

  user_data = <<EOF
#!/bin/bash
yum install -y docker
systemctl start docker
systemctl enable docker
docker pull ${var.sast_docker_image}
docker run -d -p 3000:3000 --name sast-app --restart unless-stopped ${var.sast_docker_image}
EOF

  tags = {
    Name = "sast-backend"
  }
}

output "sast_public_ip" {
  description = "Public IP of the SAST backend instance"
  value       = aws_instance.sast_server.public_ip
}

output "sast_health_endpoint" {
  description = "Health check endpoint"
  value       = "http://${aws_instance.sast_server.public_ip}:3000/health"
}
