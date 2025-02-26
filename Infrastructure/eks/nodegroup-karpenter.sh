#!/bin/bash

KARPENTER_NAMESPACE="kube-system"
KARPENTER_VERSION="1.2.1"
K8S_VERSION="1.32"

AWS_PARTITION="aws"
CLUSTER_NAME="lab-eks-cluster"
AWS_DEFAULT_REGION="us-east-1"
AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
TEMPOUT="$(mktemp)"

aws ssm get-parameter --name /aws/service/bottlerocket/aws-k8s-kubernetes-version-flavor/architecture/latest/image_id --region region-code --query "Parameter.Value" --output text
