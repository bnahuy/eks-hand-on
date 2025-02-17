#!/bin/bash

echo "🔹 Đang tìm VPC có tag env=lab..."
VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=tag:env,Values=lab" \
    --query "Vpcs[0].VpcId" --output text)

CIDR_BLOCK=$(aws ec2 describe-vpcs \
    --filters "Name=tag:env,Values=lab" \
    --query "Vpcs[0].CidrBlock" --output text)

echo "🔹 Đang tìm Private Subnets theo VPC ID..."
PRIVATE_SUBNET_IDS=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=map-public-ip-on-launch,Values=false" \
    --query "Subnets[*].SubnetId" --output json | jq -r '. | join(",")')

EKS_CONFIG_FILE="/tmp/eks-private-cluster.yaml"

echo "🔹 Tạo file cấu hình EKS tại $EKS_CONFIG_FILE..."
cat <<EOF > "$EKS_CONFIG_FILE"
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: lab-eks-cluster
  region: us-east-1
  version: "1.29"

vpc:
  id: "$VPC_ID"
  cidr: "$CIDR_BLOCK"
  subnets:
    private:
      us-east-1a:
        id: "$(echo $PRIVATE_SUBNET_IDS | cut -d ',' -f1)"
      us-east-1b:
        id: "$(echo $PRIVATE_SUBNET_IDS | cut -d ',' -f2)"

privateCluster:
  enabled: true  # EKS API Server chỉ Private

nodeGroups:
  - name: private-nodes
    instanceType: t3a.medium
    desiredCapacity: 2
    minSize: 1
    maxSize: 3
    amiFamily: Bottlerocket
    privateNetworking: true
    volumeSize: 20
    labels:
      role: worker
    tags:
      env: lab
    ssh:
      allow: false
    iam:
      withAddonPolicies:
        autoScaler: true
        cloudWatch: true

addons:
  - name: kube-proxy
  - name: coredns
  - name: eks-pod-identity-agent
EOF

echo "✅ File cấu hình EKS đã được tạo tại: $EKS_CONFIG_FILE"
echo "🚀 Bắt đầu triển khai Private EKS Cluster..."
eksctl create cluster -f "$EKS_CONFIG_FILE"
echo "✅ EKS Private Cluster đã được triển khai thành công!"
