variable "region" {
  description = "AWS region"
  default     = "us-east-1"
}

variable "ami_id" {
  description = "Optional AMI override. Leave empty to use the latest Amazon Linux 2023 AMI."
  type        = string
  default     = ""
}

variable "instance_type" {
  description = "EC2 instance type"
  default     = "t2.micro"
}

variable "sast_docker_image" {
  description = "Docker image for the SAST API service."
  type        = string
  default     = "spicehandler/sast-app:latest"
}
