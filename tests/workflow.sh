#!/usr/bin/env bash
set -e

source lib/workflow.sh

step() { :; }

# lib/output.sh: the Ctrl+C handler switches back to the terminal first.
to_console() { echo "(back to the terminal)"; }

# The real log_line, writing into a temporary log file.
LOG_FILE="$(mktemp)"
trap 'rm -f "$LOG_FILE"' EXIT
log_line() { printf '%s\n' "$*" >> "$LOG_FILE"; }

DATABASE_ENGINE="mariadb"
DATABASE_NAME="drupal_db"
DATABASE_USER="drupal_user"
DATABASE_PASSWORD="Secret#Pass1"
SQLITE_DATABASE_PATH="/tmp/test-drupal/private/database.sqlite"

PROJECT_MACHINE_NAME="test_drupal"
PROJECT_NAME="Test Drupal"
ADMIN_USER="admin"
ADMIN_MAIL="admin@example.com"
ADMIN_PASSWORD="Admin#Pass9"
DRUPAL_VERSION="11.4.8"
PROJECT_PATH="/tmp/test-drupal"
PHP_VERSION="8.5"
PROJECT_USER="devuser"

# Every stub records its name in $calls and returns the value of its
# *_result variable (default 0), so tests change results without
# redefining functions.
calls=""

prepare_installation_plan() { calls+="plan "; }
execute_installation_plan() { calls+="execute "; return "${execute_result:-0}"; }
verify_environment_ready() { calls+="readiness "; return "${readiness_result:-0}"; }

create_project_directory() {
    calls+="directory "
    directory_args="$*"
    return "${directory_result:-0}"
}

provision_project_database() {
    calls+="database "
    database_args="$*"
    return "${database_result:-0}"
}

install_php_fpm_pool() {
    calls+="pool "
    pool_args="$*"
    return "${pool_result:-0}"
}

install_nginx_site() {
    calls+="site "
    site_args="$*"
    return "${site_result:-0}"
}

install_drupal_codebase() {
    calls+="composer "
    codebase_args="$*"
    # composer_interrupt=1: Ctrl+C arrives while Composer downloads.
    [[ "${composer_interrupt:-0}" == "1" ]] && kill -INT "$BASHPID"
    return "${composer_result:-0}"
}

verify_nginx_site() { calls+="verify "; return "${verify_result:-0}"; }

install_drupal_site() {
    calls+="drupal "
    drupal_args="$*"
    return "${drupal_result:-0}"
}

create_start_script() {
    calls+="start_script "
    start_script_args="$*"
    return 0
}

run_final_checks() { calls+="checks "; checks_args="$*"; return 0; }
write_project_record() { calls+="record "; return "${record_result:-0}"; }
setup_project_git() { calls+="git "; git_args="$*"; echo "git step"; return "${git_result:-0}"; }

# Removals are also written to $removals_file when it is set (for runs
# in a subshell, whose $calls is lost).
note_removal() { [[ -n "${removals_file:-}" ]] && echo "$1" >> "$removals_file"; return 0; }
remove_nginx_site() { calls+="remove_site "; note_removal site; return 0; }
remove_php_fpm_pool() { calls+="remove_pool "; note_removal pool; return "${remove_pool_result:-0}"; }
remove_project_database() { calls+="remove_database "; remove_database_args="$*"; note_removal database; return 0; }
remove_project_directory() { calls+="remove_directory "; note_removal directory; return 0; }
get_php_fpm_pool_config_path() { echo "/etc/php/$2/fpm/pool.d/$1.conf"; }

reset_results() {
    calls=""
    unset execute_result readiness_result directory_result database_result \
        pool_result site_result composer_result verify_result drupal_result \
        remove_pool_result record_result composer_interrupt git_result
    GIT_SETUP="no"
}

pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; exit 1; }

# Test 1: Order: everything that needs sudo runs before Composer,
# which clears the cached sudo password.

reset_results

if run_installation_workflow > /dev/null &&
   [[ "$calls" == "plan execute readiness directory database pool site composer verify drupal start_script checks record " ]] &&
   [[ "$checks_args" == "/tmp/test-drupal devuser 8.5" ]] &&
   [[ "$directory_args" == "/tmp/test-drupal devuser" ]] &&
   [[ "$codebase_args" == "11.4.8 /tmp/test-drupal 8.5 devuser" ]] &&
   [[ "$pool_args" == "test_drupal 8.5 devuser" ]] &&
   [[ "$site_args" == "test_drupal /tmp/test-drupal 8.5" ]] &&
   [[ "$drupal_args" == "/tmp/test-drupal devuser Test Drupal admin admin@example.com Admin#Pass9" ]] &&
   [[ "$start_script_args" == "/tmp/test-drupal 8.5 mariadb test_drupal devuser" ]]; then
    pass "Order: directory, database, web server (sudo) before Composer"
else
    fail "Installation workflow order: $calls"
fi

# Test 2: SQLite: the database file is created after Composer, which
# needs an empty directory.

reset_results
DATABASE_ENGINE="sqlite"
run_installation_workflow > /dev/null

if [[ "$calls" == "plan execute readiness directory pool site composer database verify drupal start_script checks record " ]] &&
   [[ "$database_args" == "sqlite /tmp/test-drupal/private/database.sqlite devuser" ]]; then
    pass "SQLite created after Composer, at the project path, for the owner"
else
    fail "SQLite order or arguments: $calls / $database_args"
fi

DATABASE_ENGINE="mariadb"

# Test 3: Early failures stop without creating anything.

reset_results
execute_result=1

if run_installation_workflow > /dev/null || [[ "$calls" != "plan execute " ]]; then
    fail "Workflow continued after package installation failure: $calls"
fi

reset_results
readiness_result=1

if run_installation_workflow > /dev/null || [[ "$calls" != "plan execute readiness " ]]; then
    fail "Workflow continued after readiness failure: $calls"
fi

reset_results
directory_result=1

if run_installation_workflow > /dev/null || [[ "$calls" != "plan execute readiness directory " ]]; then
    fail "Workflow continued after directory failure: $calls"
fi

pass "Package, readiness and directory failures stop before anything is created"

# Test 4: Server databases get name, user and password.

reset_results
run_installation_workflow > /dev/null

if [[ "$database_args" == "mariadb drupal_db drupal_user Secret#Pass1" ]]; then
    pass "Server database created with the chosen credentials"
else
    fail "Unexpected database arguments: $database_args"
fi

# Test 5: Each failure rolls back everything created so far, newest first.

check_rollback() {
    local description="$1"
    local expected="$2"
    local message="$3"
    local output

    calls=""
    output="$(run_installation_workflow)" && fail "$description: reported as success"
    calls=""
    run_installation_workflow > /dev/null || true

    if [[ "$calls" == "$expected" && "$output" == *"$message"* ]]; then
        pass "$description"
    else
        fail "$description: $calls"
    fi
}

reset_results
database_result=1
check_rollback "Database failure removes the directory" \
    "plan execute readiness directory database remove_directory " \
    "[ERROR] Database creation failed."

reset_results
pool_result=1
check_rollback "PHP-FPM failure removes database and directory" \
    "plan execute readiness directory database pool remove_database remove_directory " \
    "[ERROR] Web server configuration failed."

reset_results
site_result=1
check_rollback "Nginx failure removes pool, database and directory" \
    "plan execute readiness directory database pool site remove_pool remove_database remove_directory " \
    "[ERROR] Web server configuration failed."

reset_results
composer_result=1
check_rollback "Composer failure removes site, pool, database and directory" \
    "plan execute readiness directory database pool site composer remove_site remove_pool remove_database remove_directory " \
    "Rolling back"

reset_results
verify_result=1
check_rollback "Unanswered site removes everything" \
    "plan execute readiness directory database pool site composer verify remove_site remove_pool remove_database remove_directory " \
    "[ERROR] Web server configuration failed."

reset_results
drupal_result=1
check_rollback "site:install failure removes everything" \
    "plan execute readiness directory database pool site composer verify drupal remove_site remove_pool remove_database remove_directory " \
    "[ERROR] Drupal site installation failed."

if [[ "$remove_database_args" == "mariadb drupal_db drupal_user" ]]; then
    pass "Rollback removes the project database and user"
else
    fail "Unexpected database removal: $remove_database_args"
fi

# Test 6: A registry failure is a warning: the site itself works.

reset_results
record_result=1

if output="$(run_installation_workflow)" &&
   [[ "$output" == *"[WARNING] The project works, but it is not in the registry"* ]]; then
    pass "Registry failure only warns"
else
    fail "registry failure: $output"
fi

# Test 6a: The git repository comes last, after the registry; a git
# failure is only a warning.

reset_results
GIT_SETUP="yes"

if output="$(run_installation_workflow; echo "calls=$calls")" &&
   [[ "$output" == *"calls=plan execute readiness directory database pool site composer verify drupal start_script checks record git "* ]]; then
    reset_results
    GIT_SETUP="yes"
    run_installation_workflow > /dev/null
    if [[ "$git_args" == "/tmp/test-drupal devuser Initial commit: Drupal 11.4.8 project test_drupal" ]]; then
        reset_results
        GIT_SETUP="yes"
        git_result=1
        if run_installation_workflow > /dev/null; then
            pass "Git step last, with the project path, user and commit message; a failure only warns"
        else
            fail "git failure stopped the workflow"
        fi
    else
        fail "git args: $git_args"
    fi
else
    fail "git step: $output"
fi

reset_results

# Test 6b: A failed rollback step is reported with the path to remove.

reset_results
drupal_result=1
remove_pool_result=1
output="$(run_installation_workflow || true)"

if [[ "$output" == *"[WARNING] Remove the PHP-FPM pool manually: /etc/php/8.5/fpm/pool.d/test_drupal.conf"* ]] &&
   [[ "$output" != *"[OK] Rollback completed."* ]]; then
    pass "Failed rollback step reported with the path to remove"
else
    fail "Unexpected failed rollback output: $output"
fi

# Test 7: The database password never reaches the log.

if grep -q "Secret#Pass1" "$LOG_FILE"; then
    fail "Database password written to the log"
elif grep -q "Database: mariadb (credentials are not logged)" "$LOG_FILE"; then
    pass "Database password kept out of the log"
else
    fail "Database step not logged"
fi

# Ctrl+C during the installation: what the run created is removed,
# newest first, and the run stops with exit code 130.

reset_results
status=0
removals_file="$(mktemp)"
output="$(composer_interrupt=1 run_installation_workflow)" || status=$?
interrupt_calls="$(paste -sd' ' "$removals_file")"
rm -f "$removals_file"
removals_file=""

if [[ "$status" -eq 130 && "$output" == *"(back to the terminal)"*"[INTERRUPTED] Stopping the installation."* &&
      "$output" == *"[OK] Rollback completed."* && "$interrupt_calls" == "site pool database directory" ]]; then
    pass "Ctrl+C during the installation: output back on the terminal, created resources removed, exit code 130"
else
    fail "interrupt: $status / $output / $interrupt_calls"
fi

echo "[SUCCESS] Installation workflow tests passed."
