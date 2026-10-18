#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

# Test 1: Sourcing preflight.sh only defines functions.

if output="$(bash -c 'source lib/preflight.sh' < /dev/null 2>&1)" && [[ -z "$output" ]]; then
    echo "[PASS] Sourcing preflight.sh has no side effects"
else
    echo "[FAIL] Sourcing preflight.sh produced output or failed: $output"
    exit 1
fi

source lib/system.sh
source lib/database.sh
source lib/preflight.sh

add_service_to_start() {
    INSTALL_SERVICES_TO_START+=("$1")
}

add_service_after_install() {
    INSTALL_SERVICES_AFTER_INSTALL+=("$1")
}

# Runs plan_database_service and prints "after|to_start|packages".
database_plan() {
    INSTALL_SERVICES_TO_START=()
    INSTALL_SERVICES_AFTER_INSTALL=()
    INSTALL_PACKAGES=()
    plan_database_service > /dev/null
    printf '%s|%s|%s' "${INSTALL_SERVICES_AFTER_INSTALL[*]}" "${INSTALL_SERVICES_TO_START[*]}" "${INSTALL_PACKAGES[*]}"
}

check() {
    local label="$1"
    local expected="$2"
    local actual="$3"

    if [[ "$actual" == "$expected" ]]; then
        echo "[PASS] $label"
    else
        echo "[FAIL] $label (expected '$expected', got '$actual')"
        exit 1
    fi
}

# Tests 2-5: Database service plan.

is_database_service_running() { return 1; }

DATABASE_ENGINE="mariadb" DATABASE_NEEDS_INSTALL="yes"
check "Missing MariaDB: server package installed, then started" "mariadb||mariadb-server" "$(database_plan)"

DATABASE_ENGINE="postgresql" DATABASE_NEEDS_INSTALL="yes"
check "Missing PostgreSQL: server package installed, then started" "postgresql||postgresql" "$(database_plan)"

DATABASE_ENGINE="mysql" DATABASE_NEEDS_INSTALL="yes"
check "Missing MySQL: server package installed, then started" "mysql||mysql-server" "$(database_plan)"

DATABASE_ENGINE="mariadb" DATABASE_NEEDS_INSTALL="no"
check "Stopped MariaDB service plan" "|mariadb|" "$(database_plan)"

is_database_service_running() { return 0; }
check "Running MariaDB service plan" "||" "$(database_plan)"

is_database_service_running() { echo "UNEXPECTED_DATABASE_CHECK"; return 1; }
DATABASE_ENGINE="sqlite" DATABASE_NEEDS_INSTALL="no"
check "SQLite service plan" "||" "$(database_plan)"

# Tests 6-9 mock the planning steps, so they run in a subshell:
# the mocks disappear afterwards and Test 10 uses the real functions.
(
    # Tests 6-8: Project conflicts stop preflight before any planning.

    call_log=""
    plan_required_packages() { call_log+="packages "; }
    plan_php_extensions() { call_log+="extensions "; }
    plan_service_startup() { call_log+="services "; }
    is_project_directory_taken() { return 1; }
    is_nginx_config_taken() { return 1; }

    PROJECT_MACHINE_NAME="demo"
    PROJECT_PATH="/var/www/demo"

    is_project_registered() { return 0; }

    if output="$(run_preflight)"; then
        echo "[FAIL] Registered project accepted"
        exit 1
    elif [[ "$output" == *"ERROR: Project 'demo' is already registered."* ]] &&
         [[ "$output" != *"Checking project directory"* ]]; then
        echo "[PASS] Registered project stops preflight"
    else
        echo "[FAIL] Unexpected registered project result"
        exit 1
    fi

    is_project_registered() { return 1; }
    is_project_directory_taken() { return 0; }

    if output="$(run_preflight)"; then
        echo "[FAIL] Existing project directory accepted"
        exit 1
    elif [[ "$output" == *"ERROR: Project directory '/var/www/demo' already exists."* ]]; then
        echo "[PASS] Existing project directory stops preflight"
    else
        echo "[FAIL] Unexpected existing directory result"
        exit 1
    fi

    is_project_directory_taken() { return 1; }
    is_nginx_config_taken() { return 0; }

    if output="$(run_preflight)"; then
        echo "[FAIL] Existing Nginx configuration accepted"
        exit 1
    elif [[ "$output" == *"ERROR: Nginx configuration for 'demo' already exists."* ]]; then
        echo "[PASS] Existing Nginx configuration stops preflight"
    else
        echo "[FAIL] Unexpected Nginx configuration result"
        exit 1
    fi

    # Test 9: Without conflicts, all planning steps run in order.

    is_nginx_config_taken() { return 1; }
    call_log=""
    run_preflight > /dev/null
    check "Preflight planning order" "packages extensions services " "$call_log"
) || exit 1

# Test 10: Required PHP extensions include the database driver.

is_php_cli_installed() { return 0; }
check_php_extensions() { return 0; }

for pair in "mariadb pdo_mysql" "mysql pdo_mysql" "postgresql pdo_pgsql" "sqlite pdo_sqlite"; do
    read -r DATABASE_ENGINE expected_extension <<< "$pair"
    PHP_VERSION="8.5"
    plan_php_extensions > /dev/null

    if [[ " ${REQUIRED_PHP_EXTENSIONS[*]} " != *" $expected_extension "* ]]; then
        echo "[FAIL] $DATABASE_ENGINE does not require $expected_extension"
        exit 1
    fi
done

echo "[PASS] Database driver extension planned for each engine"

# Test 11: curl is planned when it is missing (the HTTP checks need it).

(
    is_composer_installed() { return 0; }
    is_nginx_installed() { return 0; }
    is_php_fpm_installed() { return 0; }
    is_php_cli_installed() { return 0; }
    PHP_VERSION="8.5"

    empty_bin="$(mktemp -d)"
    trap 'rm -rf "$empty_bin"' EXIT
    INSTALL_PACKAGES=()
    PATH="$empty_bin" plan_required_packages > /dev/null
    check "curl planned when missing" "curl" "${INSTALL_PACKAGES[*]}"

    INSTALL_PACKAGES=()
    ln -s "$(type -P true)" "$empty_bin/curl"
    PATH="$empty_bin" plan_required_packages > /dev/null
    check "curl not planned when installed" "" "${INSTALL_PACKAGES[*]}"
) || exit 1

echo "[SUCCESS] Preflight tests passed."
