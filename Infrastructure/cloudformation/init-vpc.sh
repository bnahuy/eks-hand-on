#!/bin/bash

STACK_NAME="LabVPC"
TEMPLATE_FILE="vpc.yaml"

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
