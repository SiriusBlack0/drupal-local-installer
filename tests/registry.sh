#!/usr/bin/env bash

# Project registry: one record per project, no passwords, parsed as
# data. Everything happens in a temporary directory.

set -euo pipefail

cd "$(dirname "$0")/.."

source lib/output.sh
source lib/php_fpm.sh
source lib/nginx.sh
source lib/registry.sh
source lib/project.sh

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
export XDG_DATA_HOME="$work_dir/data"

pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; exit 1; }

# The variables below are read by lib/registry.sh.
# shellcheck disable=SC2034
set_project() {
    PROJECT_NAME="Third Test"
    PROJECT_MACHINE_NAME="$1"
    PROJECT_USER="$(id -un)"
    PROJECT_PATH="$work_dir/www/$1"
    DRUPAL_VERSION="11.4.10"
    PHP_VERSION="8.5"
    DATABASE_ENGINE="${2:-mariadb}"
    DATABASE_NAME="$1"
    DATABASE_USER="${1}_user"
    # Set on purpose: the test proves they never reach the record.
    export DATABASE_PASSWORD="Db#Secret.42"
    SQLITE_DATABASE_PATH="$PROJECT_PATH/private/database.sqlite"
    export ADMIN_PASSWORD="AdminSecret99"
    LOG_FILE="/home/dev/.local/state/drupal-local-installer/logs/x.log"
    mkdir -p "$PROJECT_PATH"
}

registry_dir="$XDG_DATA_HOME/drupal-local-installer/projects"

# Test 1: The record holds every field and no password.

set_project thirdtest

if output="$(write_project_record)" &&
   [[ "$output" == "[OK] Project registered: $registry_dir/thirdtest.conf" ]]; then
    pass "Project record written"
else
    fail "write: $output"
fi

record="$registry_dir/thirdtest.conf"

for expected in "format=1" "name=Third Test" "machine_name=thirdtest" \
    "project_path=$work_dir/www/thirdtest" "url=http://thirdtest.localhost" \
    "drupal_version=11.4.10" "install_profile=standard" "php_version=8.5" \
    "database_engine=mariadb" "database_name=thirdtest" "database_user=thirdtest_user" \
    "sqlite_path=" "php_fpm_pool=/etc/php/8.5/fpm/pool.d/thirdtest.conf" \
    "php_fpm_socket=/run/php/php8.5-fpm-thirdtest.sock" \
    "nginx_available=/etc/nginx/sites-available/thirdtest.conf" \
    "nginx_enabled=/etc/nginx/sites-enabled/thirdtest.conf" \
    "owner=$(id -un)"; do
    grep -qxF "$expected" "$record" || fail "missing line: $expected"
done

if grep -qE '^created=[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$record"; then
    pass "All project details recorded"
else
    fail "created timestamp"
fi

if grep -qF "Db#Secret.42" "$record" || grep -qF "AdminSecret99" "$record" ||
   grep -qi "password" <(grep -v '^#' "$record"); then
    fail "A password was written to the registry"
else
    pass "No password in the registry"
fi

if [[ "$(stat -c '%a' "$record")" == "600" && "$(stat -c '%a' "$registry_dir")" == "700" ]] &&
   [[ -z "$(find "$registry_dir" -name '.*.tmp')" ]]; then
    pass "Record 600, directory 700, no temporary file left"
else
    fail "permissions: $(stat -c '%a %n' "$record" "$registry_dir")"
fi

# Test 2: SQLite records the file instead of database name and user.

set_project sqlitesite sqlite
write_project_record > /dev/null

if grep -qxF "sqlite_path=$work_dir/www/sqlitesite/private/database.sqlite" "$registry_dir/sqlitesite.conf" &&
   grep -qxF "database_name=" "$registry_dir/sqlitesite.conf" &&
   grep -qxF "database_user=" "$registry_dir/sqlitesite.conf"; then
    pass "SQLite record holds the database file"
else
    fail "SQLite record"
fi

# Test 3: An existing record is never replaced.

set_project thirdtest

if write_project_record > /dev/null; then
    fail "Existing record replaced"
elif grep -qxF "name=Third Test" "$record"; then
    pass "Existing record left untouched"
else
    fail "Existing record changed"
fi

# Test 4: Reading fields; the record is data, never executed.

if [[ "$(read_project_field "$record" php_version)" == "8.5" ]] &&
   [[ "$(read_project_field "$record" name)" == "Third Test" ]] &&
   ! read_project_field "$record" no_such_field > /dev/null; then
    pass "Fields read by name"
else
    fail "read_project_field"
fi

# Single quotes on purpose: the command must stay literal in the file.
# shellcheck disable=SC2016
printf 'machine_name=evil\nurl=$(touch %s/pwned)\n' "$work_dir" > "$registry_dir/evil.conf"

if [[ "$(read_project_field "$registry_dir/evil.conf" url)" == "\$(touch $work_dir/pwned)" ]] &&
   list_registered_projects > /dev/null && [[ ! -e "$work_dir/pwned" ]]; then
    pass "A changed record is read as text and never executed"
else
    fail "record was executed"
fi

rm -f "$registry_dir/evil.conf"

# Test 5: --list shows every project and notices missing directories.

rm -rf "$work_dir/www/sqlitesite"
output="$(list_registered_projects)"

if [[ "$output" == *"thirdtest"*"http://thirdtest.localhost"*"8.5"*"mariadb"*"ok"* ]] &&
   [[ "$output" == *"sqlitesite"*"sqlite"*"directory missing"* ]]; then
    pass "List shows projects and missing directories"
else
    fail "list: $output"
fi

empty_output="$(XDG_DATA_HOME="$work_dir/empty" list_registered_projects)"

if [[ "$empty_output" == *"No projects registered yet."* ]]; then
    pass "Empty registry reported"
else
    fail "empty list: $empty_output"
fi

# Test 6: Without XDG_DATA_HOME the registry is in the developer's home,
# also when the installer runs with sudo (PROJECT_USER is the developer).

expected_home="$(getent passwd "$(id -un)" | cut -d: -f6)"

if [[ "$(XDG_DATA_HOME="" PROJECT_USER="$(id -un)" get_registry_directory)" == "$expected_home/.local/share/drupal-local-installer/projects" ]]; then
    pass "Registry in the developer's home"
else
    fail "registry directory: $(XDG_DATA_HOME="" get_registry_directory)"
fi

echo "[SUCCESS] Project registry tests passed."
