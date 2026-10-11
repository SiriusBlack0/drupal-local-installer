#!/usr/bin/env bash
set -euo pipefail

source lib/project.sh

# Test 1: Existing directory must be rejected.

if output="$(check_project_directory "/var/www")"; then
    echo "[FAIL] Existing directory was accepted."
    exit 1
else
    if [[ "$output" == *"[ERROR] Project path already exists:"* ]]; then
        echo "[PASS] Existing directory rejected"
    else
        echo "[FAIL] Unexpected error message"
        exit 1
    fi
fi

# Test 2: Available project path must be accepted.

project_path="$(mktemp -d)"
rmdir "$project_path"

if output="$(check_project_directory "$project_path")"; then
    if [[ "$output" == *"[OK] Project path is available:"* ]]; then
        echo "[PASS] Available project path accepted"
    else
        echo "[FAIL] Unexpected success message"
        exit 1
    fi
else
    echo "[FAIL] Available project path was rejected"
    exit 1
fi
# Test 3: Broken symbolic link must be rejected.

project_link="$(mktemp)"
rm "$project_link"

ln -s /tmp/nonexistent-drupal-target "$project_link"

if output="$(check_project_directory "$project_link")"; then
    echo "[FAIL] Broken symbolic link was accepted"
    rm "$project_link"
    exit 1
else
    if [[ "$output" == *"[ERROR] Project path already exists:"* ]]; then
        echo "[PASS] Broken symbolic link rejected"
    else
        echo "[FAIL] Unexpected error message"
        rm "$project_link"
        exit 1
    fi
fi

rm "$project_link"

# Test 4: Composer project command generation.

expected="composer create-project drupal/recommended-project:11.4.8 /var/www/my-drupal"

output="$(build_composer_project_command "11.4.8" "/var/www/my-drupal")"

if [[ "$output" == "$expected" ]]; then
    echo "[PASS] Composer project command generated correctly"
else
    echo "[FAIL] Incorrect Composer project command"
    exit 1
fi

# Test 5: Composer execution with mocked command.

composer() {
    printf 'MOCK_COMPOSER'
    printf ' <%s>' "$@"
    printf '\n'
}

project_path="$(mktemp -d)"
rmdir "$project_path"

output="$(create_drupal_project "11.4.8" "$project_path")"

if [[ "$output" == *"MOCK_COMPOSER <create-project> <drupal/recommended-project:11.4.8> <$project_path>"* ]]; then
    echo "[PASS] Composer executed with correct arguments"
else
    echo "[FAIL] Composer received incorrect arguments"
    exit 1
fi

# Test 6: Composer failure must be propagated.

composer() {
    return 1
}

project_path="$(mktemp -d)"
rmdir "$project_path"

if create_drupal_project "11.4.8" "$project_path" > /dev/null; then
    echo "[FAIL] Composer failure was not detected"
    exit 1
else
    echo "[PASS] Composer failure detected"
fi

# Test 7: Composer must not run if project path exists.

composer_called=0

composer() {
    composer_called=1
    return 1
}

project_path="$(mktemp -d)"

if create_drupal_project "11.4.8" "$project_path" > /dev/null; then
    echo "[FAIL] Existing project directory was accepted"
    rmdir "$project_path"
    exit 1
fi

rmdir "$project_path"

if [[ "$composer_called" -eq 0 ]]; then
    echo "[PASS] Composer skipped for existing directory"
else
    echo "[FAIL] Composer was called for existing directory"
    exit 1
fi

# Test 8: Successful Drupal provisioning.

create_drupal_project() {
    echo "[MOCK] Drupal project created: $1 at $2"
    return 0
}

if output="$(provision_drupal_project "11.4.8" "/tmp/test-drupal")" &&
   [[ "$output" == *"[MOCK] Drupal project created: 11.4.8 at /tmp/test-drupal"* ]] &&
   [[ "$output" == *"[SUCCESS] Drupal project files created."* ]]; then
    echo "[PASS] Drupal provisioning succeeded"
else
    echo "[FAIL] Drupal provisioning failed"
    exit 1
fi

# Test 9: Drupal provisioning failure.

create_drupal_project() {
    echo "[MOCK] Drupal project creation failed."
    return 1
}

if output="$(provision_drupal_project "11.4.8" "/tmp/test-drupal")"; then
    echo "[FAIL] Provisioning ignored project creation failure"
    exit 1
else
    if [[ "$output" == *"[ERROR] Drupal project creation failed."* ]] &&
       [[ "$output" != *"[SUCCESS]"* ]]; then
        echo "[PASS] Drupal provisioning failure detected"
    else
        echo "[FAIL] Unexpected provisioning result"
        exit 1
    fi
fi