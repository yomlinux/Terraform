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
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
    kube-proxy = {
      most_recent              = true
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
    vpc-cni = {
      most_recent              = true
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
    aws-ebs-csi-driver = {
      most_recent              = true
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
  }

  tags = {
    Environment = "dev"
    Terraform   = "true"
  }
}

# ------------------ Data Sources for Kubeconfig ------------------
# These data sources need to reference the actual cluster name, not the module output
data "aws_eks_cluster" "cluster" {
  name = "my-eks-cluster"  # Use the actual cluster name, not module.eks.cluster_id
}

data "aws_eks_cluster_auth" "cluster" {
  name = "my-eks-cluster"  # Use the actual cluster name, not module.eks.cluster_id
}

# Configure Kubernetes provider
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.cluster.token
}

# ------------------ Outputs ------------------
output "eks_cluster_id" {
  value = module.eks.cluster_id
}

output "eks_cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

# Fixed output - using correct attribute names
output "eks_node_group_arns" {
  value = [for ng in module.eks.eks_managed_node_groups : ng.node_group_arn]
}

output "eks_node_group_ids" {
  value = [for ng in module.eks.eks_managed_node_groups : ng.node_group_id]
}

# Fixed kubeconfig output - use a simple message instead of template
output "eks_kubeconfig_command" {
  description = "Command to generate kubeconfig"
  value       = "Use 'aws eks update-kubeconfig --region us-east-1 --name my-eks-cluster' to generate kubeconfig"
}

# Additional useful outputs
output "configure_kubectl" {
  description = "Command to configure kubectl"
  value       = "aws eks --region us-east-1 update-kubeconfig --name my-eks-cluster"
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

# These outputs will work after the cluster is created
output "cluster_arn" {
  description = "The ARN of the EKS cluster"
  value       = module.eks.cluster_arn
}

output "cluster_status" {
  description = "The status of the EKS cluster"
  value       = module.eks.cluster_status
}