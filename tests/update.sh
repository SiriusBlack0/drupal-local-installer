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
source lib/composer.sh
source lib/update.sh

work_dir="$(mktemp -d)"
trap 'chmod -R u+w "$work_dir" 2>/dev/null; rm -rf "$work_dir"' EXIT

export XDG_DATA_HOME="$work_dir/data"
export XDG_STATE_HOME="$work_dir/state"
export COMPOSER_RETRY_DELAY=0
export work_dir_net="$work_dir/net-fail-count"
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
    validate)
        if [[ "${LOCK_OUTDATED:-0}" == "1" ]]; then
            echo "- The lock file is not up to date with the latest changes in composer.json, it is recommended that you run \`composer update\` or \`composer update <package name>\`."
            exit 1
        fi
        ;;
    show)
        echo "{\"name\":\"${args[-1]}\",\"versions\":${COMPOSER_VERSIONS:-[]}}"
        ;;
    audit)
        [[ "${AUDIT_FAILS:-0}" == "1" ]] && exit 1
        if [[ "${AUDIT_CORE:-0}" == "1" ]]; then
            echo '{"advisories":{"drupal/core":[{"title":"SA-CORE"}]}}'
            exit 1
        fi
        echo '{"advisories":[]}'
        ;;
    update)
        target=""
        for a in "${args[@]}"; do [[ "$a" == drupal/core*:* ]] && target="${a##*:}"; done
        # BLOCK_ADVISORIES=1: Composer 2.9+ refuses a package with advisories
        # unless --no-security-blocking is given.
        if [[ "${BLOCK_CORE_ADVISORIES:-0}" == "1" && " ${args[*]} " != *" --no-security-blocking "* ]]; then
            echo "    - Root composer.json requires drupal/core-recommended $target -> found drupal/core[$target] but these were not loaded, because they are affected by security advisories (\"SA-CORE-2026-012\", \"SA-CORE-2026-010\")."
            exit 2
        fi
        if [[ "${BLOCK_ADVISORIES:-0}" == "1" && " ${args[*]} " != *" --no-security-blocking "* ]]; then
            echo "Your requirements could not be resolved to an installable set of packages."
            echo "  Problem 1"
            echo "    - drupal/core-recommended $target requires guzzlehttp/guzzle ~7.9.3 -> found guzzlehttp/guzzle[7.9.3] but these were not loaded, because they are affected by security advisories (\"PKSA-gcrk-3vtt-1r14\", \"PKSA-cnw1-2ytm-cgr8\"). Go to https://packagist.org/security-advisories/ to find advisory details."
            exit 2
        fi
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
        # NET_FAIL_ONCE: the first real update fails like a dropped
        # connection (the file marks that it happened).
        # NET_FAILS=<n>: the first n real updates fail that way.
        if [[ -n "${NET_FAILS:-}" ]] && [[ "$(cat "$work_dir_net" 2>/dev/null || echo 0)" -lt "$NET_FAILS" ]]; then
            echo $(( $(cat "$work_dir_net" 2>/dev/null || echo 0) + 1 )) > "$work_dir_net"
            echo "curl error 28 while downloading https://packages.drupal.org/8/x: Operation timed out"
            exit 1
        fi
        if [[ -n "${NET_FAIL_ONCE:-}" && ! -e "$NET_FAIL_ONCE" ]]; then
            touch "$NET_FAIL_ONCE"
            echo "curl error 7 while downloading https://api.github.com/x: Failed to connect to api.github.com port 443"
            exit 1
        fi
        echo "core=$target" > "$dir/composer.lock"
        [[ "${UPDATE_FAILS:-0}" == "1" ]] && exit 1
        set_version "$target"
        # Like the real update: new code and changed scaffold files. The
        # core scaffold replaces web/sites/default/default.settings.php and
        # fails, as the real one does, when that folder is read-only.
        if [[ -d "$dir/web/modules/contrib" ]]; then
            mkdir -p "$dir/web/modules/contrib/new_module"
            echo "<?php // new" > "$dir/web/index.php"
            # A scaffold file that only the new release has.
            echo "<?php // runtime" > "$dir/web/autoload_runtime.php"
        fi
        if [[ -f "$dir/web/sites/default/default.settings.php" ]]; then
            if (( (8#$(stat -c %a "$dir/web/sites/default") & 8#200) == 0 )); then
                echo "In Filesystem.php line 305:"
                echo "  Could not delete $dir/web/sites/default/default.settings.php:"
                exit 1
            fi
            rm -f "$dir/web/sites/default/default.settings.php"
            echo "<?php // new defaults" > "$dir/web/sites/default/default.settings.php"
        fi
        # UPDATE_INTERRUPT: Ctrl+C arrives while Composer runs.
        if [[ "${UPDATE_INTERRUPT:-0}" == "1" ]]; then
            kill -INT "$PPID"
            exit 130
        fi
        ;;
    install)
        if [[ "${INSTALL_FAILS:-0}" == "1" ]]; then
            echo "curl error 6: Could not resolve host: repo.packagist.org"
            exit 1
        fi
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

if [[ "$(get_update_targets "$PROJECT_PATH" 8.5 11.3.10)" == "11.3.12|11.4.2|12.0.1" &&
      "$(get_update_targets "$PROJECT_PATH" 8.5 11.3.12)" == "|11.4.2|12.0.1" &&
      "$(get_update_targets "$PROJECT_PATH" 8.5 11.4.2)" == "||12.0.1" &&
      "$(get_update_targets "$PROJECT_PATH" 8.5 10.6.3)" == "||11.4.2" ]]; then
    pass "Update targets: patch, known minor; major only as the --upgrade target (known minors, stable)"
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

if [[ "$output" == *"alpha"*"11.3.10"*"11.3.12"*"11.4.2"*"12.0.1"*"VULNERABLE - update now"* &&
      "$output" == *"MAJOR: newest release of the next major this installer knows (--upgrade)."* &&
      "$output" == *"Next major available for: alpha"* &&
      "$output" == *"[ACTION] Installed versions with a security advisory"* &&
      "$output" == *"./install.sh --update alpha"* ]] &&
   ! grep -q "composer update" "$CALLS_FILE"; then
    pass "--check-updates shows patch, minor and a clear security state; changes nothing"
else
    fail "check-updates: $output"
fi

output="$(run_check_updates)"

if [[ "$output" == *"alpha"*"no known issues"* && "$output" != *"[ACTION]"* ]] &&
   output="$(AUDIT_FAILS=1 run_check_updates)" &&
   [[ "$output" == *"not checked (composer audit failed)"* && "$output" != *"[ACTION]"* ]]; then
    pass "--check-updates: no advisory and failed audit are shown as such"
else
    fail "check-updates states: $output"
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

if output="$(LOCK_OUTDATED=1 run_update_project alpha < /dev/null)"; then
    fail "Outdated composer.lock accepted"
elif [[ "$output" == *"[BLOCKED] composer.lock does not match composer.json: composer.json was changed"* &&
        "$output" == *"its backup could not be restored"* &&
        "$output" == *"./composer update --dry-run"* ]] && ! grep -q "sudo-asked" "$CALLS_FILE"; then
    pass "composer.lock out of date with composer.json: blocked before anything, with what to do"
else
    fail "outdated lock: $output"
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
   [[ "$output" == *"[DONE WITH PROBLEMS] alpha: Drupal 11.3.10 -> 11.4.2"* &&
      "$output" == *"  - new errors in the status report: Update notifications"* &&
      "$output" == *"Back to Drupal 11.3.10 later: ./install.sh --restore alpha $work_dir/backups/alpha-update-"* &&
      "$output" == *"[WARNING] New errors in the Drupal status report"* &&
      "$output" == *"- Update notifications"* && "$output" != *"- Cron"* &&
      "$output" == *"git add -A && git commit -m \"Drupal core 11.4.2\""* ]]; then
    pass "Minor update: code, database update, registry version, new status errors (DONE WITH PROBLEMS), commit shown (git)"
else
    fail "update: $output / $(cat "$CALLS_FILE")"
fi

backup="$(find "$work_dir/backups" -maxdepth 1 -name 'alpha-update-*' -type d | head -n 1)"

if [[ -n "$backup" && "$(stat -c '%a' "$backup")" == "700" &&
      "$(stat -c '%a' "$backup/database.sql.gz")" == "600" &&
      "$(stat -c '%a' "$backup/composer.json")" == "600" &&
      "$(stat -c '%a' "$backup/composer.lock")" == "600" ]] &&
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
chmod 664 "$PROJECT_PATH/composer.json" "$PROJECT_PATH/composer.lock"

if output="$(printf '1\nbeta\n' | UPDATE_FAILS=1 run_update_project beta)"; then
    fail "Failed Composer update reported as success"
elif [[ "$(version_of beta)" == "11.3.10" && "$output" == *"[OK] The project is back to its previous version."* ]] &&
     [[ "$(stat -c '%a' "$PROJECT_PATH/composer.json")" == "664" &&
        "$(stat -c '%a' "$PROJECT_PATH/composer.lock")" == "664" ]] &&
     grep -qx "core=11.3.10" "$PROJECT_PATH/composer.lock" &&
     ! grep -q "mysql restore" "$CALLS_FILE" && grep -q "drush state:set system.maintenance_mode 0" "$CALLS_FILE"; then
    pass "Composer failure: code restored (composer files keep their mode), database untouched, maintenance off"
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

# A restore that fails: the commands by hand, in the safe order (code
# first, with a writable web/sites/default and a fresh vendor/; the
# database only after the old version is back).

make_project chi

if output="$(printf '1\nchi\n' | UPDATE_FAILS=1 INSTALL_FAILS=1 run_update_project chi)"; then
    fail "Failed restore reported as success"
elif [[ "$output" == *"[ERROR] Automatic restore did not complete. Restore by hand from:"* &&
        "$output" == *"  cd $PROJECT_PATH && chmod u+w $PROJECT_PATH/web/sites/default"* &&
        "$output" == *"  rm -rf vendor && ./composer install && chmod 555 $PROJECT_PATH/web/sites/default"* &&
        "$output" == *"  The database only after Drupal reports 11.3.10 again:"* ]]; then
    pass "Failed restore: the commands by hand, code first, database only after the old version is back"
else
    fail "failed restore: $output"
fi

# Test 10: Offline restore: the code comes back from the copy made
# before Composer, even when "composer install" (network) would fail.

make_project omega
cat > "$PROJECT_PATH/composer.json" <<'JSON'
{
    "require": { "drupal/core-recommended": "^11.3" },
    "extra": {
        "installer-paths": {
            "web/core": ["type:drupal-core"],
            "web/modules/contrib/{$name}": ["type:drupal-module"]
        }
    }
}
JSON
mkdir -p "$PROJECT_PATH/vendor/composer" "$PROJECT_PATH/web/modules/contrib/old_module" "$PROJECT_PATH/web/sites/default"
echo "<?php // autoload" > "$PROJECT_PATH/vendor/autoload.php"
echo "<?php // old" > "$PROJECT_PATH/web/index.php"
echo "<?php // old defaults" > "$PROJECT_PATH/web/sites/default/default.settings.php"
# Read-only, as Drupal leaves it after the installation.
chmod 555 "$PROJECT_PATH/web/sites/default"
: > "$CALLS_FILE"

# A copy left behind by an older run, with a read-only folder in it.
mkdir -p "$PROJECT_PATH/.drupal-local-installer/update-snapshot/code/web/sites/default"
echo "stale" > "$PROJECT_PATH/.drupal-local-installer/update-snapshot/code/web/sites/default/default.services.yml"
chmod 555 "$PROJECT_PATH/.drupal-local-installer/update-snapshot/code/web/sites/default"

if output="$(printf '1\nomega\n' | UPDB_FAILS=1 INSTALL_FAILS=1 run_update_project omega)"; then
    fail "Failed update reported as success"
elif [[ "$output" == *"Copying the current code (for an offline restore) ... OK"* &&
        "$output" == *"[OK] Code restored (from the offline copy)"* &&
        "$output" == *"[OK] The project is back to its previous version."* ]] &&
     [[ "$(version_of omega)" == "11.3.10" && "$(cat "$PROJECT_PATH/web/index.php")" == "<?php // old" ]] &&
     [[ -d "$PROJECT_PATH/web/modules/contrib/old_module" && ! -e "$PROJECT_PATH/web/modules/contrib/new_module" ]] &&
     [[ ! -e "$PROJECT_PATH/web/autoload_runtime.php" ]] &&
     [[ -f "$PROJECT_PATH/vendor/autoload.php" && ! -e "$PROJECT_PATH/.drupal-local-installer/update-snapshot" ]] &&
     [[ "$(cat "$PROJECT_PATH/web/sites/default/default.settings.php")" == "<?php // old defaults" ]] &&
     [[ "$(stat -c '%a' "$PROJECT_PATH/web/sites/default")" == "555" ]] &&
     ! grep -q "composer install" "$CALLS_FILE"; then
    pass "Offline restore (stale read-only copy replaced): code, modules, scaffold files back offline (new ones removed); copy removed"
else
    fail "offline restore: $output / $(cat "$CALLS_FILE")"
fi

if output="$(printf '1\nomega\n' | run_update_project omega)" &&
   [[ "$(version_of omega)" == "11.3.12" && ! -e "$PROJECT_PATH/.drupal-local-installer/update-snapshot" ]] &&
   [[ "$output" == *"web/sites/default is writable during the update"* ]] &&
   [[ "$(cat "$PROJECT_PATH/web/sites/default/default.settings.php")" == "<?php // new defaults" ]] &&
   [[ "$(stat -c '%a' "$PROJECT_PATH/web/sites/default")" == "555" ]]; then
    pass "Read-only web/sites/default: writable for the scaffold, protected again; offline copy removed"
else
    fail "snapshot cleanup: $output"
fi

# Test 11: Ctrl+C while Composer runs: the project is restored, exit 130.

make_project kappa
run_status=0
output="$(printf '1\nkappa\n' | UPDATE_INTERRUPT=1 run_update_project kappa)" || run_status=$?

if [[ "$run_status" -eq 130 && "$output" == *"[INTERRUPTED] Stopping the update and restoring the project"* &&
      "$output" == *"[OK] The project is back to its previous version."* ]] &&
   [[ "$(version_of kappa)" == "11.3.10" ]] &&
   grep -q "drush state:set system.maintenance_mode 0" "$CALLS_FILE"; then
    pass "Ctrl+C during the update: restored, maintenance off, exit code 130"
else
    fail "interrupt: $run_status / $output"
fi

# The same with a log file, as in a real run: Composer's output goes to
# the log, but what the restore reports must reach the terminal.
make_project kappa
LOG_FILE="$work_dir/kappa.log"
: > "$LOG_FILE"
run_status=0
output="$(remember_console; printf '1\nkappa\n' | UPDATE_INTERRUPT=1 run_update_project kappa)" || run_status=$?
LOG_FILE=""

if [[ "$run_status" -eq 130 && "$output" == *"[INTERRUPTED] Stopping the update"* &&
      "$output" == *"[OK] The project is back to its previous version."* ]] &&
   ! grep -q "INTERRUPTED" "$work_dir/kappa.log"; then
    pass "Ctrl+C with a log file: the restore is reported on the terminal, not hidden in the log"
else
    fail "interrupt with log: $run_status / $output / $(tail -5 "$work_dir/kappa.log")"
fi

# Test 12: A network error during "composer update" is retried once.

make_project lambda
LOG_FILE="$work_dir/lambda.log"
: > "$LOG_FILE"

if output="$(printf '1\nlambda\n' | NET_FAIL_ONCE="$work_dir/net-failed" run_update_project lambda)" &&
   [[ "$output" == *"[RETRY] That was a network problem"* && "$output" == *"[DONE] lambda"* ]] &&
   [[ "$(version_of lambda)" == "11.3.12" ]]; then
    pass "Network error during composer update: retried once, then updated"
else
    fail "network retry: $output"
fi

make_project nu
LOG_FILE="$work_dir/nu.log"
: > "$LOG_FILE"
rm -f "$work_dir_net"

if output="$(printf '1\nnu\n' | NET_FAILS=2 run_update_project nu)" &&
   [[ "$output" == *"attempt 2 of 3"* && "$output" == *"attempt 3 of 3"* && "$output" == *"[DONE] nu"* ]]; then
    pass "Unstable network: up to 3 attempts, then updated"
else
    fail "3 attempts: $output"
fi

make_project xi
LOG_FILE="$work_dir/xi.log"
: > "$LOG_FILE"
rm -f "$work_dir_net"

if output="$(printf '1\nxi\n' | NET_FAILS=5 run_update_project xi)"; then
    fail "Update that never gets through reported as done"
elif [[ "$output" == *"attempt 3 of 3"* && "$output" != *"attempt 4"* &&
        "$output" == *"[OK] The project is back to its previous version."* ]]; then
    pass "Network down for good: 3 attempts, then restored"
else
    fail "network down: $output"
fi

LOG_FILE=""

# Test 13: Only one run at a time per project.

make_project mu
lock_file="$XDG_STATE_HOME/drupal-local-installer/locks/mu.lock"
mkdir -p "$(dirname "$lock_file")"
flock "$lock_file" sleep 5 &
lock_holder=$!
sleep 0.5

if output="$(run_update_project mu < /dev/null)"; then
    fail "Second run on a locked project accepted"
elif [[ "$output" == *"Another run of the installer is working on 'mu' right now"* ]]; then
    pass "A project another run is working on is refused"
else
    fail "lock: $output"
fi

kill "$lock_holder" 2>/dev/null || true
wait "$lock_holder" 2>/dev/null || true

# Test 14: A mistyped name suggests the registered one; an audit that
# cannot run is reported as such in the plan.

if output="$(run_update_project omegaa < /dev/null)"; then
    fail "Unknown name accepted"
elif [[ "$output" == *"Did you mean: omega ?"* ]]; then
    pass "Mistyped project name: the registered one is suggested"
else
    fail "suggestion: $output"
fi

make_project pi

if output="$(printf '1\n' | AUDIT_FAILS=1 REMOVE_DRY_RUN=1 run_update_project pi)" &&
   [[ "$output" == *"Security: could not be checked (composer audit failed; network?)"* ]]; then
    pass "Plan says when the security check could not run"
else
    fail "audit failed: $output"
fi

# Test 15: Composer blocks the target because of advisories: explained;
# the user may accept them for this update only.

make_project rho

if output="$(printf '1\n' | BLOCK_ADVISORIES=1 REMOVE_DRY_RUN=1 run_update_project rho)" &&
   [[ "$output" == *"[SECURITY] Drupal 11.3.12 needs package versions that have published"* &&
      "$output" == *"- guzzlehttp/guzzle 7.9.3: PKSA-gcrk-3vtt-1r14, PKSA-cnw1-2ytm-cgr8"* &&
      "$output" == *"Advisories:   accepted for this update"* && "$output" == *"[DRY RUN] Nothing was changed."* ]]; then
    pass "Advisories block the target: explained in plain words; dry run shows the plan"
else
    fail "advisories dry run: $output"
fi

if output="$(printf '1\n' | AUDIT_CORE=1 BLOCK_ADVISORIES=1 REMOVE_DRY_RUN=1 run_update_project rho)" &&
   [[ "$output" == *"has a published security advisory. 11.3.12 fixes"* &&
      "$output" == *"part of it, but still has advisories (see [SECURITY] above)."* &&
      "$output" != *"this update is needed"* ]]; then
    pass "Plan: an advisory now and advisories in the target too: said so, no contradiction"
else
    fail "advisories now and in the target: $output"
fi

if output="$(printf '1\n' | AUDIT_CORE=1 REMOVE_DRY_RUN=1 run_update_project rho)" &&
   [[ "$output" == *"has a published security advisory; this update is needed."* ]]; then
    pass "Plan: an advisory now and a clean target: this update is needed"
else
    fail "advisory now, clean target: $output"
fi

if output="$(printf '1\nno\n' | BLOCK_ADVISORIES=1 run_update_project rho)"; then
    fail "Advisories accepted without 'accept'"
elif [[ "$output" == *"Update cancelled; nothing was changed."* && "$(version_of rho)" == "11.3.10" ]] &&
     ! grep -q "sudo-asked" "$CALLS_FILE"; then
    pass "Advisories not accepted: nothing changed, no sudo"
else
    fail "advisories declined: $output"
fi

: > "$CALLS_FILE"

if output="$(printf '1\naccept\nrho\n' | BLOCK_ADVISORIES=1 run_update_project rho)" &&
   [[ "$output" == *"[DONE] rho: Drupal 11.3.10 -> 11.3.12"* && "$output" == *"[NOTE] Installed with accepted security advisories"* ]] &&
   grep -q "composer update .* --with-all-dependencies --no-security-blocking$" "$CALLS_FILE" &&
   [[ "$(read_project_field "$(record_of rho)" accepted_advisories)" == *"11.3.12: guzzlehttp/guzzle 7.9.3: PKSA-gcrk-3vtt-1r14"* ]]; then
    pass "Advisories accepted: update installed for this run only, noted in the registry"
else
    fail "advisories accepted: $output / $(cat "$CALLS_FILE")"
fi

if output="$(printf 'rho\n' | run_update_project rho)" &&
   [[ "$(version_of rho)" == "11.4.2" ]] &&
   ! grep -q "^accepted_advisories=" "$(record_of rho)" &&
   grep -q "^drupal_version=11.4.2$" "$(record_of rho)"; then
    pass "A later update without advisories removes the old note from the registry"
else
    fail "accepted advisories cleared: $output / $(cat "$(record_of rho)")"
fi

make_project sigma

if output="$(printf '1\n' | BLOCK_CORE_ADVISORIES=1 REMOVE_DRY_RUN=1 run_update_project sigma)" &&
   [[ "$output" == *"- drupal/core 11.3.12: SA-CORE-2026-012, SA-CORE-2026-010"* &&
      "$output" == *"Drupal core 11.3.12 itself has these advisories"* &&
      "$output" == *"Try the other choice first: Drupal 11.4.2."* ]]; then
    pass "Advisories on Drupal core itself: explained as an unsupported line"
else
    fail "core advisories: $output"
fi

echo "[SUCCESS] Update tests passed."
