#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

source lib/system.sh

# Mock "id": MOCK_UID is returned for "id -u", MOCK_USER for "id -un".
id() {
    case "$1" in
        -u) echo "$MOCK_UID" ;;
        -un) echo "$MOCK_USER" ;;
    esac
}

expect_user() {
    local label="$1"
    local expected="$2"
    local output

    if output="$(get_runtime_user 2>/dev/null)" && [[ "$output" == "$expected" ]]; then
        echo "[PASS] $label"
    else
        echo "[FAIL] $label (got: '${output:-}')"
        exit 1
    fi
}

expect_failure() {
    local label="$1"
    local expected_error="$2"
    local output

    if output="$(get_runtime_user 2>&1)"; then
        echo "[FAIL] $label (accepted: '$output')"
        exit 1
    elif [[ "$output" == *"$expected_error"* ]]; then
        echo "[PASS] $label"
    else
        echo "[FAIL] $label (unexpected error: '$output')"
        exit 1
    fi
}

# Test 1: Normal user runs the installer.
MOCK_UID=1000 MOCK_USER=sirius SUDO_USER="" \
    expect_user "Normal user detected" "sirius"

# Test 2: Installer started with sudo uses the real user.
MOCK_UID=0 MOCK_USER=root SUDO_USER=developer \
    expect_user "Real user detected under sudo" "developer"

# Test 3: Root login without sudo is rejected.
MOCK_UID=0 MOCK_USER=root SUDO_USER="" \
    expect_failure "Direct root rejected" "not as root"

# Test 4: sudo from a root shell is rejected.
MOCK_UID=0 MOCK_USER=root SUDO_USER=root \
    expect_failure "SUDO_USER=root rejected" "not as root"

# Test 5: Unsafe username is rejected.
MOCK_UID=1000 MOCK_USER='bad user' SUDO_USER="" \
    expect_failure "Unsafe username rejected" "Unsupported username"

echo "[SUCCESS] Runtime user tests passed."
