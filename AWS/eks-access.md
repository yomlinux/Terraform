# After terraform apply completes, run these commands to verify connectivity:
bash

# Update your kubeconfig
aws eks update-kubeconfig --region us-east-1 --name my-eks-cluster

# Test cluster connection
kubectl cluster-info

# Verify nodes are running
kubectl get nodes

# Check Cilium pods
kubectl get pods -n kube-system -l k8s-app=cilium

# Check all system pods
kubectl get pods -n kube-system
