aws cloudformation create-stack --stack-name LabVPC \
    --template-body file://vpc.yaml \
    --capabilities CAPABILITY_NAMED_IAM
