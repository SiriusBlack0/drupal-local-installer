#!/usr/bin/env bash

# drush site:install step. Drush, curl and the project are stubs in a
# temporary directory; nothing on the system is touched.

set -euo pipefail

cd "$(dirname "$0")/.."

source lib/output.sh
source lib/system.sh
source lib/database.sh
source lib/php_fpm.sh
source lib/nginx.sh
source lib/registry.sh
source lib/project.sh
source lib/site.sh

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; exit 1; }

current_user="$(id -un)"
stub_bin="$work_dir/bin"
mkdir -p "$stub_bin"
export DRUSH_CALLS="$work_dir/drush_calls"
argv_log="$work_dir/argv"
LOG_FILE="$work_dir/install.log"
touch "$LOG_FILE"

DB_SECRET="Db#Secret.42"
ADMIN_SECRET="Admin pass with 'quotes' \\ and spaces"

# Every command run as the project user is recorded, to prove that no
# password ever appears in a command line.
run_as_project_user() {
    shift
    printf '%s\n' "$*" >> "$argv_log"
    "$@"
}

# curl answers with the headers in $CURL_HEADERS for both IP families.
cat > "$stub_bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%b' "${CURL_HEADERS:-}"
STUB
chmod +x "$stub_bin/curl"
PATH="$stub_bin:$PATH"

new_project() {
    local project="$work_dir/$1"
    rm -rf "$project"
    mkdir -p "$project/web/sites/default"
    printf '<?php\n\n%s\n' "$template_line" > "$project/web/sites/default/default.settings.php"

    cat > "$project/drush" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$DRUSH_CALLS"
case "$1" in
    site:install) exit "${DRUSH_INSTALL_RESULT:-0}" ;;
    php:eval)
        input="$(cat)"
        if [[ "$input" == "$EXPECTED_ADMIN_PASSWORD" ]]; then
            echo "password-ok"
        else
            echo "password-mismatch for $input"
        fi
        ;;
    status) echo "${DRUSH_BOOTSTRAP:-Successful}" ;;
esac
STUB
    chmod +x "$project/drush"
    : > "$DRUSH_CALLS"
    : > "$argv_log"
    printf '%s\n' "$project"
}

set_mariadb_project() {
    PROJECT_NAME="First Test"
    PROJECT_MACHINE_NAME="firsttest"
    DATABASE_ENGINE="mariadb"
    DATABASE_NAME="firsttest"
    DATABASE_USER="firsttest_user"
    DATABASE_PASSWORD="$DB_SECRET"
    SQLITE_DATABASE_PATH=""
    ADMIN_USER="admin"
    ADMIN_MAIL="admin@example.com"
    ADMIN_PASSWORD="$ADMIN_SECRET"
    export EXPECTED_ADMIN_PASSWORD="$ADMIN_SECRET"
}

# PHP code below is written in single quotes on purpose: it is PHP,
# not shell, so "$databases" must stay literal.
# shellcheck disable=SC2016
template_line='$databases = [];'

installed_headers='HTTP/1.1 200 OK\r\nX-Generator: Drupal 11 (https://www.drupal.org)\r\n'
installer_headers='HTTP/1.1 302 Found\r\nLocation: http://firsttest.localhost/core/install.php\r\n'

# Test 1: settings for every engine.

mysql_settings="$(generate_drupal_settings firsttest mariadb firsttest firsttest_user "$DB_SECRET" "")"
pg_settings="$(generate_drupal_settings firsttest postgresql firsttest firsttest_user "$DB_SECRET" "")"
sqlite_settings="$(generate_drupal_settings firsttest sqlite "" "" "" /var/www/firsttest/private/database.sqlite)"

if [[ "$mysql_settings" == *"'driver' => 'mysql'"* &&
      "$mysql_settings" == *"'namespace' => 'Drupal\\\\mysql\\\\Driver\\\\Database\\\\mysql'"* &&
      "$pg_settings" == *"'driver' => 'pgsql'"* && "$pg_settings" == *"'port' => '5432'"* &&
      "$sqlite_settings" == *"'database' => '/var/www/firsttest/private/database.sqlite'"* &&
      "$sqlite_settings" != *"'username'"* &&
      "$mysql_settings" == *"trusted_host_patterns'] = ['^firsttest\\\\.localhost\$']"* &&
      "$mysql_settings" == *"config_sync_directory'] = '../config/sync'"* ]]; then
    pass "settings.php block for MariaDB/MySQL, PostgreSQL and SQLite"
else
    fail "settings content: $mysql_settings"
fi

# Test 2: the generated PHP is valid and keeps every value exactly.

if ! command -v php > /dev/null; then
    echo "[SKIP] PHP not installed"
else
    tricky="a'b\\c%d"
    php_file="$work_dir/check.php"
    {
        echo '<?php'
        generate_drupal_settings firsttest mysql firsttest firsttest_user "$tricky" ""
        # shellcheck disable=SC2016  # PHP code, not shell.
        echo 'echo $databases["default"]["default"]["password"], "|", $settings["trusted_host_patterns"][0];'
    } > "$php_file"

    if [[ "$(php "$php_file")" == "${tricky}|^firsttest\\.localhost\$" ]] &&
       php -r 'exit(preg_match("{^firsttest\\.localhost$}i", "firsttest.localhost") ? 0 : 1);'; then
        pass "Generated PHP is valid; quotes and backslashes survive"
    else
        fail "PHP round trip: $(php "$php_file" 2>&1)"
    fi
fi

# Test 3: invalid input is rejected.

if generate_drupal_settings "my-site" mariadb a b c "" > /dev/null 2>&1 ||
   generate_drupal_settings firsttest oracle a b c "" > /dev/null 2>&1 ||
   generate_drupal_settings firsttest mariadb "bad name" b c "" > /dev/null 2>&1 ||
   generate_drupal_settings firsttest mariadb a b "" "" > /dev/null 2>&1 ||
   generate_drupal_settings firsttest sqlite "" "" "" "relative/db.sqlite" > /dev/null 2>&1; then
    fail "Invalid settings input accepted"
else
    pass "Invalid name, engine, database, empty password and relative SQLite path rejected"
fi

# Test 4: settings.php is Drupal's template plus our block.

set_mariadb_project
project="$(new_project site_a)"

if write_drupal_settings "$project" "$current_user" > /dev/null &&
   head -3 "$project/web/sites/default/settings.php" | grep -qxF "$template_line" &&
   grep -qF "'password' => '$DB_SECRET'" "$project/web/sites/default/settings.php"; then
    pass "settings.php = default.settings.php + project block"
else
    fail "settings.php content"
fi

if write_drupal_settings "$project" "$current_user" > /dev/null; then
    fail "Existing settings.php overwritten"
else
    pass "Existing settings.php left untouched"
fi

rm -f "$project/web/sites/default/default.settings.php" "$project/web/sites/default/settings.php"

if output="$(write_drupal_settings "$project" "$current_user")"; then
    fail "Missing template accepted"
elif [[ "$output" == *"template not found"* ]]; then
    pass "Missing Drupal template reported"
else
    fail "missing template: $output"
fi

install_drupal_site_now() {
    install_drupal_site "$1" "$current_user" \
        "$PROJECT_NAME" "$ADMIN_USER" "$ADMIN_MAIL" "$ADMIN_PASSWORD"
}

# Test 5: the whole step, and no password in any command line or log.

project="$(new_project site_b)"
export CURL_HEADERS="$installed_headers"

if output="$(install_drupal_site_now "$project")" &&
   [[ "$output" == *"[OK] Administrator password set"* ]] &&
   [[ "$output" == *"[OK] Drupal site installed and answering: http://firsttest.localhost"* ]]; then
    pass "Settings, site:install, password and checks succeed"
else
    fail "install_drupal_site: $output"
fi

if grep -qxF 'site:install standard --yes --site-name=First Test --site-mail=admin@example.com --account-name=admin --account-mail=admin@example.com' "$DRUSH_CALLS"; then
    pass "site:install runs the standard profile with the project name"
else
    fail "site:install arguments: $(cat "$DRUSH_CALLS")"
fi

if grep -qF "$DB_SECRET" "$argv_log" "$DRUSH_CALLS" "$LOG_FILE" ||
   grep -qF "$ADMIN_SECRET" "$argv_log" "$DRUSH_CALLS" "$LOG_FILE"; then
    fail "A password appeared in a command line or the log"
else
    pass "No password in any command line or in the log"
fi

# Test 6: failures stop the step.

project="$(new_project site_c)"

if DRUSH_INSTALL_RESULT=1 install_drupal_site_now "$project" > /dev/null; then
    fail "Failed site:install reported as success"
elif grep -q "^php:eval" "$DRUSH_CALLS"; then
    fail "Password set after a failed site:install"
else
    pass "Failed site:install stops the step"
fi

project="$(new_project site_d)"
export EXPECTED_ADMIN_PASSWORD="something else"

if output="$(install_drupal_site_now "$project")"; then
    fail "Password mismatch reported as success"
elif [[ "$output" == *"administrator password could not be set"* ]] &&
     ! grep -qF "$ADMIN_SECRET" "$LOG_FILE"; then
    pass "Password failure reported; the password is masked in the log"
else
    fail "password failure: $output"
fi

export EXPECTED_ADMIN_PASSWORD="$ADMIN_SECRET"

# Test 7: final checks.

project="$(new_project site_e)"

if output="$(DRUSH_BOOTSTRAP="Failed" verify_drupal_site "$project" "$current_user" firsttest)"; then
    fail "Failed bootstrap reported as success"
elif [[ "$output" == *"cannot bootstrap"* ]]; then
    pass "Drush bootstrap failure detected"
else
    fail "bootstrap failure: $output"
fi

if output="$(CURL_HEADERS="$installer_headers" verify_drupal_site "$project" "$current_user" firsttest)"; then
    fail "Uninstalled site reported as installed"
elif [[ "$output" == *"does not answer as an installed Drupal site"* ]]; then
    pass "Site still showing the installer is detected"
else
    fail "installer redirect: $output"
fi

echo "[SUCCESS] Drupal site installation tests passed."
