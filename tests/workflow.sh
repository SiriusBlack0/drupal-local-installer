#!/usr/bin/env bash
set -e

source lib/workflow.sh

step() { :; }

# The real log_line, writing into a temporary log file.
LOG_FILE="$(mktemp)"
trap 'rm -f "$LOG_FILE"' EXIT
log_line() { printf '%s\n' "$*" >> "$LOG_FILE"; }

DATABASE_ENGINE="mariadb"
DATABASE_NAME="drupal_db"
DATABASE_USER="drupal_user"
DATABASE_PASSWORD="Secret#Pass1"
SQLITE_DATABASE_PATH="/tmp/test-drupal/private/database.sqlite"

# Each stub returns the value of its *_result variable (default 0), so
# the tests change results without redefining functions.
provision_project_database() {
    calls+="database "
    database_args="$*"
    return "${database_result:-0}"
}

remove_project_directory() {
    calls+="remove_directory "
    return 0
}

remove_project_database() {
    calls+="remove_database "
    remove_database_args="$*"
    return 0
}

install_php_fpm_pool() {
    calls+="pool "
    pool_args="$*"
    return "${pool_result:-0}"
}

remove_php_fpm_pool() {
    calls+="remove_pool "
    return "${remove_pool_result:-0}"
}

install_nginx_site() {
    calls+="site "
    site_args="$*"
    return "${site_result:-0}"
}

remove_nginx_site() {
    calls+="remove_site "
    return 0
}

create_start_script() {
    calls+="start_script "
    start_script_args="$*"
    return 0
}

PROJECT_MACHINE_NAME="test_drupal"

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

if run_installation_workflow > /dev/null &&
   [[ "$calls" == "plan execute readiness provision database pool site start_script " ]] &&
   [[ "$pool_args" == "test_drupal 8.5 devuser" ]] &&
   [[ "$site_args" == "test_drupal /tmp/test-drupal 8.5" ]] &&
   [[ "$start_script_args" == "/tmp/test-drupal 8.5 mariadb test_drupal devuser" ]] &&
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

# Test 5: Server databases get name, user and password.

provision_drupal_project() {
    calls+="provision "
    return 0
}

calls=""
run_installation_workflow > /dev/null

if [[ "$database_args" == "mariadb drupal_db drupal_user Secret#Pass1" ]]; then
    echo "[PASS] Server database created with the chosen credentials"
else
    echo "[FAIL] Unexpected database arguments: $database_args"
    exit 1
fi

# Test 6: SQLite gets the file path and the project owner.

DATABASE_ENGINE="sqlite"
calls=""
run_installation_workflow > /dev/null

if [[ "$database_args" == "sqlite /tmp/test-drupal/private/database.sqlite devuser" ]]; then
    echo "[PASS] SQLite created at the project path for the project owner"
else
    echo "[FAIL] Unexpected SQLite arguments: $database_args"
    exit 1
fi

DATABASE_ENGINE="mariadb"

# Test 7: Database failure removes the project directory.

database_result=1

calls=""

if output="$(run_installation_workflow)"; then
    echo "[FAIL] Workflow ignored database failure"
    exit 1
elif [[ "$output" == *"[ERROR] Database creation failed."* ]] &&
     [[ "$output" == *"[OK] Rollback completed."* ]] &&
     [[ "$(run_installation_workflow > /dev/null; echo "$calls")" == *"database remove_directory " ]]; then
    echo "[PASS] Database failure rolls back the project directory"
else
    echo "[FAIL] Unexpected database failure result: $output"
    exit 1
fi

# Test 8: The database password never reaches the log.

if grep -q "Secret#Pass1" "$LOG_FILE"; then
    echo "[FAIL] Database password written to the log"
    exit 1
elif grep -q "Database: mariadb (credentials are not logged)" "$LOG_FILE"; then
    echo "[PASS] Database password kept out of the log"
else
    echo "[FAIL] Database step not logged"
    exit 1
fi

# Test 9: Nginx failure removes everything created, newest first.

database_result=0
site_result=1

calls=""

if output="$(run_installation_workflow)"; then
    echo "[FAIL] Workflow ignored Nginx failure"
    exit 1
fi

calls=""
run_installation_workflow > /dev/null || true

if [[ "$calls" == "plan execute readiness provision database pool site remove_pool remove_database remove_directory " ]] &&
   [[ "$remove_database_args" == "mariadb drupal_db drupal_user" ]] &&
   [[ "$output" == *"[ERROR] Web server configuration failed."* ]]; then
    echo "[PASS] Nginx failure rolls back pool, database and directory"
else
    echo "[FAIL] Unexpected Nginx rollback: $calls"
    exit 1
fi

# Test 10: PHP-FPM failure: no Nginx site, pool not removed twice.

pool_result=1

calls=""
run_installation_workflow > /dev/null || true

if [[ "$calls" == "plan execute readiness provision database pool remove_database remove_directory " ]]; then
    echo "[PASS] PHP-FPM failure rolls back database and directory only"
else
    echo "[FAIL] Unexpected PHP-FPM rollback: $calls"
    exit 1
fi

# Test 11: A failed rollback step is reported with a manual command.

pool_result=0
remove_pool_result=1

get_php_fpm_pool_config_path() {
    echo "/etc/php/$2/fpm/pool.d/$1.conf"
}

output="$(run_installation_workflow || true)"

if [[ "$output" == *"[WARNING] Remove the PHP-FPM pool manually: /etc/php/8.5/fpm/pool.d/test_drupal.conf"* ]] &&
   [[ "$output" != *"[OK] Rollback completed."* ]]; then
    echo "[PASS] Failed rollback step reported with the path to remove"
else
    echo "[FAIL] Unexpected failed rollback output: $output"
    exit 1
fi

echo "[SUCCESS] Installation workflow tests passed."
