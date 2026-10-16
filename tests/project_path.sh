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

# Tests 6-9: get_project_conflict reports the first conflict.

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

export XDG_DATA_HOME="$work_dir/data"
is_nginx_config_taken() { [[ "$1" == "nginx_taken" ]]; }

if get_project_conflict "free_name" "$work_dir/free_name" > /dev/null; then
    echo "[FAIL] Free project name reported as conflict"
    exit 1
else
    echo "[PASS] Free project name has no conflict"
fi

mkdir -p "$XDG_DATA_HOME/drupal-local-installer/projects"
touch "$XDG_DATA_HOME/drupal-local-installer/projects/registered.conf"

if [[ "$(get_project_conflict "registered" "$work_dir/registered")" == \
      "Project 'registered' is already registered." ]]; then
    echo "[PASS] Registered project reported"
else
    echo "[FAIL] Registered project not reported"
    exit 1
fi

mkdir "$work_dir/existing_dir"

if [[ "$(get_project_conflict "existing_dir" "$work_dir/existing_dir")" == \
      "Project directory '$work_dir/existing_dir' already exists." ]]; then
    echo "[PASS] Existing project directory reported"
else
    echo "[FAIL] Existing project directory not reported"
    exit 1
fi

if [[ "$(get_project_conflict "nginx_taken" "$work_dir/nginx_taken")" == \
      "Nginx configuration for 'nginx_taken' already exists." ]]; then
    echo "[PASS] Existing Nginx configuration reported"
else
    echo "[FAIL] Existing Nginx configuration not reported"
    exit 1
fi

echo "[SUCCESS] Project path tests passed."
