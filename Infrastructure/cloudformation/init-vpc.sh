#!/bin/bash

STACK_NAME="LabVPC"
TEMPLATE_FILE="vpc.yaml"

echo "🚀 Bắt đầu tạo VPC Stack: $STACK_NAME..."
aws cloudformation create-stack --stack-name "$STACK_NAME" \
    --template-body "file://$TEMPLATE_FILE" \
    --capabilities CAPABILITY_NAMED_IAM

echo "🔹 Đang đợi Stack $STACK_NAME hoàn thành..."

# Biến theo dõi thời gian
TOTAL_TIME=0
LAST_STATUS=""

# Hàm theo dõi trạng thái stack
function monitor_stack() {
    local start_time=$(date +%s.%N)  # Lưu thời gian bắt đầu

    while true; do
        STACK_STATUS=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
            --query "Stacks[0].StackStatus" --output text 2>/dev/null)

        if [[ -z "$STACK_STATUS" ]]; then
            echo "❌ Không thể lấy trạng thái stack. Kiểm tra lại AWS CLI."
            exit 1
        fi

        if [[ "$STACK_STATUS" != "$LAST_STATUS" ]]; then
            # Nếu trạng thái thay đổi, tính tổng thời gian trạng thái trước đó
            local now_time=$(date +%s.%N)
            local duration=$(echo "$now_time - $start_time" | bc)
            TOTAL_TIME=$(echo "$TOTAL_TIME + $duration" | bc)

            echo "🔄 Trạng thái thay đổi: $LAST_STATUS → $STACK_STATUS (⏱️ $(printf "%.2f" "$duration") giây)"

            # Reset thời gian bắt đầu
            start_time=$(date +%s.%N)
            LAST_STATUS="$STACK_STATUS"
        fi

        case "$STACK_STATUS" in
            CREATE_IN_PROGRESS)
                local now_time=$(date +%s.%N)
                local elapsed=$(echo "$now_time - $start_time" | bc)
                echo -ne "\r⏳ Stack đang được tạo... [CREATE_IN_PROGRESS] (⏱️ $(printf "%.2f" "$elapsed") giây)   "
                ;;
            CREATE_COMPLETE)
                local now_time=$(date +%s.%N)
                local duration=$(echo "$now_time - $start_time" | bc)
                TOTAL_TIME=$(echo "$TOTAL_TIME + $duration" | bc)
                echo -e "\n✅ Stack $STACK_NAME đã được tạo thành công! (⏱️ $(printf "%.2f" "$duration") giây)"
                return
                ;;
            CREATE_FAILED)
                local now_time=$(date +%s.%N)
                local duration=$(echo "$now_time - $start_time" | bc)
                TOTAL_TIME=$(echo "$TOTAL_TIME + $duration" | bc)
                echo -e "\n❌ Stack $STACK_NAME gặp lỗi khi tạo! (⏱️ $(printf "%.2f" "$duration") giây)"
                exit 1
                ;;
            ROLLBACK_IN_PROGRESS|ROLLBACK_COMPLETE)
                local now_time=$(date +%s.%N)
                local duration=$(echo "$now_time - $start_time" | bc)
                TOTAL_TIME=$(echo "$TOTAL_TIME + $duration" | bc)
                echo -e "\n⚠️ Stack bị rollback. Kiểm tra CloudFormation logs! (⏱️ $(printf "%.2f" "$duration") giây)"
                exit 1
                ;;
            *)
                local now_time=$(date +%s.%N)
                local duration=$(echo "$now_time - $start_time" | bc)
                TOTAL_TIME=$(echo "$TOTAL_TIME + $duration" | bc)
                echo -e "\n⚠️ Trạng thái không xác định: $STACK_STATUS (⏱️ $(printf "%.2f" "$duration") giây)"
                exit 1
                ;;
        esac

        sleep 1  # Cập nhật mỗi giây
    done
}

# Gọi hàm theo dõi stack
monitor_stack

echo -e "\n🎉 Quá trình tạo VPC hoàn tất sau $(printf "%.2f" "$TOTAL_TIME") giây!"
