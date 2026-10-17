#!/usr/bin/env bash

# ./install.sh --check-updates and --update NAME. Everything happens in a
# temporary directory: composer, drush, php8.5, sudo, mysqldump, mysql
# and curl are stubs that record their calls.

set -euo pipefail

cd "$(dirname "$0")/.."

source lib/output.sh
source lib/system.sh
source lib/database.sh
source lib/php_fpm.sh
source lib/nginx.sh
source lib/registry.sh
source lib/project.sh
source lib/compatibility.sh
source lib/scan.sh
source lib/remove.sh
source lib/update.sh

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

export XDG_DATA_HOME="$work_dir/data"
export DRUPAL_PROJECTS_DIR="$work_dir/www"
etc_dir="$work_dir/etc"
stub_bin="$work_dir/bin"
export CALLS_FILE="$work_dir/calls"
export REAL_PHP
REAL_PHP="$(command -v php)"
mkdir -p "$DRUPAL_PROJECTS_DIR" "$etc_dir/sites-available" "$etc_dir/sites-enabled" "$etc_dir/pool.d" "$stub_bin"

pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; exit 1; }

get_nginx_config_path() { printf '%s/sites-available/%s.conf\n' "$etc_dir" "$1"; }
get_nginx_enabled_path() { printf '%s/sites-enabled/%s.conf\n' "$etc_dir" "$1"; }
get_php_fpm_pool_config_path() { printf '%s/pool.d/%s.conf\n' "$etc_dir" "$1"; }
get_backup_base_dir() { printf '%s/backups\n' "$work_dir"; }
get_installed_database_version() { [[ -n "${DB_VERSION:-}" ]] && echo "$DB_VERSION"; }
require_sudo() { echo "sudo-asked" >> "$CALLS_FILE"; }

# php8.5: PHP code runs with the real php; anything else (composer) is
# started directly.
cat > "$stub_bin/php8.5" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == "-r" ]] && exec "$REAL_PHP" "$@"
exec "$@"
STUB

cat > "$stub_bin/sudo" <<'STUB'
#!/usr/bin/env bash
echo "sudo $*" >> "$CALLS_FILE"
[[ "$1" == "-u" ]] && shift 2
exec "$@"
STUB

cat > "$stub_bin/mysqldump" <<'STUB'
#!/usr/bin/env bash
echo "dump $*" >> "$CALLS_FILE"
[[ "${DUMP_FAILS:-0}" == "1" ]] && exit 1
echo "CREATE TABLE node;"
STUB

cat > "$stub_bin/mysql" <<'STUB'
#!/usr/bin/env bash
echo "mysql restore: $(cat)" >> "$CALLS_FILE"
STUB

# PostgreSQL: the owner query, the server version and the restore.
cat > "$stub_bin/psql" <<'STUB'
#!/usr/bin/env bash
if [[ " $* " == *" -c SHOW server_version_num "* ]]; then echo 160013; exit 0; fi
input="$(cat)"
if [[ "$input" == *"pg_get_userbyid"* ]]; then
    echo "psql owner query $*" >> "$CALLS_FILE"
    echo "delta_user"
    exit 0
fi
echo "psql restore $*: $input" >> "$CALLS_FILE"
STUB

for tool in pg_dump dropdb createdb; do
    cat > "$stub_bin/$tool" <<'STUB'
#!/usr/bin/env bash
echo "$(basename "$0") $*" >> "$CALLS_FILE"
[[ "$(basename "$0")" == "pg_dump" ]] && echo "CREATE TABLE node;"
exit 0
STUB
done

cat > "$stub_bin/curl" <<'STUB'
#!/usr/bin/env bash
[[ "${CURL_FAILS:-0}" == "1" ]] && exit 7
printf 'HTTP/1.1 200 OK\r\nX-Generator: Drupal 11 (https://www.drupal.org)\r\n'
STUB

# Composer: the lock file holds "core=<version>"; install and update
# write that version into core/lib/Drupal.php like the real thing would.
cat > "$stub_bin/composer" <<'STUB'
#!/usr/bin/env bash
dir=""
args=()
for a in "$@"; do
    case "$a" in
        --working-dir=*) dir="${a#--working-dir=}" ;;
        --no-interaction) ;;
        *) args+=("$a") ;;
    esac
done
echo "composer ${args[*]}" >> "$CALLS_FILE"
set_version() {
    printf "<?php\nclass Drupal {\n  const VERSION = '%s';\n}\n" "$1" > "$dir/web/core/lib/Drupal.php"
}
case "${args[0]}" in
    show)
        echo "{\"name\":\"${args[-1]}\",\"versions\":${COMPOSER_VERSIONS:-[]}}"
        ;;
    audit)
        if [[ "${AUDIT_CORE:-0}" == "1" ]]; then
            echo '{"advisories":{"drupal/core":[{"title":"SA-CORE"}]}}'
            exit 1
        fi
        echo '{"advisories":[]}'
        ;;
    update)
        target=""
        for a in "${args[@]}"; do [[ "$a" == drupal/core*:* ]] && target="${a##*:}"; done
        if [[ " ${args[*]} " == *" --dry-run "* ]]; then
            if [[ "${DRYRUN_FAILS:-0}" == "1" ]]; then
                echo "Your requirements could not be resolved to an installable set of packages."
                echo "  - Root composer.json requires drupal/core-recommended ~11.3.0"
                exit 2
            fi
            echo "Lock file operations: 1 install, 2 updates, 0 removals"
            echo "  - Upgrading drupal/core ($(grep -oP 'core=\K.*' "$dir/composer.lock") => $target)"
            echo "  - Upgrading symfony/console (v7.3.0 => v7.3.4)"
            exit 0
        fi
        echo "core=$target" > "$dir/composer.lock"
        [[ "${UPDATE_FAILS:-0}" == "1" ]] && exit 1
        set_version "$target"
        ;;
    install)
        set_version "$(grep -oP 'core=\K.*' "$dir/composer.lock")"
        ;;
esac
STUB

chmod +x "$stub_bin"/*
PATH="$stub_bin:$PATH"

# The ./drush launcher of a project: records its calls; behaviour is
# controlled by environment variables.
write_drush_stub() {
    cat > "$1/drush" <<'STUB'
#!/usr/bin/env bash
echo "drush $*" >> "$CALLS_FILE"
web="$(dirname "$0")/web"
case "$1" in
    status)
        [[ "${BOOTSTRAP_FAILS:-0}" == "1" ]] && exit 1
        [[ "${BOOTSTRAP_FAILS_AFTER:-0}" == "1" ]] && ! grep -q "'11.3.10'" "$web/core/lib/Drupal.php" && exit 1
        echo "Successful"
        ;;
    updatedb)
        sqlite="$(dirname "$0")/private/database.sqlite"
        [[ -f "$sqlite" ]] && echo "updated schema" >> "$sqlite"
        [[ "${UPDB_FAILS:-0}" == "1" ]] && exit 1
        ;;
    core:requirements)
        if [[ -n "${NEW_ERROR:-}" ]] && ! grep -q "'11.3.10'" "$web/core/lib/Drupal.php"; then
            echo "[{\"title\":\"$NEW_ERROR\"},{\"title\":\"Cron\"}]"
        else
            echo '[{"title":"Cron"}]'
        fi
        ;;
esac
exit 0
STUB
    chmod +x "$1/drush"
}

make_project() {
    local name="$1"

    PROJECT_NAME="$name"
    PROJECT_MACHINE_NAME="$name"
    PROJECT_USER="$(id -un)"
    PROJECT_PATH="$DRUPAL_PROJECTS_DIR/$name"
    DRUPAL_VERSION="11.3.10"
    PHP_VERSION="8.5"
    DATABASE_ENGINE="${2:-mariadb}"
    DATABASE_NAME="$name"
    DATABASE_USER="${name}_user"
    SQLITE_DATABASE_PATH="$PROJECT_PATH/private/database.sqlite"
    LOG_FILE=""

    rm -rf "$PROJECT_PATH" "$(record_of "$name")"
    mkdir -p "$PROJECT_PATH/web/core/lib" "$PROJECT_PATH/private"
    printf "<?php\nclass Drupal {\n  const VERSION = '11.3.10';\n}\n" > "$PROJECT_PATH/web/core/lib/Drupal.php"
    cat > "$PROJECT_PATH/composer.json" <<'JSON'
{
    "require": {
        "drupal/core-recommended": "^11.3",
        "drupal/core-composer-scaffold": "^11.3",
        "drupal/core-project-message": "^11.3",
        "drush/drush": "^13"
    },
    "require-dev": { "drupal/core-dev": "^11.3" }
}
JSON
    echo "core=11.3.10" > "$PROJECT_PATH/composer.lock"
    echo "SQLite data" > "$SQLITE_DATABASE_PATH"
    write_drush_stub "$PROJECT_PATH"
    echo "site" > "$etc_dir/sites-available/$name.conf"
    ln -sf "$etc_dir/sites-available/$name.conf" "$etc_dir/sites-enabled/$name.conf"
    echo "pool" > "$etc_dir/pool.d/$name.conf"
    write_project_record > /dev/null
    : > "$CALLS_FILE"
}

record_of() { printf '%s/drupal-local-installer/projects/%s.conf\n' "$XDG_DATA_HOME" "$1"; }
version_of() { get_drupal_version_in "$DRUPAL_PROJECTS_DIR/$1/web"; }
calls_line() { grep -n -m1 -F -- "$1" "$CALLS_FILE" | cut -d: -f1; }

export COMPOSER_VERSIONS='["12.0.1","11.5.0","11.4.2","11.4.0","11.4.0-rc1","11.3.12","11.3.11","11.3.10","11.x-dev","10.6.3"]'

# Test 1: Targets: newest patch of the same minor, newest minor that is
# in the compatibility table (11.5 is not), never a major.

make_project alpha
UPDATE_CORE_PACKAGE="drupal/core-recommended"

if [[ "$(get_update_targets "$PROJECT_PATH" 8.5 11.3.10)" == "11.3.12|11.4.2" &&
      "$(get_update_targets "$PROJECT_PATH" 8.5 11.3.12)" == "|11.4.2" &&
      "$(get_update_targets "$PROJECT_PATH" 8.5 11.4.2)" == "|" ]]; then
    pass "Update targets: patch, known minor, no major"
else
    fail "targets: $(get_update_targets "$PROJECT_PATH" 8.5 11.3.10)"
fi

if [[ "$(get_core_packages "$PROJECT_PATH" 8.5 | paste -sd' ')" == "drupal/core-recommended drupal/core-composer-scaffold drupal/core-project-message drupal/core-dev" ]]; then
    pass "Core package and its companions found in composer.json"
else
    fail "core packages: $(get_core_packages "$PROJECT_PATH" 8.5)"
fi

# Test 2: Compatibility of the target.

if output="$(check_target_compatibility 11.5.0 8.5 mariadb)"; then
    fail "Unknown minor accepted"
elif [[ "$output" == *"not in config/compatibility.conf"* ]] &&
     ! check_target_compatibility 11.4.2 8.2 mariadb > /dev/null &&
     ! DB_VERSION=10.5.2 check_target_compatibility 11.4.2 8.5 mariadb > /dev/null &&
     DB_VERSION=10.11.6 check_target_compatibility 11.4.2 8.5 mariadb > /dev/null; then
    pass "Target blocked for unknown minor, unsupported PHP and old database"
else
    fail "compatibility: $output"
fi

# Test 3: --check-updates table.

output="$(AUDIT_CORE=1 run_check_updates)"

if [[ "$output" == *"alpha"*"11.3.10"*"11.3.12"*"11.4.2"*"YES"* ]] &&
   ! grep -q "composer update" "$CALLS_FILE"; then
    pass "--check-updates shows patch, minor and security; changes nothing"
else
    fail "check-updates: $output"
fi

# Test 4: --dry-run: checks and plan only.

if output="$(printf '1\n' | REMOVE_DRY_RUN=1 run_update_project alpha)" &&
   [[ "$output" == *"Drupal core:  11.3.10 -> 11.3.12"* &&
      "$output" == *"Packages:     2 updated, 1 new, 0 removed"* &&
      "$output" == *"[DRY RUN] Nothing was changed."* ]] &&
   [[ "$(version_of alpha)" == "11.3.10" ]] &&
   ! grep -q "sudo-asked\|drush state:set\|composer update.* --with-all-dependencies$" "$CALLS_FILE" &&
   grep -q -- "--with drupal/core-recommended:11.3.12 --with drupal/core-composer-scaffold:11.3.12 --with drupal/core-project-message:11.3.12 --with drupal/core-dev:11.3.12" "$CALLS_FILE"; then
    pass "--dry-run: plan with all core packages fixed to the target; nothing changed"
else
    fail "dry run: $output / $(cat "$CALLS_FILE")"
fi

# Test 5: Refusals before anything changes.

if output="$(printf '1\n' | DRYRUN_FAILS=1 run_update_project alpha)"; then
    fail "Blocked dry run accepted"
elif [[ "$output" == *"Composer cannot update to 11.3.12"* && "$output" == *"~11.3.0"* ]] &&
     ! grep -q "sudo-asked" "$CALLS_FILE"; then
    pass "Root constraint that blocks the update: Composer's reason shown, nothing changed"
else
    fail "dry-run blocked: $output"
fi

if output="$(BOOTSTRAP_FAILS=1 run_update_project alpha < /dev/null)"; then
    fail "Broken site accepted"
elif [[ "$output" == *"Drush cannot bootstrap it"* ]]; then
    pass "A site that does not work is not updated"
else
    fail "bootstrap: $output"
fi

git -C "$PROJECT_PATH" init -q
git -C "$PROJECT_PATH" add composer.json composer.lock
git -C "$PROJECT_PATH" -c user.email=t@t -c user.name=t commit -q -m init
echo " " >> "$PROJECT_PATH/composer.json"

if output="$(run_update_project alpha < /dev/null)"; then
    fail "Uncommitted composer.json accepted"
elif [[ "$output" == *"uncommitted changes"* ]]; then
    pass "Uncommitted changes in composer.json block the update"
else
    fail "git dirty: $output"
fi

git -C "$PROJECT_PATH" checkout -q composer.json

if output="$(printf '1\nalphaa\n' | run_update_project alpha)"; then
    fail "Wrong name accepted"
elif [[ "$output" == *"Update cancelled"* ]] && ! grep -q "sudo-asked" "$CALLS_FILE" &&
     [[ "$(version_of alpha)" == "11.3.10" ]]; then
    pass "Wrong confirmation cancels before sudo"
else
    fail "wrong name: $output"
fi

printf "<?php\ndefine('VERSION', '7.101');\n" > "$work_dir/bootstrap.inc"
mv "$PROJECT_PATH/web/core/lib/Drupal.php" "$work_dir/Drupal.php"
mkdir -p "$PROJECT_PATH/web/includes"
cp "$work_dir/bootstrap.inc" "$PROJECT_PATH/web/includes/bootstrap.inc"

if output="$(run_update_project alpha < /dev/null)"; then
    fail "Drupal 7 accepted"
elif [[ "$output" == *"Drupal 7.101 is end of life"* ]]; then
    pass "Drupal 7 is refused"
else
    fail "d7: $output"
fi

rm -rf "$PROJECT_PATH/web/includes"
mv "$work_dir/Drupal.php" "$PROJECT_PATH/web/core/lib/Drupal.php"

if output="$(PROJECT_USER=someoneelse run_update_project alpha < /dev/null)"; then
    fail "Folder of another user accepted"
elif [[ "$output" == *"not to you (someoneelse)"* ]]; then
    pass "A project folder of another user is refused"
else
    fail "owner: $output"
fi

# Test 6: Successful update.

: > "$CALLS_FILE"

if output="$(printf '2\nalpha\n' | NEW_ERROR="Update notifications" run_update_project alpha)" &&
   [[ "$(version_of alpha)" == "11.4.2" ]] &&
   [[ "$(read_project_field "$(record_of alpha)" drupal_version)" == "11.4.2" ]] &&
   [[ "$output" == *"[DONE] alpha: Drupal 11.3.10 -> 11.4.2"* &&
      "$output" == *"[WARNING] New errors in the Drupal status report"* &&
      "$output" == *"- Update notifications"* && "$output" != *"- Cron"* ]]; then
    pass "Minor update: code, database update, registry version, new status errors"
else
    fail "update: $output / $(cat "$CALLS_FILE")"
fi

backup="$(find "$work_dir/backups" -maxdepth 1 -name 'alpha-update-*' -type d | head -n 1)"

if [[ -n "$backup" && "$(stat -c '%a' "$backup")" == "700" &&
      "$(stat -c '%a' "$backup/database.sql.gz")" == "600" ]] &&
   zcat "$backup/database.sql.gz" | grep -q "CREATE TABLE node" &&
   grep -qx "core=11.3.10" "$backup/composer.lock" &&
   grep -q -- "dump --single-transaction --routines --triggers --databases --add-drop-database -- alpha" "$CALLS_FILE"; then
    pass "Backup: database dump and composer files, private"
else
    fail "backup: $(ls -la "$backup" 2>&1)"
fi

if [[ "$(calls_line sudo-asked)" -lt "$(calls_line 'dump ')" &&
      "$(calls_line 'dump ')" -lt "$(calls_line 'drush state:set system.maintenance_mode 1')" &&
      "$(calls_line 'drush state:set system.maintenance_mode 1')" -lt "$(grep -n 'composer update' "$CALLS_FILE" | tail -n 1 | cut -d: -f1)" &&
      "$(grep -n 'composer update' "$CALLS_FILE" | tail -n 1 | cut -d: -f1)" -lt "$(calls_line 'drush updatedb --yes')" &&
      "$(calls_line 'drush updatedb --yes')" -lt "$(calls_line 'drush cache:rebuild')" &&
      "$(calls_line 'drush cache:rebuild')" -lt "$(calls_line 'drush state:set system.maintenance_mode 0')" ]] &&
   ! sed -n "$(grep -n 'composer update' "$CALLS_FILE" | tail -n 1 | cut -d: -f1),\$p" "$CALLS_FILE" | grep -q "^sudo "; then
    pass "Order: sudo, backup, maintenance, composer, updatedb, cache, maintenance off; no sudo after Composer"
else
    fail "order: $(cat "$CALLS_FILE")"
fi

# Test 7: Failures restore code and database.

make_project beta

if output="$(printf '1\nbeta\n' | UPDATE_FAILS=1 run_update_project beta)"; then
    fail "Failed Composer update reported as success"
elif [[ "$(version_of beta)" == "11.3.10" && "$output" == *"[OK] The project is back to its previous version."* ]] &&
     grep -qx "core=11.3.10" "$PROJECT_PATH/composer.lock" &&
     ! grep -q "mysql restore" "$CALLS_FILE" && grep -q "drush state:set system.maintenance_mode 0" "$CALLS_FILE"; then
    pass "Composer failure: code restored, database untouched, maintenance off"
else
    fail "composer failure: $output / $(cat "$CALLS_FILE")"
fi

: > "$CALLS_FILE"

if output="$(printf '1\nbeta\n' | UPDB_FAILS=1 run_update_project beta)"; then
    fail "Failed updatedb reported as success"
elif [[ "$(version_of beta)" == "11.3.10" && "$output" == *"[OK] Database restored"* ]] &&
     grep -q "mysql restore: CREATE TABLE node;" "$CALLS_FILE" &&
     [[ "$(read_project_field "$(record_of beta)" drupal_version)" == "11.3.10" ]]; then
    pass "updatedb failure: code and database restored, registry unchanged"
else
    fail "updb failure: $output / $(cat "$CALLS_FILE")"
fi

if output="$(printf '1\nbeta\n' | BOOTSTRAP_FAILS_AFTER=1 run_update_project beta)"; then
    fail "Broken updated site reported as success"
elif [[ "$(version_of beta)" == "11.3.10" && "$output" == *"Drush cannot bootstrap the updated site"* &&
        "$output" == *"[OK] Database restored"* ]]; then
    pass "Updated site that does not bootstrap: restored"
else
    fail "verify failure: $output"
fi

if output="$(printf '1\nbeta\n' | CURL_FAILS=1 run_update_project beta)"; then
    fail "Site without HTTP answer reported as success"
elif [[ "$(version_of beta)" == "11.3.10" && "$output" == *"does not answer as a Drupal site"* ]]; then
    pass "Updated site that does not answer over HTTP: restored"
else
    fail "http failure: $output"
fi

: > "$CALLS_FILE"

if output="$(printf '1\nbeta\n' | DUMP_FAILS=1 run_update_project beta)"; then
    fail "Failed backup accepted"
elif [[ "$output" == *"Backup failed. Nothing was changed."* ]] &&
     ! grep -q "composer update.*--with-all-dependencies$\|drush state:set" "$CALLS_FILE"; then
    pass "Failed backup stops before any change"
else
    fail "backup failure: $output / $(cat "$CALLS_FILE")"
fi

# Test 8: SQLite: the file is copied and copied back.

make_project gamma sqlite

if output="$(printf '1\ngamma\n' | UPDB_FAILS=1 run_update_project gamma)"; then
    fail "SQLite updatedb failure reported as success"
elif [[ "$output" == *"[OK] Database restored"* ]] &&
     [[ "$(cat "$SQLITE_DATABASE_PATH")" == "SQLite data" ]] &&
     backup="$(find "$work_dir/backups" -maxdepth 1 -name 'gamma-update-*' -type d | head -n 1)" &&
     cmp -s "$backup/database.sqlite" "$SQLITE_DATABASE_PATH" &&
     ! grep -q "^sudo " "$CALLS_FILE"; then
    pass "SQLite: file backed up and restored, no sudo needed"
else
    fail "sqlite: $output / $(cat "$CALLS_FILE")"
fi

# Test 9: PostgreSQL: the database is recreated with its owner, then
# the dump is loaded (tables added by the update do not survive).

make_project delta postgresql

if output="$(printf '1\ndelta\n' | UPDB_FAILS=1 run_update_project delta)"; then
    fail "PostgreSQL updatedb failure reported as success"
elif [[ "$output" == *"[OK] Database restored"* ]] &&
     grep -q "psql owner query .*-v db=delta" "$CALLS_FILE" &&
     grep -qx "pg_dump -- delta" "$CALLS_FILE" &&
     [[ "$(calls_line 'dropdb --if-exists --force -- delta')" -lt "$(calls_line 'createdb -O delta_user -- delta')" ]] &&
     [[ "$(calls_line 'createdb -O delta_user -- delta')" -lt "$(calls_line 'psql restore')" ]] &&
     grep -q "psql restore .*ON_ERROR_STOP=1 -d delta: CREATE TABLE node;" "$CALLS_FILE"; then
    pass "PostgreSQL: dump, then drop, recreate with owner and restore"
else
    fail "postgresql: $output / $(cat "$CALLS_FILE")"
fi

echo "[SUCCESS] Update tests passed."
