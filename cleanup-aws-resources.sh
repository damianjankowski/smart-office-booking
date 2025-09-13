#!/bin/bash

set -e

echo "Starting AWS resource cleanup"

if ! aws sts get-caller-identity > /dev/null 2>&1; then
    echo "Error: AWS CLI is not configured or credentials are invalid"
    echo "Please run 'aws configure' first"
    exit 1
fi

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=$(aws configure get region || echo "eu-west-1")
AWS_LAMBDA_FUNCTION_NAME=${AWS_LAMBDA_FUNCTION_NAME:-parking-booking}

echo "AWS Account ID: $AWS_ACCOUNT_ID"
echo "AWS Region: $AWS_REGION"
echo "Lambda Function Name: $AWS_LAMBDA_FUNCTION_NAME"

echo "Removing EventBridge Rule and Targets"
if aws events describe-rule --name parking-lambda-schedule > /dev/null 2>&1; then
    echo "Removing targets from EventBridge rule"
    aws events remove-targets --rule parking-lambda-schedule --ids ParkingLambdaTarget 2>/dev/null || true
    
    echo "Deleting EventBridge rule"
    aws events delete-rule --name parking-lambda-schedule
    echo "EventBridge rule removed"
else
    echo "EventBridge rule 'parking-lambda-schedule' not found"
fi

echo "Removing Lambda Function"
if aws lambda get-function --function-name $AWS_LAMBDA_FUNCTION_NAME > /dev/null 2>&1; then
    echo "Removing Lambda permissions"
    aws lambda remove-permission --function-name $AWS_LAMBDA_FUNCTION_NAME --statement-id EventBridgeInvoke 2>/dev/null || true
    
    echo "Deleting Lambda function"
    aws lambda delete-function --function-name $AWS_LAMBDA_FUNCTION_NAME
    echo "Lambda function removed"
else
    echo "Lambda function '$AWS_LAMBDA_FUNCTION_NAME' not found"
fi

echo "Removing IAM Role and Policy"
if aws iam get-role --role-name lambda-role > /dev/null 2>&1; then
    echo "Detaching IAM policy"
    aws iam detach-role-policy --role-name lambda-role --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null || true
    
    echo "Deleting IAM role"
    aws iam delete-role --role-name lambda-role
    echo "IAM role removed"
else
    echo "IAM role 'lambda-role' not found"
fi