#!/bin/bash

set -e

echo "============================================"
echo "  GitHub Token Function - Azure Deployment"
echo "============================================"
echo ""

# Collect required information
read -p "Function App name: " FUNCTION_APP_NAME
read -p "Resource Group name: " RESOURCE_GROUP
read -p "Storage Account name (3-24 chars, lowercase alphanumeric): " STORAGE_ACCOUNT
read -p "Location [eastus]: " LOCATION
LOCATION=${LOCATION:-eastus}

echo ""
echo "--- GitHub App Configuration ---"
read -p "GitHub App ID: " GITHUB_APP_ID
read -p "GitHub Installation ID: " GITHUB_INSTALLATION_ID
read -p "Path to private key .pem file: " PRIVATE_KEY_PATH

# Validate inputs
if [[ -z "$FUNCTION_APP_NAME" || -z "$RESOURCE_GROUP" || -z "$STORAGE_ACCOUNT" ]]; then
    echo "Error: Function App name, Resource Group, and Storage Account are required."
    exit 1
fi

if [[ -z "$GITHUB_APP_ID" || -z "$GITHUB_INSTALLATION_ID" || -z "$PRIVATE_KEY_PATH" ]]; then
    echo "Error: GitHub App ID, Installation ID, and private key path are required."
    exit 1
fi

if [[ ! -f "$PRIVATE_KEY_PATH" ]]; then
    echo "Error: Private key file not found at: $PRIVATE_KEY_PATH"
    exit 1
fi

# Validate storage account name
if [[ ! "$STORAGE_ACCOUNT" =~ ^[a-z0-9]{3,24}$ ]]; then
    echo "Error: Storage account name must be 3-24 lowercase alphanumeric characters."
    exit 1
fi

echo ""
echo "--- Configuration Summary ---"
echo "Function App:    $FUNCTION_APP_NAME"
echo "Resource Group:  $RESOURCE_GROUP"
echo "Storage Account: $STORAGE_ACCOUNT"
echo "Location:        $LOCATION"
echo "GitHub App ID:   $GITHUB_APP_ID"
echo "Installation ID: $GITHUB_INSTALLATION_ID"
echo "Private Key:     $PRIVATE_KEY_PATH"
echo ""

read -p "Proceed with deployment? [y/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Deployment cancelled."
    exit 0
fi

echo ""
echo "--- Checking Azure CLI authentication ---"
if ! az account show > /dev/null 2>&1; then
    echo "Error: Not logged in to Azure CLI. Run 'az login' first."
    exit 1
fi

SUBSCRIPTION=$(az account show --query "name" -o tsv)
echo "Using subscription: $SUBSCRIPTION"
echo ""

# Check if resource group exists
echo "--- Checking resource group ---"
if ! az group show --name "$RESOURCE_GROUP" > /dev/null 2>&1; then
    read -p "Resource group '$RESOURCE_GROUP' not found. Create it? [y/N]: " CREATE_RG
    if [[ "$CREATE_RG" =~ ^[Yy]$ ]]; then
        echo "Creating resource group..."
        az group create --name "$RESOURCE_GROUP" --location "$LOCATION"
    else
        echo "Deployment cancelled."
        exit 1
    fi
else
    echo "Resource group exists."
fi

# Create storage account
echo ""
echo "--- Creating storage account ---"
if az storage account show --name "$STORAGE_ACCOUNT" --resource-group "$RESOURCE_GROUP" > /dev/null 2>&1; then
    echo "Storage account already exists."
else
    az storage account create \
        --name "$STORAGE_ACCOUNT" \
        --location "$LOCATION" \
        --resource-group "$RESOURCE_GROUP" \
        --sku Standard_LRS
    echo "Storage account created."
fi

# Create function app
echo ""
echo "--- Creating function app ---"
if az functionapp show --name "$FUNCTION_APP_NAME" --resource-group "$RESOURCE_GROUP" > /dev/null 2>&1; then
    echo "Function app already exists."
else
    az functionapp create \
        --name "$FUNCTION_APP_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --storage-account "$STORAGE_ACCOUNT" \
        --flexconsumption-location "$LOCATION" \
        --runtime python \
        --runtime-version 3.13
    echo "Function app created."
fi

# Set environment variables
echo ""
echo "--- Setting environment variables ---"
PRIVATE_KEY=$(cat "$PRIVATE_KEY_PATH")
az functionapp config appsettings set \
    --name "$FUNCTION_APP_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --settings \
        "GITHUB_APP_ID=$GITHUB_APP_ID" \
        "GITHUB_INSTALLATION_ID=$GITHUB_INSTALLATION_ID" \
        "GITHUB_PRIVATE_KEY=$PRIVATE_KEY" \
    --output none
echo "Environment variables configured."

# Deploy function code
echo ""
echo "--- Deploying function code ---"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

pushd "$PROJECT_DIR" > /dev/null
func azure functionapp publish "$FUNCTION_APP_NAME" --python
popd > /dev/null

# Get function key
echo ""
echo "--- Retrieving function key ---"
FUNCTION_KEY=$(az functionapp keys list \
    --name "$FUNCTION_APP_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query "functionKeys.default" -o tsv)

# Test the function
echo ""
echo "--- Testing function ---"
FUNCTION_URL="https://$FUNCTION_APP_NAME.azurewebsites.net/api/getgithubtoken?code=$FUNCTION_KEY"

echo "Waiting 10 seconds for function to initialize..."
sleep 10

RESPONSE=$(curl -s -w "\n%{http_code}" "$FUNCTION_URL")
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [[ "$HTTP_CODE" == "200" && "$BODY" == ghs_* ]]; then
    echo ""
    echo "============================================"
    echo "  Deployment Successful!"
    echo "============================================"
    echo ""
    echo "Function URL:"
    echo "$FUNCTION_URL"
    echo ""
    echo "Test token received: ${BODY:0:20}..."
    echo ""
else
    echo ""
    echo "============================================"
    echo "  Deployment Complete (Test Failed)"
    echo "============================================"
    echo ""
    echo "Function URL:"
    echo "$FUNCTION_URL"
    echo ""
    echo "HTTP Status: $HTTP_CODE"
    echo "Response: $BODY"
    echo ""
    echo "The function deployed but the test failed."
    echo "Check the Azure Portal logs for more details."
fi
