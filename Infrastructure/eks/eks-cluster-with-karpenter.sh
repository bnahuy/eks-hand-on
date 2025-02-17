KARPENTER_NAMESPACE="kube-system"
KARPENTER_VERSION="1.2.1"
K8S_VERSION="1.32"

AWS_PARTITION="aws" # if you are not using standard partitions, you may need to configure to aws-cn / aws-us-gov
CLUSTER_NAME="lab-eks-cluster"
AWS_DEFAULT_REGION="us-east-1"
AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
TEMPOUT="$(mktemp)"
ARM_AMI_ID="$(aws ssm get-parameter --name /aws/service/eks/optimized-ami/${K8S_VERSION}/amazon-linux-2-arm64/recommended/image_id --query Parameter.Value --output text)"
AMD_AMI_ID="$(aws ssm get-parameter --name /aws/service/eks/optimized-ami/${K8S_VERSION}/amazon-linux-2/recommended/image_id --query Parameter.Value --output text)"
GPU_AMI_ID="$(aws ssm get-parameter --name /aws/service/eks/optimized-ami/${K8S_VERSION}/amazon-linux-2-gpu/recommended/image_id --query Parameter.Value --output text)"

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
  ## If you intend to run Windows workloads, the kube-proxy group should be specified.
  # For more information, see https://github.com/aws/karpenter/issues/5099.
  # - eks:kube-proxy-windows

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

CLUSTER_ENDPOINT="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --query "cluster.endpoint" --output text)"
KARPENTER_IAM_ROLE_ARN="arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:role/${CLUSTER_NAME}-karpenter"

echo "${CLUSTER_ENDPOINT} ${KARPENTER_IAM_ROLE_ARN}"
