terraform {
  required_providers {
    null = {
      source = "hashicorp/null"
      version = "~> 3.0"
    }
  }
  required_version = ">= 1.3.0"
}

variable "repo_content" {
  default = <<EOT
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.30/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.30/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl
EOT
}

variable "nodes" {
  default = {
    kmaster1 = { ip = "10.0.0.131", role = "master" }
    kmaster2 = { ip = "10.0.0.132", role = "master" }
    kworker1 = { ip = "10.0.0.133", role = "worker" }
    kworker2 = { ip = "10.0.0.134", role = "worker" }
  }
}

# Clean up existing Kubernetes setup
resource "null_resource" "clean_setup" {
  for_each = var.nodes

  connection {
    type        = "ssh"
    host        = each.value["ip"]
    user        = "root"
    private_key = file("~/.ssh/id_rsa")
  }

  provisioner "remote-exec" {
    inline = [
      "echo Cleaning up existing Kubernetes setup",
      "sudo kubeadm reset -f",
      "sudo systemctl stop kubelet || true",
      "sudo systemctl stop docker || true",
      "sudo rm -rf /etc/cni /var/lib/etcd /root/.kube /etc/kubernetes /var/lib/kubelet",
      "sudo yum remove -y kubeadm kubectl kubelet docker || true",
    ]
  }
}

# Set up the Kubernetes repository
resource "null_resource" "setup_repo" {
  for_each = var.nodes

  connection {
    type        = "ssh"
    host        = each.value["ip"]
    user        = "root"
    private_key = file("~/.ssh/id_rsa")
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${var.repo_content}' | sudo tee /etc/yum.repos.d/k8s.repo",
    ]
  }
}

# Install Kubernetes packages and kubectl
resource "null_resource" "install_k8s_packages" {
  for_each = var.nodes

  connection {
    type        = "ssh"
    host        = each.value["ip"]
    user        = "root"
    private_key = file("~/.ssh/id_rsa")
  }

  provisioner "remote-exec" {
    inline = [
      "echo Installing Kubernetes packages on ${each.value["role"]}",
      "curl -LO \"https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl\"",
      "curl -LO https://dl.k8s.io/release/v1.31.0/bin/linux/amd64/kubectl",
      "sudo install -o root -g root -m 0755 kubectl /usr/bin/kubectl",
      "curl -LO https://dl.k8s.io/release/v1.31.0/bin/linux/amd64/kubeadm",
      "sudo install -o root -g root -m 0755 kubectl /usr/bin/kubeadm",
      "curl -LO https://dl.k8s.io/release/v1.31.0/bin/linux/amd64/kubelet",
      "sudo install -o root -g root -m 0755 kubectl /usr/bin/kubelet",
      "sudo yum install -y kubeadm kubelet kubectl --disableexcludes=kubernetes",
      "sudo systemctl enable kubelet && sudo systemctl start kubelet",
      "echo Installing kubectl",
    ]
    on_failure = "continue"
  }
}

# Initialize Kubernetes master on both nodes
resource "null_resource" "initialize_master" {
  for_each = { 
    "kmaster1" = var.nodes["kmaster1"], 
    "kmaster2" = var.nodes["kmaster2"]
  }

  connection {
    type        = "ssh"
    host        = each.value["ip"]
    user        = "root"
    private_key = file("~/.ssh/id_rsa")
  }

  provisioner "remote-exec" {
    inline = [
      "echo Initializing Kubernetes master on ${each.key}",
      "sudo kubeadm init --apiserver-advertise-address=${each.value["ip"]} --pod-network-cidr=192.168.0.0/16",
      "mkdir -p $HOME/.kube",
      "sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config",
      "sudo chown $(id -u):$(id -g) $HOME/.kube/config",
    ]
    on_failure = "continue"
  }
}

# Join workers to the cluster
resource "null_resource" "join_cluster" {
  for_each = { for k, v in var.nodes : k => v if v.role != "master" }

  depends_on = [null_resource.initialize_master]

  connection {
    type        = "ssh"
    host        = each.value["ip"]
    user        = "root"
    private_key = file("~/.ssh/id_rsa")
  }

  provisioner "remote-exec" {
    inline = [
      "echo Joining worker ${each.value["ip"]} to the cluster",
      "sudo kubeadm join ${var.nodes.kmaster1["ip"]}:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>",
    ]
    on_failure = "continue"
  }
}
