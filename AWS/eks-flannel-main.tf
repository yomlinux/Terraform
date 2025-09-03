terraform {
  required_version = ">= 1.4.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.23"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region     = "us-east-1"
  access_key = ""
  secret_key = ""
}

# ------------------ VPC ------------------
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.1.2"

  name                 = "eks-vpc"
  cidr                 = "10.0.0.0/16"
  azs                  = ["us-east-1a", "us-east-1b", "us-east-1c"]
  private_subnets      = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets       = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  # Required tags for EKS to properly discover subnets
  public_subnet_tags = {
    "kubernetes.io/role/elb"               = 1
    "kubernetes.io/cluster/my-eks-cluster-2" = "shared"  # Updated cluster name
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"      = 1
    "kubernetes.io/cluster/my-eks-cluster-2" = "shared"  # Updated cluster name
  }
}

# ------------------ EKS Cluster ------------------
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "19.21.0"

  cluster_name    = "my-eks-cluster-2"  # CHANGED: Unique cluster name
  cluster_version = "1.28"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access = true

  # DISABLE CLOUDWATCH LOGGING TO AVOID CONFLICTS
  cluster_enabled_log_types = []

  # Managed Node Groups - fixed configuration
  eks_managed_node_groups = {
    worker_nodes = {
      name           = "worker-nodes"
      desired_size   = 2
      max_size       = 3
      min_size       = 1
      instance_types = ["t3.medium"]
      subnet_ids     = module.vpc.private_subnets

      # Additional recommended settings
      disk_size      = 20
      capacity_type  = "ON_DEMAND"
      
      # IAM role settings
      iam_role_additional_policies = {
        AmazonEBSCSIDriverPolicy = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
      }
    }
  }

  # EKS Addons configuration - fixed to avoid deprecated arguments
  cluster_addons = {
    coredns = {
      most_recent              = true
      resolve_conflicts        = "OVERWRITE"  # Updated parameter
    }
    kube-proxy = {
      most_recent              = true
      resolve_conflicts        = "OVERWRITE"  # Updated parameter
    }
    vpc-cni = {
      most_recent              = true
      resolve_conflicts        = "OVERWRITE"  # Updated parameter
    }
    aws-ebs-csi-driver = {
      most_recent              = true
      resolve_conflicts        = "OVERWRITE"  # Updated parameter
    }
  }

  tags = {
    Environment = "dev"
    Terraform   = "true"
  }
}

# Configure Kubernetes provider with exec authentication (FIXED - no data sources)
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks",
      "get-token",
      "--cluster-name",
      module.eks.cluster_name,
      "--region",
      "us-east-1"
    ]
  }
}

# ------------------ Dashboard Deployment ------------------
resource "null_resource" "deploy_dashboard" {
  triggers = {
    cluster_endpoint = module.eks.cluster_endpoint
  }

  provisioner "local-exec" {
    command = <<-EOT
      # Wait for cluster to be ready
      echo "Waiting for EKS cluster to be active..."
      until aws eks describe-cluster --name ${module.eks.cluster_name} --region us-east-1 --query "cluster.status" --output text | grep -q "ACTIVE"; do
        sleep 10
        echo "Waiting for cluster to be ACTIVE..."
      done
      
      # Wait a bit more for nodes to be ready
      sleep 30
      
      # Update kubeconfig
      echo "Updating kubeconfig..."
      aws eks update-kubeconfig --region us-east-1 --name ${module.eks.cluster_name}
      
      # Wait for nodes to be ready
      echo "Waiting for nodes to be ready..."
      until kubectl get nodes 2>/dev/null | grep -q "Ready"; do
        sleep 10
        echo "Waiting for nodes..."
      done
      
      # Deploy Kubernetes Dashboard
      echo "Deploying Kubernetes Dashboard..."
      kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml
      
      # Create admin user and role binding
      cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin-user
  namespace: kubernetes-dashboard
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin-user
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: admin-user
  namespace: kubernetes-dashboard
EOF

      echo "Kubernetes Dashboard deployed successfully!"
      echo "Get token with: kubectl -n kubernetes-dashboard create token admin-user"
    EOT

    interpreter = ["/bin/bash", "-c"]
  }

  depends_on = [
    module.eks.eks_managed_node_groups
  ]
}

# ------------------ Outputs ------------------
output "eks_cluster_id" {
  value = module.eks.cluster_id
}

output "eks_cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "eks_node_group_arns" {
  value = [for ng in module.eks.eks_managed_node_groups : ng.node_group_arn]
}

output "dashboard_token_command" {
  description = "Command to get dashboard token"
  value       = "kubectl -n kubernetes-dashboard create token admin-user"
}

output "dashboard_proxy_command" {
  description = "Command to access dashboard via kubectl proxy"
  value       = "kubectl proxy"
}

output "dashboard_local_url" {
  description = "Local URL for dashboard (after running proxy)"
  value       = "http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/"
}

output "dashboard_port_forward_command" {
  description = "Command for port forwarding"
  value       = "kubectl port-forward -n kubernetes-dashboard service/kubernetes-dashboard 8443:443"
}

output "dashboard_info" {
  description = "Dashboard access information"
  value = <<EOT

Kubernetes Dashboard deployed successfully!

Access Methods:
1. kubectl proxy (most secure):
   Run: kubectl proxy
   Then open: http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/

2. Port forwarding:
   Run: kubectl port-forward -n kubernetes-dashboard service/kubernetes-dashboard 8443:443
   Then open: https://localhost:8443

Get login token with:
kubectl -n kubernetes-dashboard create token admin-user

EOT
}

output "configure_kubectl_command" {
  description = "Command to configure kubectl"
  value       = "aws eks update-kubeconfig --region us-east-1 --name ${module.eks.cluster_name}"
}

output "cluster_ready_command" {
  description = "Command to wait for cluster to be ready"
  value       = "aws eks wait cluster-active --name ${module.eks.cluster_name} --region us-east-1"
}

output "cluster_security_group_id" {
  description = "Security group ID attached to the cluster"
  value       = module.eks.cluster_security_group_id
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data required to communicate with the cluster"
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "oidc_provider_arn" {
  description = "The ARN of the OIDC Provider"
  value       = module.eks.oidc_provider_arn
}

output "cluster_name" {
  value = module.eks.cluster_name
}
