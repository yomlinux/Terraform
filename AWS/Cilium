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
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.10"
    }
  }
}

provider "aws" {
  region = "us-east-1"
  # Remove hardcoded credentials - use environment variables or AWS profile instead
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
    "kubernetes.io/cluster/my-eks-cluster" = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"      = 1
    "kubernetes.io/cluster/my-eks-cluster" = "shared"
  }
}

# ------------------ EKS Cluster ------------------
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "19.21.0"

  cluster_name    = "my-eks-cluster"
  cluster_version = "1.28"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access = true

  # Disable VPC-CNI since we'll use Cilium for networking
  create_cni_ipv6_iam_policy = false

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
      
      # IAM role settings - use proper policy attachment to avoid deprecation warnings
      iam_role_additional_policies = {
        AmazonEBSCSIDriverPolicy = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
      }
    }
  }

  # EKS Addons configuration - remove vpc-cni since we'll use Cilium
  cluster_addons = {
    coredns = {
      most_recent              = true
      resolve_conflicts        = "OVERWRITE"
    }
    kube-proxy = {
      most_recent              = true
      resolve_conflicts        = "OVERWRITE"
    }
    aws-ebs-csi-driver = {
      most_recent              = true
      resolve_conflicts        = "OVERWRITE"
    }
  }

  tags = {
    Environment = "dev"
    Terraform   = "true"
  }
}

# Configure Kubernetes provider with exec authentication
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

# Configure Helm provider with exec authentication
provider "helm" {
  kubernetes {
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
}

# ------------------ Cilium Installation ------------------
resource "helm_release" "cilium" {
  name             = "cilium"
  repository       = "https://helm.cilium.io/"
  chart            = "cilium"
  version          = "1.14.5" # Use a specific version for stability
  namespace        = "kube-system"
  create_namespace = true
  wait             = true
  timeout          = 600

  set {
    name  = "ipam.mode"
    value = "kubernetes"
  }

  set {
    name  = "tunnel"
    value = "disabled"
  }

  set {
    name  = "autoDirectNodeRoutes"
    value = "true"
  }

  set {
    name  = "kubeProxyReplacement"
    value = "strict"
  }

  set {
    name  = "nativeRoutingCIDR"
    value = module.vpc.vpc_cidr_block
  }

  set {
    name  = "loadBalancer.mode"
    value = "dsr"
  }

  set {
    name  = "nodePort.enable"
    value = "true"
  }

  set {
    name  = "hostPort.enable"
    value = "true"
  }

  set {
    name  = "bgp.enabled"
    value = "false"
  }

  set {
    name  = "hubble.enabled"
    value = "true"
  }

  set {
    name  = "hubble.metrics.enabled"
    value = "{dns,drop,tcp,flow,port-distribution,icmp,http}"
  }

  set {
    name  = "hubble.relay.enabled"
    value = "true"
  }

  set {
    name  = "hubble.ui.enabled"
    value = "true"
  }

  # Wait for cluster to be fully ready and nodes to be available
  depends_on = [
    module.eks,
    time_sleep.wait_for_cluster
  ]
}

# Add a delay to ensure cluster is fully ready before installing Cilium
resource "time_sleep" "wait_for_cluster" {
  create_duration = "120s"
  depends_on = [module.eks]
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

output "eks_node_group_ids" {
  value = [for ng in module.eks.eks_managed_node_groups : ng.node_group_id]
}

output "eks_kubeconfig_command" {
  description = "Command to generate kubeconfig"
  value       = "Use 'aws eks update-kubeconfig --region us-east-1 --name ${module.eks.cluster_name}' to generate kubeconfig"
}

output "configure_kubectl" {
  description = "Command to configure kubectl"
  value       = "aws eks --region us-east-1 update-kubeconfig --name ${module.eks.cluster_name}"
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

output "cluster_arn" {
  description = "The ARN of the EKS cluster"
  value       = module.eks.cluster_arn
}

output "cluster_status" {
  description = "The status of the EKS cluster"
  value       = module.eks.cluster_status
}

output "cilium_status" {
  description = "Cilium installation status"
  value       = helm_release.cilium.status
}
