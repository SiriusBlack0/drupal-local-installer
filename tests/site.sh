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
    site:install)
        # Like Drush: the temporary password Drupal made up.
        echo " [success] Installation complete.  User name: admin  User password: Tmp9xYzQ"
        exit "${DRUSH_INSTALL_RESULT:-0}"
        ;;
    php:eval)
        input="$(cat)"
        if [[ "$input" == "$EXPECTED_ADMIN_PASSWORD" ]]; then
            echo "password-ok"
        else
            echo "password-mismatch for $input"
        fi
        ;;
    status)
        if [[ "$*" == *db-status* ]]; then
            echo "${DRUSH_DB_STATUS:-Connected}"
        else
            echo "${DRUSH_BOOTSTRAP:-Successful}"
        fi
        ;;
    core:requirements) printf '%s\n' "${DRUSH_REQUIREMENTS:-[]}" ;;
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

# Test 1: settings for every engine. The secrets go to settings.local.php,
# settings.php gets only the host, the config directory and the include.

SALT="$(generate_hash_salt)"
mysql_settings="$(generate_drupal_local_settings mariadb firsttest firsttest_user "$DB_SECRET" "" "$SALT")"
pg_settings="$(generate_drupal_local_settings postgresql firsttest firsttest_user "$DB_SECRET" "" "$SALT")"
sqlite_settings="$(generate_drupal_local_settings sqlite "" "" "" /var/www/firsttest/private/database.sqlite "$SALT")"
main_settings="$(generate_drupal_settings firsttest)"

if [[ "$mysql_settings" == "<?php"* &&
      "$mysql_settings" == *"'driver' => 'mysql'"* &&
      "$mysql_settings" == *"'namespace' => 'Drupal\\\\mysql\\\\Driver\\\\Database\\\\mysql'"* &&
      "$mysql_settings" == *"\$settings['hash_salt'] = '$SALT';"* &&
      "$pg_settings" == *"'driver' => 'pgsql'"* && "$pg_settings" == *"'port' => '5432'"* &&
      "$sqlite_settings" == *"'database' => '/var/www/firsttest/private/database.sqlite'"* &&
      "$sqlite_settings" != *"'username'"* &&
      "$main_settings" == *"trusted_host_patterns'] = ['^firsttest\\\\.localhost\$']"* &&
      "$main_settings" == *"config_sync_directory'] = '../config/sync'"* &&
      "$main_settings" == *"include \$app_root . '/' . \$site_path . '/settings.local.php';"* &&
      "$main_settings" != *"databases"* && "$main_settings" != *"hash_salt'] ="* ]]; then
    pass "settings.local.php for MariaDB/MySQL, PostgreSQL and SQLite; settings.php block without secrets"
else
    fail "settings content: $mysql_settings / $main_settings"
fi

if [[ "$SALT" =~ ^[A-Za-z0-9_-]{70,}$ && "$SALT" != "$(generate_hash_salt)" ]]; then
    pass "Hash salt: random, URL-safe, as long as Drupal's"
else
    fail "hash salt: $SALT"
fi

# Test 2: the generated PHP is valid, keeps every value exactly, and
# settings.php reads settings.local.php.

if ! command -v php > /dev/null; then
    echo "[SKIP] PHP not installed"
else
    tricky="a'b\\c%d"
    site_dir="$work_dir/php_check/sites/default"
    mkdir -p "$site_dir"
    generate_drupal_local_settings mysql firsttest firsttest_user "$tricky" "" "$SALT" > "$site_dir/settings.local.php"
    {
        echo '<?php'
        # shellcheck disable=SC2016  # PHP code, not shell.
        echo '$app_root = __DIR__ . "/../.."; $site_path = "sites/default";'
        generate_drupal_settings firsttest
        # shellcheck disable=SC2016  # PHP code, not shell.
        echo 'echo $databases["default"]["default"]["password"], "|", $settings["trusted_host_patterns"][0], "|", $settings["hash_salt"];'
    } > "$site_dir/settings.php"

    if [[ "$(php "$site_dir/settings.php")" == "${tricky}|^firsttest\\.localhost\$|$SALT" ]] &&
       php -r 'exit(preg_match("{^firsttest\\.localhost$}i", "firsttest.localhost") ? 0 : 1);'; then
        pass "Generated PHP is valid; settings.php includes settings.local.php; quotes and backslashes survive"
    else
        fail "PHP round trip: $(php "$site_dir/settings.php" 2>&1)"
    fi
fi

# Test 3: invalid input is rejected.

if generate_drupal_settings "my-site" > /dev/null 2>&1 ||
   generate_drupal_local_settings oracle a b c "" "$SALT" > /dev/null 2>&1 ||
   generate_drupal_local_settings mariadb "bad name" b c "" "$SALT" > /dev/null 2>&1 ||
   generate_drupal_local_settings mariadb a b "" "" "$SALT" > /dev/null 2>&1 ||
   generate_drupal_local_settings sqlite "" "" "" "relative/db.sqlite" "$SALT" > /dev/null 2>&1 ||
   generate_drupal_local_settings mariadb a b c "" "short'salt" > /dev/null 2>&1; then
    fail "Invalid settings input accepted"
else
    pass "Invalid name, engine, database, empty password, relative SQLite path and bad salt rejected"
fi

# Test 4: settings.php is Drupal's template plus our block;
# settings.local.php is private and holds the secrets.

set_mariadb_project
project="$(new_project site_a)"
settings_file="$project/web/sites/default/settings.php"
local_file="$project/web/sites/default/settings.local.php"

if write_drupal_settings "$project" "$current_user" > /dev/null &&
   head -3 "$settings_file" | grep -qxF "$template_line" &&
   ! grep -qF "$DB_SECRET" "$settings_file" &&
   grep -qF "'password' => '$DB_SECRET'" "$local_file" &&
   grep -qE "^\\\$settings\\['hash_salt'\\] = '[A-Za-z0-9_-]{70,}';\$" "$local_file" &&
   [[ "$(stat -c '%a' "$local_file")" == "600" && -d "$project/config/sync" ]] &&
   check_settings_without_secrets "$project"; then
    pass "settings.php = template + block (no secrets); settings.local.php private (600); config/sync created"
else
    fail "settings files: $(cat "$local_file" 2>&1)"
fi

# Drupal's installer would write the database into settings.php: caught.
printf "\$databases['default']['default'] = [];\n" >> "$settings_file"
with_db="$(check_settings_without_secrets "$project" && echo clean || echo found)"
sed -i '$d' "$settings_file"
printf "\$settings['hash_salt'] = 'abc';\n" >> "$settings_file"
with_salt="$(check_settings_without_secrets "$project" && echo clean || echo found)"
sed -i '$d' "$settings_file"
printf "\$settings['hash_salt'] = '';\n\$databases = [];\n" >> "$settings_file"
template_only="$(check_settings_without_secrets "$project" && echo clean || echo found)"

if [[ "$with_db" == found && "$with_salt" == found && "$template_only" == clean ]]; then
    pass "Database settings or a hash salt in settings.php are detected; the template's empty ones are not"
else
    fail "secret check: $with_db $with_salt $template_only"
fi

if write_drupal_settings "$project" "$current_user" > /dev/null; then
    fail "Existing settings.php overwritten"
else
    pass "Existing settings.php left untouched"
fi

rm -f "$settings_file"

if output="$(write_drupal_settings "$project" "$current_user")"; then
    fail "Existing settings.local.php overwritten"
elif [[ "$output" == *"settings.local.php already exists"* ]]; then
    pass "Existing settings.local.php left untouched"
else
    fail "existing settings.local.php: $output"
fi

rm -f "$project/web/sites/default/default.settings.php" "$local_file"

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

if grep -q "User password: \[temporary password, replaced by the installer\]" "$LOG_FILE" &&
   ! grep -q "Tmp9xYzQ" "$LOG_FILE"; then
    pass "The temporary password of site:install is masked in the log"
else
    fail "temporary password in log: $(grep -i 'password' "$LOG_FILE")"
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

# composer audit (lib/update/check.sh): 1 = no advisory, 0 = advisory,
# 2 = could not check.
has_core_security_advisory() { return "${SECURITY_STATUS:-1}"; }

# Test 8: Final checks only report; they never fail the installation.

if ! command -v php > /dev/null; then
    echo "[SKIP] PHP not installed: final checks"
else
    php_version="$(php -r 'echo PHP_MAJOR_VERSION, ".", PHP_MINOR_VERSION;')"
    project="$(new_project site_f)"
    mkdir -p "$project/web/sites/default/files"
    printf '<?php\n' > "$project/web/sites/default/settings.php"
    chmod 0444 "$project/web/sites/default/settings.php"

    output="$(run_final_checks "$project" "$current_user" "$php_version")"

    if [[ "$output" == *"[OK] Database connection"* &&
          "$output" == *"[OK] Files directory is writable"* &&
          "$output" == *"[OK] settings.php cannot be changed by other users (444)"* &&
          "$output" == *"[OK] Drupal status report: no errors"* &&
          "$output" == *"[OK] settings.php has no secrets"* &&
          "$output" == *"[OK] No known security advisory for Drupal core"* &&
          "$output" != *"WARNING"* ]]; then
        pass "Final checks: database, files, settings.php, status report"
    else
        fail "final checks: $output"
    fi

    chmod 0666 "$project/web/sites/default/settings.php"
    rmdir "$project/web/sites/default/files"

    if output="$(DRUSH_DB_STATUS="none" \
            DRUSH_REQUIREMENTS='{"cron":{"title":"Cron <em>maintenance</em>","severity":"Error"}}' \
            run_final_checks "$project" "$current_user" "$php_version")" &&
       [[ "$output" == *"[WARNING] Drush reports no database connection."* &&
          "$output" == *"[WARNING] Files directory is missing or not writable"* &&
          "$output" == *"[WARNING] settings.php is writable by other users"* &&
          "$output" == *"- Cron maintenance"* &&
          "$output" == *"[INFO] 4 check(s) need attention"* ]]; then
        pass "Problems are reported as warnings, not failures"
    else
        fail "final check warnings: $output"
    fi

    if output="$(SECURITY_STATUS=0 DRUPAL_VERSION=10.5.9 run_final_checks "$project" "$current_user" "$php_version")" &&
       [[ "$output" == *"[WARNING] Drupal core 10.5.9 has published security advisories."* &&
          "$output" == *"Composer refuses to add modules (composer require) until core is"* &&
          "$output" == *"updated: ./install.sh --update site_f"* ]] &&
       output="$(SECURITY_STATUS=2 run_final_checks "$project" "$current_user" "$php_version")" &&
       [[ "$output" == *"[SKIPPED] Security advisories could not be checked"* ]]; then
        pass "Security advisories of the installed core: warned, with what it means and the fix"
    else
        fail "security check: $output"
    fi

    if output="$(DRUSH_REQUIREMENTS='not json' run_final_checks "$project" "$current_user" "$php_version")" &&
       [[ "$output" == *"[SKIPPED] Drupal status report could not be read."* ]]; then
        pass "Unreadable status report is skipped"
    else
        fail "unreadable status report: $output"
    fi
fi

echo "[SUCCESS] Drupal site installation tests passed."
