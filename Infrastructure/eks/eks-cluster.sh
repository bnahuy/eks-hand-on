#!/bin/bash

echo "🔹 Đang tìm VPC có tag env=lab..."
VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=tag:env,Values=lab" \
    --query "Vpcs[0].VpcId" --output text)

CIDR_BLOCK=$(aws ec2 describe-vpcs \
    --filters "Name=tag:env,Values=lab" \
    --query "Vpcs[0].CidrBlock" --output text)

echo "🔹 Đang tìm Private Subnets theo VPC ID..."
PRIVATE_SUBNETS=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=map-public-ip-on-launch,Values=false" \
    --query "Subnets[*].[SubnetId,AvailabilityZone]" --output json)

# Lấy Subnet ID & AZ
PRIVATE_SUBNET_1_ID=$(echo $PRIVATE_SUBNETS | jq -r '.[0][0]')
PRIVATE_SUBNET_1_AZ=$(echo $PRIVATE_SUBNETS | jq -r '.[0][1]')
PRIVATE_SUBNET_2_ID=$(echo $PRIVATE_SUBNETS | jq -r '.[1][0]')
PRIVATE_SUBNET_2_AZ=$(echo $PRIVATE_SUBNETS | jq -r '.[1][1]')

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
      $PRIVATE_SUBNET_1_AZ:
        id: "$PRIVATE_SUBNET_1_ID"
      $PRIVATE_SUBNET_2_AZ:
        id: "$PRIVATE_SUBNET_2_ID"

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
