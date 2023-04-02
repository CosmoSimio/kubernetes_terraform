terraform {
  # Declare the required providers for the Terraform configuration
  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "~> 3.70"
    }
  }
}

# Create an AWS VPC with a CIDR block of 10.0.0.0/16 and DNS hostnames enabled
resource "aws_vpc" "k8s" {
  cidr_block = "10.0.0.0/16"
  enable_dns_hostnames = true
}

# Create a public subnet in availability zone us-east-2a
resource "aws_subnet" "k8s-public" {
  vpc_id = aws_vpc.k8s.id
  cidr_block = "10.0.0.0/24"
  availability_zone = "us-east-2a"

  tags = {
    Name = "${var.name}-kubernetes-public-subnet"
    Owner = var.owner
    Purpose = var.purpose
  }
}

# Create a private subnet in availability zone us-east-2b
resource "aws_subnet" "k8s-private" {
  vpc_id = aws_vpc.k8s.id
  cidr_block = "10.0.1.0/24"
  availability_zone = "us-east-2b"

  tags = {
    Name = "${var.name}-kubernetes-private-subnet"
    Owner = var.owner
    Purpose = var.purpose
  }
}

# Create a security group for the Kubernetes worker nodes with ports 22, 80 and 443 open for inbound traffic and all outbound traffic allowed
resource "aws_security_group" "kubernetes" {
  vpc_id = aws_vpc.k8s.id
  description = "Kubernetes worker security group"

  # Allow SSH traffic on port 22 from any IP address
  ingress {
    protocol = "tcp"
    from_port = 22
    to_port = 22
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow HTTP traffic on port 80 from any IP address
  ingress {
    protocol = "tcp"
    from_port = 80
    to_port = 80
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow HTTPS traffic on port 443 from any IP address
  ingress {
    protocol = "tcp"
    from_port = 443
    to_port = 443
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow all outbound traffic from the security group
  egress {
    protocol = "all"
    from_port = 0
    to_port = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Create an EC2 instance for the Kubernetes master node
resource "aws_instance" "k8s-master" {
  ami           = var.ami
  instance_type = var.master_instance_type
  key_name      = var.aws_key_name
  vpc_security_group_ids = [aws_security_group.kubernetes.id]
  subnet_id     = aws_subnet.k8s-public.id
  associate_public_ip_address = true
  credit_specification {
    cpu_credits = "standard"
  }

  user_data = <<-EOF
              #!/bin/bash
              echo "Environment=KUBELET_EXTRA_ARGS=--node-ip=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)" >> /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
              systemctl daemon-reload
              systemctl restart kubelet
              EOF

  tags = {
    Name = "${var.name}-kubernetes-master"
    Owner = var.owner
    Purpose = var.purpose
  }
}

# Wait for the Kubernetes master node to become ready
resource "null_resource" "k8s-master-provisioner" {
  depends_on = [aws_instance.k8s-master]

  provisioner "remote-exec" {
    connection {
      type = "ssh"
      host = aws_instance.k8s-master.public_dns
      user = var.ssh_user
    }

    inline = [
      "until [[ -f /etc/kubernetes/admin.conf ]]; do sleep 1; done",
      "until kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes | grep $(hostname) | grep -q Ready; do sleep 1; done",
      "sleep 30",
      "kubectl --kubeconfig /etc/kubernetes/admin.conf taint nodes --all node-role.kubernetes.io/master-",
    ]
  }
}

# Initialize the Kubernetes cluster on the master node
resource "null_resource" "k8s-init" {
  depends_on = [null_resource.k8s-master-provisioner]

  provisioner "remote-exec" {
    connection {
      type = "ssh"
      host = aws_instance.k8s-master.public_dns
      user = var.ssh_user
    }

    inline = [
      "kubeadm init --pod-network-cidr=10.244.0.0/16",
      "mkdir -p /home/${var.ssh_user}/.kube",
      "cp /etc/kubernetes/admin.conf /home/${var.ssh_user}/.kube/config",
      "chown -R ${var.ssh_user}:${var.ssh_user} /home/${var.ssh_user}/.kube",
    ]
  }
}

# Install a CNI plugin to provide networking for Kubernetes pods
resource "null_resource" "k8s-cni" {
  depends_on = [null_resource.k8s-init]

  provisioner "remote-exec" {
    connection {
      type = "ssh"
      host = aws_instance.k8s-master.public_dns
      user = var.ssh_user
    }

    inline = [
      "kubectl --kubeconfig /etc/kubernetes/admin.conf apply -f https://docs.projectcalico.org/manifests/calico.yaml",
    ]
  }
}

# Create a Kubernetes join token for worker nodes to join the cluster
resource "null_resource" "k8s-join" {
  depends_on = [null_resource.k8s-init]

  provisioner "remote-exec" {
    connection {
      type = "ssh"
      host = aws_instance.k8s-master.public_dns
      user = var.ssh_user
    }

    inline = [
      "kubeadm token create --print-join-command > /tmp/k8s-join.sh",
    ]
  }

  provisioner "local-exec" {
    command = "scp -o StrictHostKeyChecking=no -i ${var.ssh_private_key_path} /tmp/k8s-join.sh ${var.ssh_user}@${aws_instance.k8s-master.public_dns}:/tmp"
  }
}

# Create a Kubernetes worker node and join it to the cluster
resource "aws_instance" "worker" {
  ami           = var.ami
  instance_type = var.worker_instance_type
  key_name      = var.aws_key_name
  vpc_security_group_ids = [aws_security_group.kubernetes.id]
  subnet_id     = aws_subnet.k8s-private.id
  associate_public_ip_address = true
  credit_specification {
    cpu_credits = "standard"
  }

  user_data = <<-EOF
              #!/bin/bash
              sudo $(cat /tmp/k8s-join.sh)
              EOF

  tags = {
    Name = "${var.name}-kubernetes-worker-${count.index}"
    Owner = var.owner
    Purpose = var.purpose
  }

  provisioner "remote-exec" {
    script = <<-EOT
      sudo yum install -y docker
      sudo systemctl start docker
      sudo systemctl enable docker
      sudo usermod -aG docker ${var.ssh_user}
    EOT

    connection {
      type = "ssh"
      host = self.public_ip
      user = var.ssh_user
    }
  }

  count = var.worker_count
}

# Output the Kubernetes cluster's IP address
output "kubernetes_cluster_ip" {
  value = aws_instance.k8s-master.public_dns
}
