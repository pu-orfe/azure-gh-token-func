#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
MOCK_DIR="$SCRIPT_DIR/mocks"

# Setup mock environment
export PATH="$MOCK_DIR:$PATH"
export MOCK_STATE_DIR=$(mktemp -d)

# Cleanup on ANY exit, not just the happy path: `set -e` means a failed
# assertion above skips the teardown at the bottom of the script and leaves
# the mock state dir and the generated key behind.
cleanup() {
    rm -rf "$MOCK_STATE_DIR"
    [[ -n "${TEST_PEM:-}" ]] && rm -f "$TEST_PEM"
    return 0
}
trap cleanup EXIT

# Make mocks executable
chmod +x "$MOCK_DIR/az" "$MOCK_DIR/func" "$MOCK_DIR/curl"

# Create test resource group
touch "$MOCK_STATE_DIR/rg_test-rg"

# Throwaway key, generated per run so nothing key-shaped is ever committed.
# 2048 bits to match what GitHub issues for App private keys - 1024 is below
# what current tooling accepts, so a smaller key would make this test pass
# against input production would reject.
TEST_PEM=$(mktemp)
openssl genrsa -out "$TEST_PEM" 2048 2>/dev/null

echo "============================================"
echo "  Testing Deploy Script"
echo "============================================"
echo ""

# Run deploy script with test inputs
{
    echo "test-function-app"      # Function App name
    echo "test-rg"                # Resource Group
    echo "teststorage123"         # Storage Account
    echo "eastus"                 # Location
    echo "12345"                  # GitHub App ID
    echo "67890"                  # GitHub Installation ID
    echo "$TEST_PEM"              # Private key path
    echo "y"                      # Confirm deployment
} | "$PROJECT_DIR/scripts/deploy.sh"

DEPLOY_EXIT=$?

echo ""
echo "--- Verifying deployment ---"

# Check resources were created
ERRORS=0

if [[ ! -f "$MOCK_STATE_DIR/storage_teststorage123" ]]; then
    echo "FAIL: Storage account not created"
    ERRORS=$((ERRORS + 1))
else
    echo "PASS: Storage account created"
fi

if [[ ! -f "$MOCK_STATE_DIR/app_test-function-app" ]]; then
    echo "FAIL: Function app not created"
    ERRORS=$((ERRORS + 1))
else
    echo "PASS: Function app created"
fi

if [[ ! -f "$MOCK_STATE_DIR/app_test-function-app_settings" ]]; then
    echo "FAIL: App settings not configured"
    ERRORS=$((ERRORS + 1))
else
    if grep -q "GITHUB_APP_ID=12345" "$MOCK_STATE_DIR/app_test-function-app_settings"; then
        echo "PASS: GITHUB_APP_ID configured"
    else
        echo "FAIL: GITHUB_APP_ID not configured"
        ERRORS=$((ERRORS + 1))
    fi

    if grep -q "GITHUB_INSTALLATION_ID=67890" "$MOCK_STATE_DIR/app_test-function-app_settings"; then
        echo "PASS: GITHUB_INSTALLATION_ID configured"
    else
        echo "FAIL: GITHUB_INSTALLATION_ID not configured"
        ERRORS=$((ERRORS + 1))
    fi

    if grep -q "GITHUB_PRIVATE_KEY=" "$MOCK_STATE_DIR/app_test-function-app_settings"; then
        echo "PASS: GITHUB_PRIVATE_KEY configured"
    else
        echo "FAIL: GITHUB_PRIVATE_KEY not configured"
        ERRORS=$((ERRORS + 1))
    fi
fi


echo ""
if [[ $ERRORS -eq 0 ]]; then
    echo "============================================"
    echo "  All tests passed!"
    echo "============================================"
    exit 0
else
    echo "============================================"
    echo "  $ERRORS test(s) failed"
    echo "============================================"
    exit 1
fi
