#!/bin/bash

KARPENTER_NAMESPACE="kube-system"
KARPENTER_VERSION="1.2.1"
K8S_VERSION="1.32"

AWS_PARTITION="aws"
CLUSTER_NAME="lab-eks-cluster"
AWS_DEFAULT_REGION="us-east-1"
AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
TEMPOUT="$(mktemp)"
ARCHITECTURE="arm64"

echo "Bắt đầu lấy AMI..."
BOTTLEROCKET_AMI="$(aws ssm get-parameter --name /aws/service/bottlerocket/aws-k8s-${K8S_VERSION}/${ARCHITECTURE}/latest/image_id --region ${AWS_DEFAULT_REGION} --query "Parameter.Value" --output text)"
echo "AMI: ${BOTTLEROCKET_AMI}"
