#!/bin/bash

KARPENTER_NAMESPACE="kube-system"
KARPENTER_VERSION="1.2.1"
K8S_VERSION="1.32"

AWS_PARTITION="aws"
CLUSTER_NAME="lab-eks-cluster"
AWS_DEFAULT_REGION="us-east-1"
AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
TEMPOUT="$(mktemp)"

echo "${KARPENTER_NAMESPACE}" "${KARPENTER_VERSION}" "${K8S_VERSION}" "${CLUSTER_NAME}" "${AWS_DEFAULT_REGION}" "${AWS_ACCOUNT_ID}" "${TEMPOUT}" "${ARM_AMI_ID}" "${AMD_AMI_ID}" "${GPU_AMI_ID}"

CLUSTER_ENDPOINT="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --query "cluster.endpoint" --output text)"

# 🚀 Cài đặt Karpenter bằng Helm
echo "🔹 Cài đặt Karpenter với Helm..."
helm registry logout public.ecr.aws  # Logout để đảm bảo tải về chính xác

helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter --version "${KARPENTER_VERSION}" --namespace "${KARPENTER_NAMESPACE}" --create-namespace \
  --set "settings.clusterName=${CLUSTER_NAME}" \
  --set "settings.interruptionQueue=${CLUSTER_NAME}" \
  --set controller.resources.requests.cpu=1 \
  --set controller.resources.requests.memory=1Gi \
  --set controller.resources.limits.cpu=1 \
  --set controller.resources.limits.memory=1Gi \
  --wait || {
    echo "❌ LỖI: Cài đặt Karpenter thất bại! Kiểm tra lại.";
    exit 1;
}

echo "✅ Karpenter đã được cài đặt thành công trên cluster ${CLUSTER_NAME}!"
