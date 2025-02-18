#!/bin/bash

KARPENTER_NAMESPACE="kube-system"
KARPENTER_VERSION="1.2.1"
K8S_VERSION="1.32"

AWS_PARTITION="aws"
CLUSTER_NAME="lab-eks-cluster"
AWS_DEFAULT_REGION="us-east-1"
AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
TEMPOUT="$(mktemp)"

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

# Kiểm tra nếu không có subnet nào được tìm thấy
if [[ -z "$PRIVATE_SUBNETS" || "$PRIVATE_SUBNETS" == "[]" ]]; then
    echo "❌ Không tìm thấy Private Subnet nào trong VPC: $VPC_ID. Kiểm tra lại!"
    exit 1
fi

# Lấy Subnet ID & AZ động, chỉ lấy "X-1a"
PRIVATE_SUBNET_1A_ID=""
PRIVATE_SUBNET_1A_AZ=""

for row in $(echo "$PRIVATE_SUBNETS" | jq -c '.[]'); do
    SUBNET_ID=$(echo "$row" | jq -r '.[0]')
    AZ=$(echo "$row" | jq -r '.[1]')

    if [[ "$AZ" =~ (us-east|ap-southeast|eu-central)-[0-9]+a$ ]]; then
        PRIVATE_SUBNET_1A_ID="$SUBNET_ID"
        PRIVATE_SUBNET_1A_AZ="$AZ"
        break
    fi
done

if [[ -z "$PRIVATE_SUBNET_1A_ID" || "$PRIVATE_SUBNET_1A_ID" == "None" ]]; then
    echo "❌ Không tìm thấy Private Subnet trong AZ phù hợp (X-1a). Kiểm tra lại Subnets!"
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
