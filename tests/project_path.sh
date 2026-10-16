#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

source lib/registry.sh

check() {
    local label="$1"
    local expected="$2"
    shift 2
    local output

    if output="$("$@" 2>/dev/null)" && [[ "$output" == "$expected" ]]; then
        echo "[PASS] $label"
    else
        echo "[FAIL] $label (got: '${output:-}')"
        exit 1
    fi
}

check_failure() {
    local label="$1"
    shift
    local output

    if output="$("$@" 2>&1)"; then
        echo "[FAIL] $label (accepted: '$output')"
        exit 1
    elif [[ "$output" == *"[ERROR]"* ]]; then
        echo "[PASS] $label"
    else
        echo "[FAIL] $label (no error message)"
        exit 1
    fi
}

unset DRUPAL_PROJECTS_DIR

# Test 1: Default base directory.
check "Default project path" "/var/www/mydrupal" \
    get_project_path mydrupal

# Test 2: Custom base directory.
DRUPAL_PROJECTS_DIR=/srv/sites check "Custom base directory" "/srv/sites/mydrupal" \
    get_project_path mydrupal

# Test 3: Trailing slash is normalised.
DRUPAL_PROJECTS_DIR=/srv/sites/ check "Trailing slash removed" "/srv/sites/mydrupal" \
    get_project_path mydrupal

# Test 4: Relative base directory is rejected.
DRUPAL_PROJECTS_DIR=sites check_failure "Relative base directory rejected" \
    get_project_path mydrupal

# Test 5: Unsafe machine names are rejected.
for name in "" "My Drupal" "../etc" "my-drupal" "a/b"; do
    check_failure "Unsafe machine name rejected: '$name'" \
        get_project_path "$name"
done

echo "[SUCCESS] Project path tests passed."
