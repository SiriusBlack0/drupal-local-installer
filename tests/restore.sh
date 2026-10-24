#!/usr/bin/env bash

# ./install.sh --restore NAME [BACKUP]. Everything happens in a temporary
# directory: composer, drush, php8.3, sudo, mysqldump, mysql and curl are
# stubs that record their calls.

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
source lib/restore.sh

work_dir="$(mktemp -d)"
trap 'chmod -R u+w "$work_dir" 2>/dev/null; rm -rf "$work_dir"' EXIT

export XDG_DATA_HOME="$work_dir/data"
export XDG_STATE_HOME="$work_dir/state"
export COMPOSER_RETRY_DELAY=0
export DRUPAL_PROJECTS_DIR="$work_dir/www"
export STATE_DIR="$work_dir/stub-state"
etc_dir="$work_dir/etc"
stub_bin="$work_dir/bin"
export CALLS_FILE="$work_dir/calls"
export REAL_PHP
REAL_PHP="$(command -v php)"
mkdir -p "$DRUPAL_PROJECTS_DIR" "$etc_dir/sites-available" "$etc_dir/sites-enabled" "$etc_dir/pool.d" "$stub_bin" "$STATE_DIR"

pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; exit 1; }

get_nginx_config_path() { printf '%s/sites-available/%s.conf\n' "$etc_dir" "$1"; }
get_nginx_enabled_path() { printf '%s/sites-enabled/%s.conf\n' "$etc_dir" "$1"; }
get_php_fpm_pool_config_path() { printf '%s/pool.d/%s.conf\n' "$etc_dir" "$1"; }
get_backup_base_dir() { printf '%s/backups\n' "$work_dir"; }
require_sudo() { echo "sudo-asked" >> "$CALLS_FILE"; }

cat > "$stub_bin/php8.3" <<'STUB'
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

# The dump is the "current" database: whatever the last restore loaded.
cat > "$stub_bin/mysqldump" <<'STUB'
#!/usr/bin/env bash
echo "dump $*" >> "$CALLS_FILE"
cat "$STATE_DIR/database" 2>/dev/null || echo "NEW DB"
STUB

# MYSQL_FAIL_ONCE: the first restore fails.
cat > "$stub_bin/mysql" <<'STUB'
#!/usr/bin/env bash
input="$(cat)"
if [[ "${MYSQL_FAIL_ONCE:-0}" == "1" && ! -e "$STATE_DIR/mysql-failed" ]]; then
    touch "$STATE_DIR/mysql-failed"
    echo "mysql restore failed: $input" >> "$CALLS_FILE"
    exit 1
fi
echo "mysql restore: $input" >> "$CALLS_FILE"
printf '%s\n' "$input" > "$STATE_DIR/database"
STUB

cat > "$stub_bin/curl" <<'STUB'
#!/usr/bin/env bash
printf 'HTTP/1.1 200 OK\r\nX-Generator: Drupal 10 (https://www.drupal.org)\r\n'
STUB

# Composer install: the version of drupal/core in composer.lock goes into
# core/lib/Drupal.php. A Composer plugin of Drupal 11 left in vendor/
# stops the install of an older lock, as the real one does.
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
case "${args[0]}" in
    validate)
        # LOCK_OUTDATED_IN: composer.lock of that folder is out of date.
        if [[ -n "${LOCK_OUTDATED_IN:-}" && "$dir" == "$LOCK_OUTDATED_IN" ]]; then
            echo "./composer.json is valid but your composer.lock has some errors"
            echo "# Lock file errors"
            echo "- The lock file is not up to date with the latest changes in composer.json, it is recommended that you run \`composer update\` or \`composer update <package name>\`."
            exit 1
        fi
        ;;
    install)
        # The check before the restore: a dry run on a copy.
        if [[ " ${args[*]} " == *" --dry-run "* ]]; then
            case "${INSTALL_DRYRUN:-ok}" in
                php)
                    echo "Your lock file does not contain a compatible set of packages."
                    echo "  Problem 1"
                    echo "    - drupal/core is locked to version 10.5.12 and requires php >=8.4.0 -> your php version (8.3.20) does not satisfy that requirement."
                    exit 2
                    ;;
                plugin)
                    echo "symfony/runtime contains a Composer plugin which is blocked by your allow-plugins config."
                    exit 1
                    ;;
                network)
                    echo "curl error 6 while downloading https://repo.packagist.org/packages.json: Could not resolve host"
                    exit 1
                    ;;
            esac
            echo "Package operations: 188 installs, 0 updates, 0 removals"
            exit 0
        fi
        version="$(grep -oP '"name": *"drupal/core", *"version": *"\K[^"]+' "$dir/composer.lock")"
        if [[ -e "$dir/vendor/symfony-runtime" && "$version" == 10.* ]]; then
            echo "symfony/runtime contains a Composer plugin which is blocked by your allow-plugins config."
            exit 1
        fi
        [[ "${INSTALL_FAILS:-0}" == "1" ]] && { echo "curl error 6: Could not resolve host"; exit 1; }
        [[ "${INSTALL_WRONG_VERSION:-0}" == "1" ]] && version="9.9.9"
        mkdir -p "$dir/vendor" "$dir/web/core/lib"
        echo "<?php // autoload $version" > "$dir/vendor/autoload.php"
        printf "<?php\nclass Drupal {\n  const VERSION = '%s';\n}\n" "$version" > "$dir/web/core/lib/Drupal.php"
        if [[ "$version" == 11.* ]]; then
            touch "$dir/vendor/symfony-runtime"
            echo "<?php // runtime" > "$dir/web/autoload_runtime.php"
        fi
        ;;
esac
exit 0
STUB

chmod +x "$stub_bin"/*
PATH="$stub_bin:$PATH"

write_drush_stub() {
    cat > "$1/drush" <<'STUB'
#!/usr/bin/env bash
echo "drush $*" >> "$CALLS_FILE"
case "$1" in
    status) echo "Successful" ;;
    core:requirements) echo '[]' ;;
    cache:rebuild) [[ "${CACHE_FAILS:-0}" == "1" ]] && exit 1 ;;
    php:eval)
        # The configuration export folder, when CONFIG_SYNC is set.
        [[ -n "${CONFIG_SYNC:-}" ]] && printf '%s' "$CONFIG_SYNC"
        ;;
    config:status)
        if [[ "${CONFIG_DIFFERS:-0}" == "1" ]]; then
            echo '{"system.site":{"name":"system.site","state":"Different"},"views.view.x":{"name":"views.view.x","state":"Only in sync dir"}}'
        else
            echo '[]'
        fi
        ;;
esac
exit 0
STUB
    chmod +x "$1/drush"
}

lock_for() {
    printf '{\n    "packages": [\n        {"name": "drupal/core", "version": "%s"}\n    ]\n}\n' "$1"
}

record_of() { printf '%s/drupal-local-installer/projects/%s.conf\n' "$XDG_DATA_HOME" "$1"; }
version_of() { get_drupal_version_in "$DRUPAL_PROJECTS_DIR/$1/web"; }
calls_line() { grep -n -m1 -F -- "$1" "$CALLS_FILE" | cut -d: -f1; }
calls_exact() { grep -n -m1 -x -F -- "$1" "$CALLS_FILE" | cut -d: -f1; }

# A project on Drupal 11.4.11 after an upgrade, as Composer leaves it.
make_project() {
    local name="$1"

    PROJECT_NAME="$name"
    PROJECT_MACHINE_NAME="$name"
    PROJECT_USER="$(id -un)"
    PROJECT_PATH="$DRUPAL_PROJECTS_DIR/$name"
    DRUPAL_VERSION="11.4.11"
    PHP_VERSION="8.3"
    DATABASE_ENGINE="mariadb"
    DATABASE_NAME="$name"
    DATABASE_USER="${name}_user"
    SQLITE_DATABASE_PATH="$PROJECT_PATH/private/database.sqlite"
    LOG_FILE=""

    [[ -d "$PROJECT_PATH" ]] && chmod -R u+w "$PROJECT_PATH"
    rm -rf "$PROJECT_PATH" "$(record_of "$name")" "${STATE_DIR:?}"/*
    mkdir -p "$PROJECT_PATH/web/core/lib" "$PROJECT_PATH/web/sites/default" "$PROJECT_PATH/vendor"
    printf '{"name": "new", "extra": {"installer-paths": {"web/core": ["type:drupal-core"]}}}\n' > "$PROJECT_PATH/composer.json"
    lock_for 11.4.11 > "$PROJECT_PATH/composer.lock"
    printf "<?php\nclass Drupal {\n  const VERSION = '11.4.11';\n}\n" > "$PROJECT_PATH/web/core/lib/Drupal.php"
    echo "<?php // index" > "$PROJECT_PATH/web/index.php"
    echo "<?php // runtime" > "$PROJECT_PATH/web/autoload_runtime.php"
    echo "<?php // defaults" > "$PROJECT_PATH/web/sites/default/default.settings.php"
    chmod 555 "$PROJECT_PATH/web/sites/default"
    touch "$PROJECT_PATH/vendor/symfony-runtime"
    write_drush_stub "$PROJECT_PATH"
    echo "NEW DB" > "$STATE_DIR/database"
    write_project_record > /dev/null
    set_project_field "$(record_of "$name")" upgraded_from "2026-10-23 10.6.20"
    set_project_field "$(record_of "$name")" accepted_advisories "2026-10-23 11.4.11: x"
    : > "$CALLS_FILE"
}

# A backup made before the upgrade: Drupal 10.6.20 and its database.
make_backup() {
    local name="$1"
    local stamp="$2"
    local kind="${3:-upgrade}"
    local dir="$work_dir/backups/$name-$kind-$stamp"

    mkdir -p "$dir"
    chmod 700 "$dir"
    printf '{"name": "old", "extra": {"installer-paths": {"web/core": ["type:drupal-core"]}}}\n' > "$dir/composer.json"
    lock_for "${4:-10.6.20}" > "$dir/composer.lock"
    echo "OLD DB" | gzip > "$dir/database.sql.gz"
    printf '%s\n' web/index.php web/sites/default/default.settings.php > "$dir/scaffold-files.list"
    printf '%s\n' "$dir"
}

# Test 1: The backups of a project, newest first; others are left out.

make_project gamma
older="$(make_backup gamma 20261020-090000 update 10.6.19)"
newer="$(make_backup gamma 20261023-221500)"
make_backup delta 20261024-080000 > /dev/null
mkdir -p "$work_dir/backups/gamma-php-20261024-090000" "$work_dir/backups/gamma-update-20261024-100000"
touch "$work_dir/backups/gamma-php-20261024-090000/composer.lock" "$work_dir/backups/gamma-update-20261024-100000/composer.json"
RECORD_PHP_VERSION="8.3"

echo "rolled-back 2026-10-20 09:01" > "$older/result"

if [[ "$(list_restorable_backups gamma)" == "$newer"$'\n'"$older" &&
      "$(describe_backup "$older")" == "update, 2026-10-20, Drupal 10.6.19; that run failed and was restored automatically" &&
      "$(describe_backup "$newer")" == "upgrade, 2026-10-23, Drupal 10.6.20" &&
      "$(get_backup_time "$newer")" == "2026-10-23 22:15" ]]; then
    pass "Backups of the project, newest first (incomplete ones and --php backups left out)"
else
    fail "backup list: $(list_restorable_backups gamma)"
fi

# Test 2: The plan (--dry-run) changes nothing.

if output="$(printf '1\n' | REMOVE_DRY_RUN=1 run_restore_project gamma)" &&
   [[ "$output" == *"1) gamma-upgrade-20261023-221500 (upgrade, 2026-10-23, Drupal 10.6.20)"* &&
      "$output" == *"2) gamma-update-20261020-090000 (update, 2026-10-20, Drupal 10.6.19; that run failed and was restored automatically)"* &&
      "$output" == *"Drupal core:  11.4.11 -> 10.6.20"* &&
      "$output" == *"changed since 2026-10-23 22:15 are lost."* &&
      "$output" == *"The database is replaced only after the code is back."* &&
      "$output" == *"[DRY RUN] Nothing was changed."* ]] &&
   [[ "$(version_of gamma)" == "11.4.11" ]] && grep -q '"new"' "$PROJECT_PATH/composer.json" &&
   ! grep -q "sudo-asked\|composer install$" "$CALLS_FILE"; then
    pass "Dry run: list, versions, what is lost, the order; nothing changed"
else
    fail "dry run: $output"
fi

# Test 3: Wrong backup, no backup, wrong name: nothing changes.

if output="$(RESTORE_BACKUP_ARGUMENT="$work_dir/backups/delta-upgrade-20261024-080000" run_restore_project gamma < /dev/null)"; then
    fail "Backup of another project accepted"
elif [[ "$output" == *"[ERROR] Not a backup of 'gamma' that can be restored"* ]]; then
    pass "A backup of another project is refused"
else
    fail "other backup: $output"
fi

make_project epsilon

if output="$(run_restore_project epsilon < /dev/null)"; then
    fail "Restore without a backup accepted"
elif [[ "$output" == *"[ERROR] No backup of 'epsilon' to restore"* ]]; then
    pass "No backup: said so"
else
    fail "no backup: $output"
fi

make_project gamma

if output="$(printf '1\ngama\n' | run_restore_project gamma)"; then
    fail "Wrong name accepted"
elif [[ "$output" == *"Name does not match. Restore cancelled; nothing was changed."* ]] &&
     [[ "$(version_of gamma)" == "11.4.11" ]] && ! grep -q "sudo-asked" "$CALLS_FILE"; then
    pass "Wrong confirmation: nothing changed, no sudo"
else
    fail "wrong name: $output"
fi

# Test 4: The restore: current state backed up, code first (fresh vendor/,
# writable web/sites/default), version check, then the database.

if output="$(printf '1\ngamma\ny\n' | run_restore_project gamma)" &&
   [[ "$(version_of gamma)" == "10.6.20" ]] && grep -q '"old"' "$PROJECT_PATH/composer.json" &&
   [[ ! -e "$PROJECT_PATH/vendor/symfony-runtime" && ! -e "$PROJECT_PATH/web/autoload_runtime.php" ]] &&
   [[ "$(stat -c '%a' "$PROJECT_PATH/web/sites/default")" == "555" ]] &&
   [[ "$(cat "$STATE_DIR/database")" == "OLD DB" ]] &&
   [[ "$output" == *"[OK] Code of the backup installed: Drupal 10.6.20"* &&
      "$output" == *"These files were written by the newer release and are not in the backup:"* &&
      "$output" == *"  web/autoload_runtime.php"* &&
      "$output" == *"[OK] Removed web/autoload_runtime.php"* &&
      "$output" == *"[OK] Database of the backup restored"* &&
      "$output" == *"[DONE] gamma: Drupal 11.4.11 -> 10.6.20 (backup of 2026-10-23 22:15)"* ]]; then
    pass "Restore: code of the backup (old plugin removed with vendor/), newer scaffold file removed, database"
else
    fail "restore: $output / $(cat "$CALLS_FILE")"
fi

if [[ "$(calls_line sudo-asked)" -lt "$(calls_line 'dump ')" &&
      "$(calls_line 'dump ')" -lt "$(calls_exact 'composer install')" &&
      "$(calls_exact 'composer install')" -lt "$(calls_line 'mysql restore: OLD DB')" &&
      "$(calls_line 'mysql restore: OLD DB')" -lt "$(calls_line 'drush cache:rebuild')" ]]; then
    pass "Order: sudo, backup of the current state, code, then the database, then caches"
else
    fail "order: $(cat "$CALLS_FILE")"
fi

record="$(record_of gamma)"
safety="$(find "$work_dir/backups" -maxdepth 1 -name 'gamma-restore-*' -type d | head -n 1)"

if [[ "$(read_project_field "$record" drupal_version)" == "10.6.20" ]] &&
   ! grep -q "^upgraded_from=\|^accepted_advisories=" "$record" &&
   [[ "$(read_project_field "$record" restored_from)" == *"gamma-upgrade-20261023-221500" ]] &&
   [[ -n "$safety" ]] && grep -q '"11.4.11"' "$safety/composer.lock" &&
   [[ "$(zcat "$safety/database.sql.gz")" == "NEW DB" ]] &&
   [[ "$output" == *"(undo: ./install.sh --restore gamma $safety)"* ]]; then
    pass "Registry: the backup's version, upgrade notes gone; the state of before kept as a backup"
else
    fail "registry/safety: $(cat "$record") / $safety"
fi

# Test 5: Undo: the backup of the state before the restore, given by path.

: > "$CALLS_FILE"

if output="$(printf 'gamma\n' | RESTORE_BACKUP_ARGUMENT="$safety" run_restore_project gamma)" &&
   [[ "$(version_of gamma)" == "11.4.11" && "$(cat "$STATE_DIR/database")" == "NEW DB" ]] &&
   grep -q '"new"' "$PROJECT_PATH/composer.json" &&
   [[ "$output" == *"[DONE] gamma: Drupal 10.6.20 -> 11.4.11"* ]] &&
   [[ "$(read_project_field "$record" upgraded_from)" == "2026-10-23 10.6.20" &&
      "$(read_project_field "$record" accepted_advisories)" == "2026-10-23 11.4.11: x" &&
      "$(read_project_field "$record" drupal_version)" == "11.4.11" ]] &&
   ! grep -q "^restored_from=" "$record"; then
    pass "Undo with the backup made by the restore: 11.4.11, its database and its registry exactly as before"
else
    fail "undo: $output"
fi

# Test 6: Failures before the database: the database is never touched,
# the code of before comes back (offline copy).

make_project gamma
: > "$CALLS_FILE"

if output="$(printf 'gamma\n' | INSTALL_FAILS=1 RESTORE_BACKUP_ARGUMENT="$newer" run_restore_project gamma)"; then
    fail "Failed composer install reported as success"
elif [[ "$output" == *"[ERROR] The code of the backup could not be installed; the database was not touched."* &&
        "$output" == *"[OK] Code restored (from the offline copy)"* &&
        "$output" == *"[OK] The project is back to its previous version."* ]] &&
     [[ "$(version_of gamma)" == "11.4.11" && "$(cat "$STATE_DIR/database")" == "NEW DB" ]] &&
     grep -q '"new"' "$PROJECT_PATH/composer.json" && [[ -e "$PROJECT_PATH/web/autoload_runtime.php" ]] &&
     ! grep -q "mysql restore" "$CALLS_FILE" &&
     [[ "$(read_project_field "$(record_of gamma)" drupal_version)" == "11.4.11" ]]; then
    pass "Code cannot be installed: database untouched, the state of before back, registry unchanged"
else
    fail "install failure: $output / $(cat "$CALLS_FILE")"
fi

make_project gamma

if output="$(printf 'gamma\n' | INSTALL_WRONG_VERSION=1 RESTORE_BACKUP_ARGUMENT="$newer" run_restore_project gamma)"; then
    fail "Wrong version reported as success"
elif [[ "$output" == *"[ERROR] Drupal reports '9.9.9' instead of 10.6.20; the database was not touched."* ]] &&
     [[ "$(version_of gamma)" == "11.4.11" ]] && ! grep -q "mysql restore" "$CALLS_FILE"; then
    pass "Drupal reports another version: database untouched, the state of before back"
else
    fail "wrong version: $output"
fi

# Test 7: The database cannot be restored: code and database of before
# come back.

make_project gamma

if output="$(printf 'gamma\nn\n' | MYSQL_FAIL_ONCE=1 RESTORE_BACKUP_ARGUMENT="$newer" run_restore_project gamma)"; then
    fail "Failed database restore reported as success"
elif [[ "$output" == *"[ERROR] The database of the backup could not be restored."* &&
        "$output" == *"[OK] Database restored"* &&
        "$output" == *"[OK] The project is back to its previous version."* ]] &&
     [[ "$(version_of gamma)" == "11.4.11" && "$(cat "$STATE_DIR/database")" == "NEW DB" ]] &&
     grep -q "mysql restore: NEW DB" "$CALLS_FILE"; then
    pass "Database restore fails: code and database of before back"
else
    fail "database failure: $output / $(cat "$CALLS_FILE")"
fi

# Test 7b: Before anything changes (also in the dry run) the backup is
# test-installed on a copy; one that cannot be installed is refused.

make_project gamma

if output="$(INSTALL_DRYRUN=php REMOVE_DRY_RUN=1 RESTORE_BACKUP_ARGUMENT="$newer" run_restore_project gamma < /dev/null)"; then
    fail "Backup that needs another PHP accepted"
elif [[ "$output" == *"[BLOCKED] The backup's packages cannot be installed (composer install --dry-run):"* &&
        "$output" == *"requires php >=8.4.0"* &&
        "$output" == *"./install.sh --php gamma X.Y"* ]] &&
     ! grep -q "composer install$" "$CALLS_FILE"; then
    pass "Backup that needs another PHP: refused in the dry run, Composer's reason and the way out"
else
    fail "php: $output"
fi

if output="$(printf 'gamma\n' | INSTALL_DRYRUN=plugin RESTORE_BACKUP_ARGUMENT="$newer" run_restore_project gamma)"; then
    fail "Backup that cannot be installed accepted"
elif [[ "$output" == *"[BLOCKED] The backup's packages cannot be installed"* &&
        "$output" == *"blocked by your allow-plugins config"* ]] &&
     [[ "$(version_of gamma)" == "11.4.11" ]] && ! grep -q "sudo-asked" "$CALLS_FILE"; then
    pass "Backup that cannot be installed: refused before sudo, nothing changed"
else
    fail "not installable: $output"
fi

# composer.lock that does not match composer.json: composer install still
# installs exactly the lock, so the backup is restored (with a note).
if output="$(printf 'gamma\nn\n' | LOCK_OUTDATED_IN="$newer" RESTORE_BACKUP_ARGUMENT="$newer" run_restore_project gamma)" &&
   [[ "$output" == *"Check:        the backup's packages can be installed (composer install --dry-run)."* &&
      "$output" == *"[NOTE] In this backup composer.json has changes that were not in composer.lock"* &&
      "$output" == *"[DONE] gamma: Drupal 11.4.11 -> 10.6.20"* ]] &&
   [[ "$(version_of gamma)" == "10.6.20" ]]; then
    pass "Backup with an older lock hash: noted, and restored (composer install uses the lock)"
else
    fail "outdated lock in backup: $output"
fi

make_project gamma

if output="$(INSTALL_DRYRUN=network REMOVE_DRY_RUN=1 RESTORE_BACKUP_ARGUMENT="$newer" run_restore_project gamma < /dev/null)" &&
   [[ "$output" == *"could not test the install of the backup (network?)"* &&
      "$output" == *"[DRY RUN] Nothing was changed."* ]]; then
    pass "Install test not possible (network): said so, not refused"
else
    fail "network: $output"
fi

# Test 7c: The configuration export folder is compared with the restored
# database; differences are explained, with what not to do.

make_project gamma
mkdir -p "$PROJECT_PATH/config/sync"
echo "name: New" > "$PROJECT_PATH/config/sync/system.site.yml"
git -C "$PROJECT_PATH" init -q
git -C "$PROJECT_PATH" add -A
git -C "$PROJECT_PATH" -c user.email=t@t -c user.name=t commit -q -m "Drupal 11"

if output="$(printf 'gamma\nn\n' | CONFIG_SYNC="$PROJECT_PATH/config/sync" CONFIG_DIFFERS=1 RESTORE_BACKUP_ARGUMENT="$newer" run_restore_project gamma)" &&
   [[ "$output" == *"Config:       config/ is not changed by the restore"* &&
      "$output" == *"[WARNING] The configuration export (config/sync) differs from the restored"* &&
      "$output" == *"database in 2 item(s)"* &&
      "$output" == *"Do NOT run \"drush config:import\" now"* &&
      "$output" == *"./drush config:export, review, commit"* &&
      "$output" == *"Decide about the configuration export first (see the WARNING above: export or"* &&
      "$output" != *"Review it, then commit once the site works"* ]] &&
   [[ "$(cat "$PROJECT_PATH/config/sync/system.site.yml")" == "name: New" ]]; then
    pass "Configuration export differs from the restored database: warned, folder untouched"
else
    fail "config differs: $output"
fi

make_project gamma
mkdir -p "$PROJECT_PATH/config/sync"
echo "name: Old" > "$PROJECT_PATH/config/sync/system.site.yml"

if output="$(printf 'gamma\nn\n' | CONFIG_SYNC="$PROJECT_PATH/config/sync" RESTORE_BACKUP_ARGUMENT="$newer" run_restore_project gamma)" &&
   [[ "$output" == *"[OK] The configuration export (config/sync) matches the restored database"* ]]; then
    pass "Configuration export matches: OK"
else
    fail "config same: $output"
fi

# Test 8: Newer scaffold files are kept when the developer says no.

make_project gamma

if output="$(printf 'gamma\nn\n' | RESTORE_BACKUP_ARGUMENT="$newer" run_restore_project gamma)" &&
   [[ "$(version_of gamma)" == "10.6.20" && -e "$PROJECT_PATH/web/autoload_runtime.php" ]] &&
   [[ "$output" == *"[INFO] Kept. Remove them by hand when you are sure they are not yours."* ]]; then
    pass "Newer scaffold files: listed; kept when the developer says no"
else
    fail "keep files: $output"
fi

echo "[SUCCESS] Restore tests passed."
