#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
MOCK_DIR="$SCRIPT_DIR/mocks"

# Setup mock environment
export PATH="$MOCK_DIR:$PATH"
export MOCK_STATE_DIR=$(mktemp -d)

# Make mocks executable
chmod +x "$MOCK_DIR/az" "$MOCK_DIR/func" "$MOCK_DIR/curl"

# Create test resources
touch "$MOCK_STATE_DIR/rg_test-rg"
touch "$MOCK_STATE_DIR/storage_teststorage123"
touch "$MOCK_STATE_DIR/app_test-function-app"
echo "DEPLOYMENT_STORAGE_CONNECTION_STRING=DefaultEndpointsProtocol=https;AccountName=teststorage123;AccountKey=fake" > "$MOCK_STATE_DIR/app_test-function-app_settings"

echo "============================================"
echo "  Testing Cleanup Script"
echo "============================================"
echo ""

# Run cleanup script with test inputs
{
    echo "test-function-app"      # Function App name
    echo "test-rg"                # Resource Group
    echo "y"                      # Confirm deletion
    echo "y"                      # Delete storage
    echo "y"                      # Delete App Insights
} | "$PROJECT_DIR/scripts/cleanup.sh"

CLEANUP_EXIT=$?

echo ""
echo "--- Verifying cleanup ---"

ERRORS=0

if [[ -f "$MOCK_STATE_DIR/app_test-function-app" ]]; then
    echo "FAIL: Function app not deleted"
    ERRORS=$((ERRORS + 1))
else
    echo "PASS: Function app deleted"
fi

if [[ -f "$MOCK_STATE_DIR/storage_teststorage123" ]]; then
    echo "FAIL: Storage account not deleted"
    ERRORS=$((ERRORS + 1))
else
    echo "PASS: Storage account deleted"
fi

# Cleanup
rm -rf "$MOCK_STATE_DIR"

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
