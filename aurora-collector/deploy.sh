#!/bin/bash
set -e

# Aurora PostgreSQL Long-Running Query Collector Deployment Script
# Usage: ./deploy.sh <stack-name> <parameters-file>

STACK_NAME="${1:-aurora-query-collector}"
PARAMS_FILE="${2:-parameters.json}"
REGION="${AWS_REGION:-us-east-1}"
S3_BUCKET="${SAM_BUCKET:-}"

echo "=============================================="
echo "Aurora Query Collector Deployment"
echo "=============================================="
echo "Stack Name: $STACK_NAME"
echo "Region: $REGION"
echo "Parameters: $PARAMS_FILE"
echo ""

# Check prerequisites
check_prerequisites() {
    echo "Checking prerequisites..."

    if ! command -v sam &> /dev/null; then
        echo "ERROR: AWS SAM CLI is not installed"
        echo "Install it from: https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/install-sam-cli.html"
        exit 1
    fi

    if ! command -v aws &> /dev/null; then
        echo "ERROR: AWS CLI is not installed"
        exit 1
    fi

    if ! aws sts get-caller-identity &> /dev/null; then
        echo "ERROR: AWS credentials not configured"
        exit 1
    fi

    echo "Prerequisites OK"
}

# Build the Lambda package
build() {
    echo ""
    echo "Building Lambda package..."
    sam build --use-container
    echo "Build complete"
}

# Deploy the stack
deploy() {
    echo ""
    echo "Deploying stack..."

    DEPLOY_ARGS="--stack-name $STACK_NAME --region $REGION --capabilities CAPABILITY_IAM"

    if [ -f "$PARAMS_FILE" ]; then
        echo "Using parameters from: $PARAMS_FILE"
        DEPLOY_ARGS="$DEPLOY_ARGS --parameter-overrides file://$PARAMS_FILE"
    fi

    if [ -n "$S3_BUCKET" ]; then
        DEPLOY_ARGS="$DEPLOY_ARGS --s3-bucket $S3_BUCKET"
    fi

    sam deploy $DEPLOY_ARGS --no-confirm-changeset

    echo ""
    echo "Deployment complete!"
}

# Show outputs
show_outputs() {
    echo ""
    echo "Stack Outputs:"
    aws cloudformation describe-stacks \
        --stack-name $STACK_NAME \
        --region $REGION \
        --query 'Stacks[0].Outputs' \
        --output table
}

# Test the function
test_function() {
    echo ""
    echo "Testing Lambda function..."

    FUNCTION_NAME=$(aws cloudformation describe-stacks \
        --stack-name $STACK_NAME \
        --region $REGION \
        --query 'Stacks[0].Outputs[?OutputKey==`FunctionName`].OutputValue' \
        --output text)

    echo "Invoking: $FUNCTION_NAME"
    aws lambda invoke \
        --function-name $FUNCTION_NAME \
        --region $REGION \
        --payload '{}' \
        response.json

    echo ""
    echo "Response:"
    cat response.json | python3 -m json.tool
    rm -f response.json
}

# Main execution
main() {
    check_prerequisites
    build
    deploy
    show_outputs

    read -p "Do you want to test the function? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        test_function
    fi
}

# Parse commands
case "${1:-deploy}" in
    build)
        check_prerequisites
        build
        ;;
    deploy)
        main
        ;;
    test)
        test_function
        ;;
    outputs)
        show_outputs
        ;;
    *)
        main
        ;;
esac
