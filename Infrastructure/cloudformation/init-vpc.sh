#!/bin/bash

set -e  # Dừng script ngay khi có lỗi

STACK_NAME="LabVPC"
TEMPLATE_FILE="vpc.yaml"
BASTION_NAME="BastionHost"
KEY_NAME="bastion-key"
KEY_PATH="/home/cloudshell-user/acg.pem"  # Sử dụng file .pem luôn

echo "🚀 Bắt đầu tạo VPC Stack: $STACK_NAME..."
aws cloudformation create-stack --stack-name "$STACK_NAME" \
    --template-body "file://$TEMPLATE_FILE" \
    --capabilities CAPABILITY_NAMED_IAM

echo "🔹 Đang đợi Stack $STACK_NAME hoàn thành..."

# Hàm kiểm tra trạng thái Stack
function monitor_stack() {
    while true; do
        STACK_STATUS=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
            --query "Stacks[0].StackStatus" --output text 2>/dev/null)

        if [[ -z "$STACK_STATUS" ]]; then
            echo "❌ Không thể lấy trạng thái stack. Kiểm tra lại AWS CLI."
            exit 1
        fi

        case "$STACK_STATUS" in
            CREATE_IN_PROGRESS)
                echo "⏳ Stack đang được tạo... [CREATE_IN_PROGRESS]"
                ;;
            CREATE_COMPLETE)
                echo "✅ Stack $STACK_NAME đã được tạo thành công!"
                return
                ;;
            CREATE_FAILED)
                echo "❌ Stack $STACK_NAME gặp lỗi khi tạo!"
                exit 1
                ;;
            ROLLBACK_IN_PROGRESS|ROLLBACK_COMPLETE)
                echo "⚠️ Stack bị rollback. Kiểm tra CloudFormation logs!"
                exit 1
                ;;
            *)
                echo "⚠️ Trạng thái không xác định: $STACK_STATUS"
                exit 1
                ;;
        esac

        sleep 10  # Kiểm tra lại sau 10 giây
    done
}

# Gọi hàm monitor stack
monitor_stack

echo "🎉 Quá trình tạo VPC hoàn tất!"

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
PUBLIC_SUBNETS=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=map-public-ip-on-launch,Values=true" \
    --query "Subnets[*].[SubnetId,AvailabilityZone]" --output json)

# Lấy Subnet ID & AZ
PUBLIC_SUBNET_1_ID=$(echo $PUBLIC_SUBNETS | jq -r '.[0][0]')
PUBLIC_SUBNET_1_AZ=$(echo $PUBLIC_SUBNETS | jq -r '.[0][1]')
PUBLIC_SUBNET_2_ID=$(echo $PUBLIC_SUBNETS | jq -r '.[1][0]')
PUBLIC_SUBNET_2_AZ=$(echo $PUBLIC_SUBNETS | jq -r '.[1][1]')

# Kiểm tra nếu không có subnet nào được tìm thấy
if [[ -z "$PUBLIC_SUBNETS" || "$PUBLIC_SUBNETS" == "[]" ]]; then
    echo "❌ Không tìm thấy Public Subnet nào trong VPC: $VPC_ID. Kiểm tra lại!"
    exit 1
fi

# Lấy Subnet ID & AZ động, chỉ lấy AZ kết thúc bằng "a"
PUBLIC_SUBNET_1A_ID=""
PUBLIC_SUBNET_1A_AZ=""

for row in $(echo "$PUBLIC_SUBNETS" | jq -c '.[]'); do
    SUBNET_ID=$(echo "$row" | jq -r '.[0]')
    AZ=$(echo "$row" | jq -r '.[1]')

    # Kiểm tra nếu AZ kết thúc bằng "a"
    if echo "$AZ" | grep -Eq "[a]$"; then
        PUBLIC_UBNET_1A_ID="$SUBNET_ID"
        PUBLIC_SUBNET_1A_AZ="$AZ"
        break
    fi
done

# Kiểm tra nếu không tìm thấy AZ nào kết thúc bằng "a"
if [[ -z "$PUBLIC_SUBNET_1A_ID" ]]; then
    echo "❌ LỖI: Không tìm thấy Public Subnet trong AZ kết thúc bằng 'a'. Kiểm tra lại Subnets!"
    exit 1
fi

echo "✅ Chọn AZ: $PUBLIC_SUBNET_1A_AZ (Subnet: $PUBLIC_SUBNET_1A_ID)"


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
    --subnet-id "$PUBLIC_SUBNET_1A_ID" \
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
