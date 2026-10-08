#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
MOCK_DIR="$SCRIPT_DIR/mocks"

APP="test-function-app"
EXPECTED_RUNTIME="python 3.13"

# Setup mock environment
export PATH="$MOCK_DIR:$PATH"
export MOCK_STATE_DIR=""

# Cleanup on ANY exit, not just the happy path: `set -e` means a failed
# assertion above skips the teardown at the bottom of the script and leaves
# the mock state dir and the generated key behind.
cleanup() {
    [[ -n "${MOCK_STATE_DIR:-}" ]] && rm -rf "$MOCK_STATE_DIR"
    [[ -n "${TEST_PEM:-}" ]] && rm -f "$TEST_PEM"
    return 0
}
trap cleanup EXIT

# Make mocks executable
chmod +x "$MOCK_DIR/az" "$MOCK_DIR/func" "$MOCK_DIR/curl"

# Throwaway key, generated per run so nothing key-shaped is ever committed.
# 2048 bits to match what GitHub issues for App private keys - 1024 is below
# what current tooling accepts, so a smaller key would make this test pass
# against input production would reject.
TEST_PEM=$(mktemp)
openssl genrsa -out "$TEST_PEM" 2048 2>/dev/null

ERRORS=0
CHECKS=0

pass() { echo "PASS: $1"; CHECKS=$((CHECKS + 1)); }
fail() { echo "FAIL: $1"; CHECKS=$((CHECKS + 1)); ERRORS=$((ERRORS + 1)); }

# Fresh mock state per scenario, with the resource group already present.
reset_state() {
    [[ -n "$MOCK_STATE_DIR" ]] && rm -rf "$MOCK_STATE_DIR"
    MOCK_STATE_DIR=$(mktemp -d)
    touch "$MOCK_STATE_DIR/rg_test-rg"
}

# Pre-provision an app the way an earlier deploy would have left it.
existing_app() {
    touch "$MOCK_STATE_DIR/storage_teststorage123"
    touch "$MOCK_STATE_DIR/app_$APP"
    echo "$1" > "$MOCK_STATE_DIR/app_${APP}_runtime"
}

# Runs deploy.sh with the standard answers; sets DEPLOY_EXIT without letting
# `set -e` abort the test on a deploy that is expected to fail.
run_deploy() {
    DEPLOY_EXIT=0
    {
        echo "$APP"                   # Function App name
        echo "test-rg"                # Resource Group
        echo "teststorage123"         # Storage Account
        echo "eastus"                 # Location
        echo "12345"                  # GitHub App ID
        echo "67890"                  # GitHub Installation ID
        echo "$TEST_PEM"              # Private key path
        echo "y"                      # Confirm deployment
    } | "$PROJECT_DIR/scripts/deploy.sh" || DEPLOY_EXIT=$?
    echo ""
    echo "--- Verifying ---"
}

expect_exit_zero() {
    if [[ $DEPLOY_EXIT -eq 0 ]]; then
        pass "deploy.sh exited 0"
    else
        fail "deploy.sh exited $DEPLOY_EXIT"
    fi
}

expect_runtime() {
    local actual
    actual=$(cat "$MOCK_STATE_DIR/app_${APP}_runtime" 2>/dev/null || echo "<missing>")
    if [[ "$actual" == "$1" ]]; then
        pass "runtime is '$1'"
    else
        fail "runtime is '$actual', expected '$1'"
    fi
}

expect_published() {
    if [[ -f "$MOCK_STATE_DIR/published_$APP" ]]; then
        pass "code published"
    else
        fail "code not published"
    fi
}

expect_settings() {
    local f="$MOCK_STATE_DIR/app_${APP}_settings"
    for s in "GITHUB_APP_ID=12345" "GITHUB_INSTALLATION_ID=67890" "GITHUB_PRIVATE_KEY="; do
        if [[ -f "$f" ]] && grep -q "$s" "$f"; then
            pass "${s%%=*} configured"
        else
            fail "${s%%=*} not configured"
        fi
    done
}

expect_no_runtime_set() {
    if [[ -f "$MOCK_STATE_DIR/app_${APP}_runtime_sets" ]]; then
        fail "runtime set unexpectedly: $(tr '\n' ' ' < "$MOCK_STATE_DIR/app_${APP}_runtime_sets")"
    else
        pass "runtime left untouched"
    fi
}

echo "============================================"
echo "  Testing Deploy Script"
echo "============================================"

echo ""
echo "=== Scenario: new function app ==="
reset_state
run_deploy
expect_exit_zero
if [[ -f "$MOCK_STATE_DIR/storage_teststorage123" ]]; then
    pass "storage account created"
else
    fail "storage account not created"
fi
if [[ -f "$MOCK_STATE_DIR/app_$APP" ]]; then
    pass "function app created"
else
    fail "function app not created"
fi
expect_runtime "$EXPECTED_RUNTIME"
expect_no_runtime_set
expect_settings
expect_published

echo ""
echo "=== Scenario: existing app on Python 3.11 ==="
reset_state
existing_app "python 3.11"
run_deploy
expect_exit_zero
expect_runtime "$EXPECTED_RUNTIME"
if [[ "$(cat "$MOCK_STATE_DIR/app_${APP}_runtime_sets" 2>/dev/null)" == "3.13" ]]; then
    pass "runtime set exactly once, to 3.13"
else
    fail "runtime sets were '$(tr '\n' ' ' < "$MOCK_STATE_DIR/app_${APP}_runtime_sets" 2>/dev/null)', expected '3.13'"
fi
expect_settings
expect_published

echo ""
echo "=== Scenario: existing app already on Python 3.13 ==="
reset_state
existing_app "python 3.13"
run_deploy
expect_exit_zero
expect_runtime "$EXPECTED_RUNTIME"
expect_no_runtime_set
expect_published

echo ""
echo "=== Scenario: existing app not on Flex Consumption ==="
reset_state
existing_app "python 3.11"
touch "$MOCK_STATE_DIR/app_${APP}_legacy"
run_deploy
if [[ $DEPLOY_EXIT -ne 0 ]]; then
    pass "deploy.sh failed (exit $DEPLOY_EXIT)"
else
    fail "deploy.sh exited 0 on an app it cannot update"
fi
if [[ -f "$MOCK_STATE_DIR/published_$APP" ]]; then
    fail "code published to an app left on the old runtime"
else
    pass "code not published"
fi
if [[ -f "$MOCK_STATE_DIR/app_${APP}_settings" ]]; then
    fail "app settings written before the runtime check"
else
    pass "app settings untouched"
fi

echo ""
echo "--- Verifying the suite itself ran ---"
# Silence is not success: a scenario that stopped early would report no
# failures simply because its checks never ran.
EXPECTED_CHECKS=23
if [[ $CHECKS -ne $EXPECTED_CHECKS ]]; then
    fail "ran $CHECKS checks, expected $EXPECTED_CHECKS"
fi

echo ""
if [[ $ERRORS -eq 0 ]]; then
    echo "============================================"
    echo "  All $CHECKS checks passed!"
    echo "============================================"
    exit 0
else
    echo "============================================"
    echo "  $ERRORS of $CHECKS check(s) failed"
    echo "============================================"
    exit 1
fi
