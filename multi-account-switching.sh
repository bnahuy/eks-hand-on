#!/bin/bash

# Script để lấy MFA session token cho các môi trường AWS

# Clear các biến AWS cũ để tránh xung đột
unset AWS_ACCESS_KEY_ID
unset AWS_SECRET_ACCESS_KEY
unset AWS_SESSION_TOKEN
unset AWS_PROFILE

# Hiển thị menu chọn môi trường
echo "Chọn môi trường:"
echo "1. DEV"
echo "2. STG"
echo "3. PRD"
read -p "Nhập số (1 hoặc 2 hoac 3): " choice

# Thiết lập biến môi trường dựa trên lựa chọn
case $choice in
    1)
        AWS_PROFILE="DEV-STG"
        EKS_CLUSTER_NAME="mas-high-tech-dev"
        MFA_DEVICE_ARN="arn:aws:iam::051826720730:mfa/DEV-STG"
        ROLE_ARN="arn:aws:iam::051826720730:role/OM-AdministratorAccess"
        ;;
    2)
        AWS_PROFILE="DEV-STG"
        EKS_CLUSTER_NAME="mas-high-tech-staging"
        MFA_DEVICE_ARN="arn:aws:iam::051826720730:mfa/DEV-STG"
        ROLE_ARN="arn:aws:iam::051826720730:role/OM-AdministratorAccess"
        ;;
    3)
        AWS_PROFILE="PRD"
        EKS_CLUSTER_NAME="mas-high-tech-production"
        MFA_DEVICE_ARN="arn:aws:iam::084828561255:mfa/PRD"
        ROLE_ARN="arn:aws:iam::084828561255:role/OM-AdministratorAccess"
        ;;
    *)
        echo "Lựa chọn không hợp lệ"
        return 1
        ;;
esac

echo "Đang cấu hình cho môi trường: $AWS_PROFILE"

# Thiết lập AWS profile
export AWS_PROFILE

# Lấy credentials từ profile được chọn
AWS_ACCESS_KEY_ID=$(aws configure get aws_access_key_id --profile $AWS_PROFILE)
AWS_SECRET_ACCESS_KEY=$(aws configure get aws_secret_access_key --profile $AWS_PROFILE)

# Kiểm tra xem có lấy được credentials không
if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
    echo "Không thể lấy được AWS credentials từ profile $AWS_PROFILE"
    echo "Vui lòng kiểm tra file ~/.aws/credentials"
    return 1
fi

# Xuất credentials tạm thời
export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY

# Yêu cầu nhập MFA token
read -p "Nhập OTP từ MFA: " MFA_TOKEN

# Lấy session token với MFA
MFA_CREDS=$(aws sts get-session-token \
    --serial-number "$MFA_DEVICE_ARN" \
    --token-code "$MFA_TOKEN" \
    --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
    --output text)

# Kiểm tra nếu lệnh AWS CLI có thành công hay không
if [ $? -ne 0 ]; then
    echo "Lỗi khi gọi AWS CLI. Vui lòng kiểm tra lại OTP hoặc cấu hình AWS."
    return 1
fi

# Tách các giá trị từ MFA_CREDS
MFA_AWS_ACCESS_KEY_ID=$(echo "$MFA_CREDS" | awk '{print $1}')
MFA_AWS_SECRET_ACCESS_KEY=$(echo "$MFA_CREDS" | awk '{print $2}')
MFA_AWS_SESSION_TOKEN=$(echo "$MFA_CREDS" | awk '{print $3}')

# Bước 2: Assume role với session token từ MFA
ASSUME_ROLE_CREDS=$(AWS_ACCESS_KEY_ID="$MFA_AWS_ACCESS_KEY_ID" \
    AWS_SECRET_ACCESS_KEY="$MFA_AWS_SECRET_ACCESS_KEY" \
    AWS_SESSION_TOKEN="$MFA_AWS_SESSION_TOKEN" \
    aws sts assume-role \
    --role-arn "$ROLE_ARN" \
    --role-session-name "my-session-$AWS_PROFILE" \
    --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
    --output text)

# Kiểm tra nếu lệnh AWS CLI có thành công hay không
if [ $? -ne 0 ]; then
    echo "Lỗi khi assume role. Vui lòng kiểm tra lại thông tin."
    return 1
fi

# Tách các giá trị trong biến ASSUME_ROLE_CREDS
AWS_ACCESS_KEY_ID=$(echo "$ASSUME_ROLE_CREDS" | awk '{print $1}')
AWS_SECRET_ACCESS_KEY=$(echo "$ASSUME_ROLE_CREDS" | awk '{print $2}')
AWS_SESSION_TOKEN=$(echo "$ASSUME_ROLE_CREDS" | awk '{print $3}')

# Xuất các biến môi trường
export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
export AWS_SESSION_TOKEN

# In ra các giá trị để kiểm tra
echo "Đã assume role cho môi trường $AWS_PROFILE thành công:"
echo "  AWS_ACCESS_KEY_ID: $AWS_ACCESS_KEY_ID"
echo "  AWS_SECRET_ACCESS_KEY: **** (được ẩn)"
echo "  AWS_SESSION_TOKEN: **** (được ẩn)"

# Kiểm tra caller identity để xác nhận
echo "Kiểm tra caller identity:"
aws sts get-caller-identity

echo ""
echo "Đang update kubeconfig cho cluster: $EKS_CLUSTER_NAME"
aws eks update-kubeconfig --region ap-southeast-1 --name $EKS_CLUSTER_NAME

echo ""
echo "✅ Hoàn thành! Các biến môi trường đã được export:"
echo "  AWS_ACCESS_KEY_ID: $AWS_ACCESS_KEY_ID"
echo "  AWS_SECRET_ACCESS_KEY: **** (được ẩn)"
echo "  AWS_SESSION_TOKEN: **** (được ẩn)"
echo "  EKS_CLUSTER_NAME: $EKS_CLUSTER_NAME"
echo ""
echo "Bây giờ bạn có thể sử dụng AWS CLI và kubectl với role credentials."
                                                                            
