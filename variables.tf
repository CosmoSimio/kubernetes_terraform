variable "ami" {
  type = string
}

variable "master_instance_type" {
  type = string
}

variable "worker_instance_type" {
  type = string
}

variable "aws_key_name" {
  type = string
}

variable "ssh_user" {
  type = string
}

variable "worker_count" {
  type = number
}

variable "region" {
  type = string
}

variable "ssh_private_key_path" {
  type        = string
}

variable "name" {
  type = string
  description = "Enter your name"
}

variable "owner" {
  type = string
  description = "Enter the your work email address"
}

variable "purpose" {
  type = string
  description = "Enter the purpose of this launch"
}
