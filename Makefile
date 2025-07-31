SHELL := /bin/bash

ifneq (,$(wildcard .env))
    include .env
    export
endif

PYTHON := python3
PIP := pip3
AWS := aws
MAIN_FILE := parking.py
REQUIREMENTS := requirements.txt

AWS_LAMBDA_FUNCTION_NAME ?= parking-booking
DEPLOYMENT_PACKAGE_ZIP := $(AWS_LAMBDA_FUNCTION_NAME).zip
AWS_FUNCTION_DOCKER_IMAGE_NAME := $(AWS_LAMBDA_FUNCTION_NAME)

AWS_REGION ?= eu-west-1
AWS_ECR_REPO := $(AWS_LAMBDA_FUNCTION_NAME)
DATE_TAG := $(shell date +%Y%m%d)
TAGS := latest $(DATE_TAG)

.DEFAULT_GOAL := help

# General
# -----------------------------------------------------------------------------
##@ General

.PHONY: help
help:  ## Show this help message
	@echo "Available commands:"
	@awk 'BEGIN {FS = ":.*?##"} \
	/^##@/ {print "\n" substr($$0, 5)} \
	/^[a-zA-Z0-9_-]+:.*?##/ {printf "  make %-20s - %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# Setup
# -----------------------------------------------------------------------------
##@ Setup

.PHONY: install
install:  ## Install dependencies from requirements.txt
	$(PIP) install -r $(REQUIREMENTS)

.PHONY: clean
clean:  ## Remove temporary files, caches, and build artifacts
	@echo "Cleaning up temporary files and caches..."
	find . -type f -name '*.pyc' -delete
	find . -type d -name '__pycache__' -delete
	rm -rf .pytest_cache $(DEPLOYMENT_PACKAGE_ZIP)

# Run
# -----------------------------------------------------------------------------
##@ Run

.PHONY: run
run:  ## Run the Lambda function locally
	$(PYTHON) $(MAIN_FILE)

# Deployment
# -----------------------------------------------------------------------------
##@ Deployment

.PHONY: build-on-docker
build-on-docker: clean ## Create a deployment package for AWS Lambda using Docker
	@echo "Building Lambda package using Docker..."
	docker build -t lambda-build .
	docker create --name lambda-build-container lambda-build
	docker cp lambda-build-container:/out/function.zip ./$(DEPLOYMENT_PACKAGE_ZIP)
	docker rm lambda-build-container
	@echo "Deployment package $(DEPLOYMENT_PACKAGE_ZIP) created."

.PHONY: create-env
create-env: ## Create env
	-$(AWS) iam create-role \
		--role-name lambda-role \
		--assume-role-policy-document file://trust-policy.json || true
	-$(AWS) iam attach-role-policy \
		--role-name lambda-role \
		--policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole || true
	@echo "Waiting for IAM role propagation..."
	sleep 15
	@if [ -f .env ]; then \
		echo "Creating Lambda function with environment variables from .env file..."; \
		@echo '{' > env-vars-temp.json; \
		@echo '  "Variables": {' >> env-vars-temp.json; \
		@grep -v '^#' .env | grep -v '^$$' | grep -v '^AWS_REGION=' | grep -v '^AWS_ACCOUNT_ID=' | grep -v '^AWS_LAMBDA_FUNCTION_NAME=' | grep -v '^BOOKING_DATE=' | sed 's/^/    "/;s/=/": "/;s/$$/",/' >> env-vars-temp.json; \
		@sed -i '' '$$ s/,$$//' env-vars-temp.json; \
		@echo '  }' >> env-vars-temp.json; \
		@echo '}' >> env-vars-temp.json; \
		$(AWS) lambda create-function \
			--function-name $(AWS_LAMBDA_FUNCTION_NAME) \
			--runtime python3.12 \
			--role arn:aws:iam::$(AWS_ACCOUNT_ID):role/lambda-role \
			--handler parking.lambda_handler \
			--zip-file fileb://$(DEPLOYMENT_PACKAGE_ZIP) \
			--region $(AWS_REGION) \
			--environment file://env-vars-temp.json; \
		@rm env-vars-temp.json; \
	else \
		echo "Creating Lambda function without environment variables (no .env file found)..."; \
		$(AWS) lambda create-function \
			--function-name $(AWS_LAMBDA_FUNCTION_NAME) \
			--runtime python3.12 \
			--role arn:aws:iam::$(AWS_ACCOUNT_ID):role/lambda-role \
			--handler parking.lambda_handler \
			--zip-file fileb://$(DEPLOYMENT_PACKAGE_ZIP) \
			--region $(AWS_REGION); \
	fi

.PHONY: update-env
update-env: ## Update Lambda function environment variables from .env file
	@if [ ! -f .env ]; then \
		echo "Error: .env file not found. Please create a .env file with your environment variables."; \
		exit 1; \
	fi
	@echo "Updating Lambda function environment variables from .env file..."
	@echo '{' > env-vars-temp.json
	@echo '  "Variables": {' >> env-vars-temp.json
	@grep -v '^#' .env | grep -v '^$$' | grep -v '^AWS_REGION=' | grep -v '^AWS_ACCOUNT_ID=' | grep -v '^AWS_LAMBDA_FUNCTION_NAME=' | grep -v '^BOOKING_DATE=' | sed 's/^/    "/;s/=/": "/;s/$$/",/' >> env-vars-temp.json
	@sed -i '' '$$ s/,$$//' env-vars-temp.json
	@echo '  }' >> env-vars-temp.json
	@echo '}' >> env-vars-temp.json
	$(AWS) lambda update-function-configuration \
		--function-name $(AWS_LAMBDA_FUNCTION_NAME) \
		--region $(AWS_REGION) \
		--environment file://env-vars-temp.json
	@rm env-vars-temp.json
	@echo "Environment variables updated successfully."

.PHONY: deploy
deploy: build-on-docker ## Deploy the Lambda function directly
	@echo "Deploying Lambda function directly..."
	$(AWS) lambda update-function-code \
		--function-name $(AWS_LAMBDA_FUNCTION_NAME) \
		--zip-file fileb://$(DEPLOYMENT_PACKAGE_ZIP) \
		--region $(AWS_REGION)
	@if [ -f .env ]; then \
		echo "Updating environment variables from .env file..."; \
		$(MAKE) update-env; \
	fi

.PHONY: create-schedule
create-schedule: ## Create EventBridge schedule for Lambda
	@if [ -z "$(AWS_LAMBDA_FUNCTION_NAME)" ] || [ "$(AWS_LAMBDA_FUNCTION_NAME)" = "-" ]; then \
	  echo "Error: AWS_LAMBDA_FUNCTION_NAME is not set. Please set it via .env or as a make variable."; exit 1; \
	fi
	@if [ -z "$(AWS_REGION)" ]; then \
	  echo "Error: AWS_REGION is not set. Please set it via .env or as a make variable."; exit 1; \
	fi
	@if [ -z "$(AWS_ACCOUNT_ID)" ]; then \
	  echo "Error: AWS_ACCOUNT_ID is not set. Please set it via .env or as a make variable."; exit 1; \
	fi
	@echo "Creating EventBridge schedule..."
	@sed "s/\$${AWS_REGION}/$(AWS_REGION)/g; s/\$${AWS_ACCOUNT_ID}/$(AWS_ACCOUNT_ID)/g; s/\$${AWS_LAMBDA_FUNCTION_NAME}/$(AWS_LAMBDA_FUNCTION_NAME)/g" eventbridge-rule.json > eventbridge-rule-temp.json
	@sed "s/\$${AWS_REGION}/$(AWS_REGION)/g; s/\$${AWS_ACCOUNT_ID}/$(AWS_ACCOUNT_ID)/g; s/\$${AWS_LAMBDA_FUNCTION_NAME}/$(AWS_LAMBDA_FUNCTION_NAME)/g" eventbridge-targets.json > eventbridge-targets-temp.json
	$(AWS) events put-rule --cli-input-json file://eventbridge-rule-temp.json
	$(AWS) lambda add-permission \
		--function-name $(AWS_LAMBDA_FUNCTION_NAME) \
		--statement-id EventBridgeInvoke \
		--action lambda:InvokeFunction \
		--principal events.amazonaws.com \
		--source-arn arn:aws:events:$(AWS_REGION):$(AWS_ACCOUNT_ID):rule/parking-lambda-schedule
	$(AWS) events put-targets \
		--rule parking-lambda-schedule \
		--targets file://eventbridge-targets-temp.json
	rm eventbridge-rule-temp.json eventbridge-targets-temp.json
	@echo "Schedule created successfully."

# Docker
# -----------------------------------------------------------------------------
##@ Docker

.PHONY: clean-images
clean-images:  ## Remove Docker images locally
	@for tag in $(TAGS); do \
		docker rmi $(AWS_FUNCTION_DOCKER_IMAGE_NAME):$$tag || true; \
		docker rmi $(AWS_ACCOUNT_ID).dkr.ecr.$$(AWS_REGION).amazonaws.com/$(AWS_ECR_REPO):$$tag || true; \
	done
