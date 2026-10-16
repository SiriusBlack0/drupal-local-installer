#!/usr/bin/env bash
set -e

source lib/workflow.sh

DRUPAL_VERSION="11.4.8"
PROJECT_PATH="/tmp/test-drupal"
PHP_VERSION="8.5"
PROJECT_USER="devuser"

calls=""

prepare_installation_plan() {
    calls+="plan "
}

execute_installation_plan() {
    calls+="execute "
    return 0
}

verify_environment_ready() {
    calls+="readiness "
    return 0
}

provision_drupal_project() {
    calls+="provision "
    provision_args="$*"
    return 0
}

if run_installation_workflow &&
   [[ "$calls" == "plan execute readiness provision " ]] &&
   [[ "$provision_args" == "11.4.8 /tmp/test-drupal 8.5 devuser" ]]; then
    echo "[PASS] Installation workflow executes in correct order"
else
    echo "[FAIL] Installation workflow execution order"
    exit 1
fi

# Test 2: Stop workflow when installation execution fails.

calls=""

execute_installation_plan() {
    calls+="execute "
    return 1
}

if run_installation_workflow; then
    echo "[FAIL] Workflow continued after installation failure"
    exit 1
else
    if [[ "$calls" == "plan execute " ]]; then
        echo "[PASS] Workflow stops on installation failure"
    else
        echo "[FAIL] Unexpected workflow execution: $calls"
        exit 1
    fi
fi

# Test 3: Stop workflow when environment readiness fails.

calls=""

execute_installation_plan() {
    calls+="execute "
    return 0
}

verify_environment_ready() {
    calls+="readiness "
    return 1
}

if run_installation_workflow; then
    echo "[FAIL] Workflow continued after readiness failure"
    exit 1
else
    if [[ "$calls" == "plan execute readiness " ]]; then
        echo "[PASS] Workflow stops on readiness failure"
    else
        echo "[FAIL] Unexpected workflow execution: $calls"
        exit 1
    fi
fi

# Test 4: Detect Drupal provisioning failure.

calls=""

verify_environment_ready() {
    calls+="readiness "
    return 0
}

provision_drupal_project() {
    calls+="provision "
    return 1
}

if run_installation_workflow; then
    echo "[FAIL] Workflow ignored provisioning failure"
    exit 1
else
    if [[ "$calls" == "plan execute readiness provision " ]]; then
        echo "[PASS] Workflow detects provisioning failure"
    else
        echo "[FAIL] Unexpected workflow execution: $calls"
        exit 1
    fi
fi