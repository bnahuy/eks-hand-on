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

curl -fsSL https://raw.githubusercontent.com/aws/karpenter-provider-aws/v"${KARPENTER_VERSION}"/website/content/en/preview/getting-started/getting-started-with-karpenter/cloudformation.yaml  > "${TEMPOUT}" \
&& aws cloudformation deploy \
  --stack-name "Karpenter-${CLUSTER_NAME}" \
  --template-file "${TEMPOUT}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides "ClusterName=${CLUSTER_NAME}"

echo "🔹 Đang tìm VPC có tag env=lab..."
VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=tag:env,Values=lab" \
    --query "Vpcs[0].VpcId" --output text)

CIDR_BLOCK=$(aws ec2 describe-vpcs \
    --filters "Name=tag:env,Values=lab" \
    --query "Vpcs[0].CidrBlock" --output text)

# Kiểm tra nếu không tìm thấy VPC
if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
    echo "❌ Không tìm thấy VPC có tag env=lab. Kiểm tra lại!"
    exit 1
fi
echo "✅ VPC tìm thấy: $VPC_ID (CIDR: $CIDR_BLOCK)"

echo "🔹 Đang tìm Private Subnets theo VPC ID..."
PRIVATE_SUBNETS=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=map-public-ip-on-launch,Values=false" \
    --query "Subnets[*].[SubnetId,AvailabilityZone]" --output json)

# Lấy Subnet ID & AZ
PRIVATE_SUBNET_1_ID=$(echo $PRIVATE_SUBNETS | jq -r '.[0][0]')
PRIVATE_SUBNET_1_AZ=$(echo $PRIVATE_SUBNETS | jq -r '.[0][1]')
PRIVATE_SUBNET_2_ID=$(echo $PRIVATE_SUBNETS | jq -r '.[1][0]')
PRIVATE_SUBNET_2_AZ=$(echo $PRIVATE_SUBNETS | jq -r '.[1][1]')

# Kiểm tra nếu không có subnet nào được tìm thấy
if [[ -z "$PRIVATE_SUBNETS" || "$PRIVATE_SUBNETS" == "[]" ]]; then
    echo "❌ Không tìm thấy Private Subnet nào trong VPC: $VPC_ID. Kiểm tra lại!"
    exit 1
fi

# Lấy Subnet ID & AZ động, chỉ lấy AZ kết thúc bằng "a"
PRIVATE_SUBNET_1A_ID=""
PRIVATE_SUBNET_1A_AZ=""

for row in $(echo "$PRIVATE_SUBNETS" | jq -c '.[]'); do
    SUBNET_ID=$(echo "$row" | jq -r '.[0]')
    AZ=$(echo "$row" | jq -r '.[1]')

    # Kiểm tra nếu AZ kết thúc bằng "a"
    if echo "$AZ" | grep -Eq "[a]$"; then
        PRIVATE_SUBNET_1A_ID="$SUBNET_ID"
        PRIVATE_SUBNET_1A_AZ="$AZ"
        break
    fi
done

# Kiểm tra nếu không tìm thấy AZ nào kết thúc bằng "a"
if [[ -z "$PRIVATE_SUBNET_1A_ID" ]]; then
    echo "❌ LỖI: Không tìm thấy Private Subnet trong AZ kết thúc bằng 'a'. Kiểm tra lại Subnets!"
    exit 1
fi

echo "✅ Chọn AZ: $PRIVATE_SUBNET_1A_AZ (Subnet: $PRIVATE_SUBNET_1A_ID)"


echo "🔹 Đang tìm Security Group 'bastion-host' hoặc có tag env=lab..."
BASTION_SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:env,Values=lab" \
    --query "SecurityGroups[0].GroupId" --output text)

# Nếu không tìm thấy theo tag, thử tìm theo group-name
if [[ -z "$BASTION_SG_ID" || "$BASTION_SG_ID" == "None" ]]; then
    echo "⚠️ Không tìm thấy Security Group theo tag env=lab, thử tìm theo group-name..."
    BASTION_SG_ID=$(aws ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=bastion-host" \
        --query "SecurityGroups[0].GroupId" --output text)
fi

# Nếu vẫn không tìm thấy, báo lỗi
if [[ -z "$BASTION_SG_ID" || "$BASTION_SG_ID" == "None" ]]; then
    echo "❌ Không tìm thấy Security Group hợp lệ! Kiểm tra lại tag hoặc tên Security Group."
    exit 1
fi
echo "✅ Security Group ID của Bastion Host: $BASTION_SG_ID"

EKS_CONFIG_FILE="/tmp/eks-private-cluster.yaml"

echo "🔹 Tạo file cấu hình EKS tại $EKS_CONFIG_FILE..."
cat <<EOF > "$EKS_CONFIG_FILE"
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: ${CLUSTER_NAME}
  region: ${AWS_DEFAULT_REGION}
  version: "${K8S_VERSION}"
  tags:
    karpenter.sh/discovery: ${CLUSTER_NAME}

iam:
  withOIDC: true
  podIdentityAssociations:
  - namespace: "${KARPENTER_NAMESPACE}"
    serviceAccountName: karpenter
    roleName: ${CLUSTER_NAME}-karpenter
    permissionPolicyARNs:
    - arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:policy/KarpenterControllerPolicy-${CLUSTER_NAME}
    
iamIdentityMappings:
- arn: "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:role/KarpenterNodeRole-${CLUSTER_NAME}"
  username: system:node:{{EC2PrivateDNSName}}
  groups:
  - system:bootstrappers
  - system:nodes

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

managedNodeGroups:
  - name: "${CLUSTER_NAME}-worker"
    instanceType: t3.micro
    amiFamily: Bottlerocket
    availabilityZones:
      - "$PRIVATE_SUBNET_1A_AZ"
    desiredCapacity: 2
    minSize: 2
    maxSize: 4
    maxPodsPerNode: 17
    privateNetworking: true
    ssh:
      allow: true
      publicKeyPath: /home/cloudshell-user/myown.pub
      sourceSecurityGroupIds: ["$BASTION_SG_ID"]

addons:
  - name: kube-proxy
  - name: coredns
  - name: eks-pod-identity-agent
EOF

echo "✅ File cấu hình EKS đã được tạo tại: $EKS_CONFIG_FILE"
echo "🚀 Bắt đầu triển khai Private EKS Cluster..."
if eksctl create cluster -f "$EKS_CONFIG_FILE"; then
    echo "✅ EKS Private Cluster đã được triển khai thành công!"
else
    echo "❌ LỖI: Tạo cluster thất bại! Kiểm tra lại log lỗi bên trên."
    exit 1
fi

CLUSTER_ENDPOINT="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --query "cluster.endpoint" --output text)"
KARPENTER_IAM_ROLE_ARN="arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:role/${CLUSTER_NAME}-karpenter"

echo "${CLUSTER_ENDPOINT} ${KARPENTER_IAM_ROLE_ARN}"

# 🛡️ Verify Karpenter image trước khi cài đặt
echo "🔹 Xác minh Karpenter image với Cosign..."
cosign verify public.ecr.aws/karpenter/karpenter:${KARPENTER_VERSION} \
  --certificate-oidc-issuer=https://token.actions.githubusercontent.com \
  --certificate-identity-regexp='https://github\.com/aws/karpenter-provider-aws/\.github/workflows/release\.yaml@.+' \
  --certificate-github-workflow-repository=aws/karpenter-provider-aws \
  --certificate-github-workflow-name=Release \
  --certificate-github-workflow-ref=refs/tags/v${KARPENTER_VERSION} \
  --annotations version=${KARPENTER_VERSION} || { 
    echo "❌ LỖI: Xác minh Karpenter image thất bại! Kiểm tra lại.";
    exit 1;
}

echo "✅ Karpenter image đã được xác minh!"

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
