#!/bin/bash

set -e  # Dừng script ngay khi có lỗi

STACK_NAME="LabVPC"
TEMPLATE_FILE="vpc.yaml"
BASTION_NAME="BastionHost"
KEY_NAME="bastion-key"
KEY_PATH="/home/cloudshell-user/acg.pem"  # Sử dụng file .pem luôn

echo "🚀 Bắt đầu tạo VPC Stack: $STACK_NAME..."
aws cloudformation deploy --stack-name "$STACK_NAME" \
    --template-file "$TEMPLATE_FILE" \
    --capabilities CAPABILITY_NAMED_IAM

echo "🔹 Đang đợi Stack $STACK_NAME hoàn thành..."

# Lấy VPC ID
VPC_ID=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --query "Stacks[0].Outputs[?OutputKey=='VPCId'].OutputValue" --output text)
if [[ -z "$VPC_ID" ]]; then
    echo "❌ Không thể lấy VPC ID, kiểm tra lại stack!"
    exit 1
fi
echo "✅ VPC ID: $VPC_ID"

# Lấy Public Subnet 1A
PUBLIC_SUBNET_ID=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --query "Stacks[0].Outputs[?OutputKey=='PublicSubnet1Id'].OutputValue" --output text)
if [[ -z "$PUBLIC_SUBNET_ID" ]]; then
    echo "❌ Không tìm thấy Public Subnet. Kiểm tra lại!"
    exit 1
fi
echo "✅ Public Subnet: $PUBLIC_SUBNET_ID"

# Lấy Security Group cho Bastion Public
BASTION_SG_ID=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --query "Stacks[0].Outputs[?OutputKey=='BastionPublicSecurityGroupId'].OutputValue" --output text)
if [[ -z "$BASTION_SG_ID" ]]; then
    echo "❌ Không tìm thấy Security Group cho Bastion. Kiểm tra lại!"
    exit 1
fi
echo "✅ Security Group cho Bastion: $BASTION_SG_ID"

# 🔑 Upload KeyPair từ file .pem luôn (không cần convert)
echo "🔹 Kiểm tra KeyPair trên AWS..."
if aws ec2 describe-key-pairs --key-names "$KEY_NAME" &>/dev/null; then
    echo "✅ KeyPair '$KEY_NAME' đã tồn tại."
else
    echo "🔹 Đang upload KeyPair từ file $KEY_PATH..."
    
    aws ec2 import-key-pair --key-name "$KEY_NAME" --public-key-material fileb://"$KEY_PATH"
    echo "✅ KeyPair '$KEY_NAME' đã được upload thành công."
fi

# 🔹 Lấy AMI mới nhất của Amazon Linux 2
AMI_ID=$(aws ssm get-parameters --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query "Parameters[0].Value" --output text)
if [[ -z "$AMI_ID" || "$AMI_ID" == "None" ]]; then
    echo "❌ Không tìm thấy AMI ID. Kiểm tra lại!"
    exit 1
fi
echo "✅ AMI ID: $AMI_ID"

# 🔹 Tạo Bastion Host
echo "🚀 Tạo Bastion Host..."
INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "t3a.large" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$BASTION_SG_ID" \
    --subnet-id "$PUBLIC_SUBNET_ID" \
    --associate-public-ip-address \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=BastionHost},{Key=env,Value=lab}]" \
    --query "Instances[0].InstanceId" --output text)

if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "None" ]]; then
    echo "❌ Không thể tạo Bastion Host. Kiểm tra lại!"
    exit 1
fi
echo "✅ Bastion Host Instance ID: $INSTANCE_ID"

# 🔹 Lấy Public IP của Bastion Host
echo "⏳ Đang đợi Bastion Host khởi động..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"

BASTION_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
if [[ -z "$BASTION_IP" || "$BASTION_IP" == "None" ]]; then
    echo "❌ Không tìm thấy Public IP của Bastion Host. Kiểm tra lại!"
    exit 1
fi
echo "✅ Bastion Host có Public IP: $BASTION_IP"

echo "🎉 Hoàn thành! Bạn có thể SSH vào Bastion Host bằng lệnh sau:"
echo "ssh -i $KEY_PATH ec2-user@$BASTION_IP"
