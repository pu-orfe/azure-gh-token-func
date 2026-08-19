# GitHub Token Generator for Azure Functions

An Azure Function that generates GitHub App installation access tokens. Use this to authenticate GitHub API calls from Azure Logic Apps, other Azure Functions, or any service that needs programmatic GitHub access.

## Quick Start

### Prerequisites

- Azure CLI installed and authenticated (`az login`)
- Azure Functions Core Tools v4+ (`func --version`)
- Python 3.13
- A GitHub App with appropriate permissions

### 1. Create a GitHub App

1. Go to **GitHub Settings > Developer settings > GitHub Apps > New GitHub App**
2. Set the following:
   - **GitHub App name**: Choose a descriptive name
   - **Homepage URL**: Any valid URL
   - **Webhook**: Uncheck "Active" (not needed)
3. Set **Permissions**:
   - **Repository permissions**:
     - Contents: Read-only
     - Metadata: Read-only
     - Actions: Read and write
     - Workflows: Read and write
4. Set **Where can this GitHub App be installed?** to "Only on this account"
5. Click **Create GitHub App**

### 2. Configure the GitHub App

After creation:

1. Note the **App ID** (displayed on the app's settings page)
2. Scroll down and click **Generate a private key**
   - This downloads a `.pem` file - keep it secure
3. Click **Install App** in the left sidebar
4. Select the account/organization and choose which repositories to grant access
5. After installation, note the **Installation ID** from the URL:
   ```
   https://github.com/settings/installations/95613337
                                              ^^^^^^^^
                                              This is your Installation ID
   ```

### 3. Deploy to Azure

#### Option A: Interactive Script (Recommended)

Run the deployment script which will prompt for all required information:

```bash
./scripts/deploy.sh
```

The script will:
- Collect configuration (function name, resource group, GitHub App details)
- Create the storage account and function app
- Set environment variables
- Deploy the code
- Test the function and display the URL

#### Option B: Manual Deployment

```bash
# Set your variables
RESOURCE_GROUP="your-resource-group"
FUNCTION_APP_NAME="your-function-app-name"
STORAGE_ACCOUNT="yourstorageaccount"  # 3-24 chars, lowercase alphanumeric only
LOCATION="eastus"  # Must support Flex Consumption - check with: az functionapp list-flexconsumption-locations

# Create storage account (required for Azure Functions)
az storage account create \
  --name $STORAGE_ACCOUNT \
  --location $LOCATION \
  --resource-group $RESOURCE_GROUP \
  --sku Standard_LRS

# Create the function app (Flex Consumption plan)
az functionapp create \
  --name $FUNCTION_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --storage-account $STORAGE_ACCOUNT \
  --flexconsumption-location $LOCATION \
  --runtime python \
  --runtime-version 3.13

# Set environment variables
PRIVATE_KEY=$(cat path/to/your-private-key.pem)
az functionapp config appsettings set \
  --name $FUNCTION_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --settings \
    "GITHUB_APP_ID=your-app-id" \
    "GITHUB_INSTALLATION_ID=your-installation-id" \
    "GITHUB_PRIVATE_KEY=$PRIVATE_KEY"

# Deploy the function code
func azure functionapp publish $FUNCTION_APP_NAME --python
```

### 4. Get Your Function Key

```bash
az functionapp keys list \
  --name $FUNCTION_APP_NAME \
  --resource-group $RESOURCE_GROUP
```

### 5. Test the Function

```bash
curl "https://$FUNCTION_APP_NAME.azurewebsites.net/api/getgithubtoken?code=YOUR_FUNCTION_KEY"
```

A successful response returns a GitHub installation access token:
```
ghs_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

## Usage Examples

This function is useful when you need automated GitHub access from Azure services. Common use cases:

- **Scheduled workflow triggers**: Use an Azure Logic App to call this function on a schedule, then trigger a GitHub Actions workflow (useful for keeping public repos active past GitHub's 60-day inactivity limit)
- **Automated commits**: Commit files to a repository programmatically from a Logic App or another Azure Function
- **Repository management**: Create issues, manage pull requests, or update repository settings on a schedule
- **Cross-service integration**: Bridge Azure services with GitHub's API for any automation that requires authenticated access

### Trigger GitHub Actions Workflow

Use the token to dispatch a workflow:

```bash
TOKEN=$(curl -s "https://your-func.azurewebsites.net/api/getgithubtoken?code=YOUR_KEY")

curl -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.github+json" \
  -d '{"ref": "main"}' \
  "https://api.github.com/repos/OWNER/REPO/actions/workflows/WORKFLOW.yml/dispatches"
```

### Azure Logic Apps Integration

In a Logic App HTTP action, set:
- **URI**: Your function URL with code parameter
- **Method**: GET

Then use the response in subsequent steps:
```
Authorization: Bearer @{body('GetGitHubToken')}
```

## Local Development

### Setup

```bash
# Create virtual environment
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

# Create local settings
cp local.settings.example.json local.settings.json
```

### Configure Local Settings

Edit `local.settings.json`:

```json
{
  "IsEncrypted": false,
  "Values": {
    "AzureWebJobsStorage": "UseDevelopmentStorage=true",
    "FUNCTIONS_WORKER_RUNTIME": "python",
    "GITHUB_APP_ID": "your-app-id",
    "GITHUB_INSTALLATION_ID": "your-installation-id",
    "GITHUB_PRIVATE_KEY": "-----BEGIN RSA PRIVATE KEY-----\nMIIE...\n-----END RSA PRIVATE KEY-----"
  }
}
```

**Note**: For `local.settings.json`, the private key must be formatted as a single line with `\n` escape sequences (JSON doesn't support multi-line strings):

```bash
# Convert .pem to single line for local.settings.json
awk 'NF {printf "%s\\n", $0}' your-private-key.pem
```

For Azure deployment via CLI, you can use the raw PEM file directly - the deployment script and manual commands handle this automatically.

### Run Locally

```bash
func start
```

Test at: `http://localhost:7071/api/GetGitHubToken`

## Project Structure

```
├── host.json                      # Functions host configuration
├── requirements.txt               # Python dependencies
├── local.settings.example.json    # Example local settings (safe for git)
├── local.settings.json            # Your local settings (gitignored)
├── scripts/
│   ├── deploy.sh                  # Interactive deployment script
│   └── cleanup.sh                 # Delete function app and resources
└── GetGitHubToken/
    ├── __init__.py                # Function code
    └── function.json              # Trigger and binding config
```

## Migrating Existing Apps to Flex Consumption

If you have an existing function app on Linux Consumption (which reaches EOL September 2028), you'll need to create a new Flex Consumption app and redeploy:

1. Create a new function app with `--flexconsumption-location` instead of `--consumption-plan-location`
2. Copy your environment variables from the old app
3. Deploy your code to the new app
4. Update any Logic Apps or other services to use the new function URL
5. Delete the old function app

There's no in-place migration path - Flex Consumption requires a new app.

## Troubleshooting

### 401 Unauthorized
- Ensure you're including the function key as `?code=` parameter or `x-functions-key` header

### "Missing GITHUB_APP_ID" or similar
- Verify environment variables are set in Azure Portal > Function App > Configuration > Application settings

### "Invalid private key format"
- Check that the private key includes the full `-----BEGIN RSA PRIVATE KEY-----` and `-----END RSA PRIVATE KEY-----` markers
- For local development, ensure newlines are escaped as `\n`

### Function not found (404)
- Wait a few minutes after deployment for the function to initialize
- Check deployment succeeded: `func azure functionapp publish` should show the function URL

### Local development issues
- Verify Python 3.13 is installed
- Check Azure Functions Core Tools v4+: `func --version`
- Ensure virtual environment is activated
