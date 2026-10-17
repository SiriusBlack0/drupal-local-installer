#!/usr/bin/env bash

# ./install.sh --remove: registry based, checked, confirmed, with
# optional backup. Everything happens in a temporary directory; sudo,
# mysql, systemctl and drush are stubs.

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

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

export XDG_DATA_HOME="$work_dir/data"
export DRUPAL_PROJECTS_DIR="$work_dir/www"
etc_dir="$work_dir/etc"
stub_bin="$work_dir/bin"
export CALLS_FILE="$work_dir/calls"
mkdir -p "$DRUPAL_PROJECTS_DIR" "$etc_dir/sites-available" "$etc_dir/sites-enabled" "$etc_dir/pool.d" "$stub_bin"

pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; exit 1; }

# /etc paths and the backup directory point into the temporary directory.
get_nginx_config_path() { printf '%s/sites-available/%s.conf\n' "$etc_dir" "$1"; }
get_nginx_enabled_path() { printf '%s/sites-enabled/%s.conf\n' "$etc_dir" "$1"; }
get_php_fpm_pool_config_path() { printf '%s/pool.d/%s.conf\n' "$etc_dir" "$1"; }
get_backup_base_dir() { printf '%s/backups\n' "$work_dir"; }
has_systemd() { return 0; }
require_sudo() { echo "sudo-asked" >> "$CALLS_FILE"; }

cat > "$stub_bin/sudo" <<'STUB'
#!/usr/bin/env bash
echo "sudo $*" >> "$CALLS_FILE"
[[ "$1" == "-u" ]] && shift 2
exec "$@"
STUB

# Database dumps print one SQL line, or fail with DUMP_FAILS=1.
for dump in mysqldump pg_dump; do
    cat > "$stub_bin/$dump" <<'STUB'
#!/usr/bin/env bash
echo "dump $*" >> "$CALLS_FILE"
[[ "${DUMP_FAILS:-0}" == "1" ]] && exit 1
echo "CREATE TABLE node;"
STUB
done

# Configuration tests for adopted projects.
cat > "$stub_bin/nginx" <<'STUB'
#!/usr/bin/env bash
echo "nginx $*" >> "$CALLS_FILE"
STUB

cat > "$stub_bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >> "$CALLS_FILE"
STUB

cat > "$stub_bin/mysql" <<'STUB'
#!/usr/bin/env bash
echo "mysql:" >> "$CALLS_FILE"
cat >> "$CALLS_FILE"
exit "${MYSQL_EXIT:-0}"
STUB
chmod +x "$stub_bin"/*
PATH="$stub_bin:$PATH"

# Creates a complete fake project with its record.
make_project() {
    local name="$1"
    local engine="${2:-mariadb}"

    PROJECT_NAME="$name"
    PROJECT_MACHINE_NAME="$name"
    PROJECT_USER="$(id -un)"
    PROJECT_PATH="$DRUPAL_PROJECTS_DIR/$name"
    DRUPAL_VERSION="11.4.10"
    PHP_VERSION="8.5"
    DATABASE_ENGINE="$engine"
    DATABASE_NAME="$name"
    DATABASE_USER="${name}_user"
    SQLITE_DATABASE_PATH="$PROJECT_PATH/private/database.sqlite"
    LOG_FILE=""

    mkdir -p "$PROJECT_PATH/web/sites/default/files" "$PROJECT_PATH/vendor/big" "$PROJECT_PATH/private"
    echo "uploaded" > "$PROJECT_PATH/web/sites/default/files/photo.jpg"
    echo "dependency" > "$PROJECT_PATH/vendor/big/lib.php"
    echo "site" > "$etc_dir/sites-available/$name.conf"
    ln -sf "$etc_dir/sites-available/$name.conf" "$etc_dir/sites-enabled/$name.conf"
    echo "pool" > "$etc_dir/pool.d/$name.conf"
    write_project_record > /dev/null
    : > "$CALLS_FILE"
}

record_of() { printf '%s/drupal-local-installer/projects/%s.conf\n' "$XDG_DATA_HOME" "$1"; }

everything_gone() {
    [[ ! -e "$DRUPAL_PROJECTS_DIR/$1" && ! -e "$etc_dir/sites-available/$1.conf" &&
       ! -L "$etc_dir/sites-enabled/$1.conf" && ! -e "$etc_dir/pool.d/$1.conf" &&
       ! -e "$(record_of "$1")" ]]
}

everything_kept() {
    [[ -d "$DRUPAL_PROJECTS_DIR/$1" && -e "$etc_dir/sites-available/$1.conf" &&
       -L "$etc_dir/sites-enabled/$1.conf" && -e "$etc_dir/pool.d/$1.conf" &&
       -e "$(record_of "$1")" ]] && ! grep -q "DROP" "$CALLS_FILE"
}

# Test 1: A project that is not registered is never removed.

mkdir -p "$DRUPAL_PROJECTS_DIR/legacy"
echo "site" > /dev/null

if output="$(run_remove_project legacy < /dev/null)"; then
    fail "Unregistered project reported as removed"
elif [[ "$output" == *"[NOT REGISTERED] 'legacy' is not in the registry."* &&
        "$output" == *"project directory: $DRUPAL_PROJECTS_DIR/legacy"* &&
        "$output" == *"sudo rm -rf -- '$DRUPAL_PROJECTS_DIR/legacy'"* ]] &&
     [[ -d "$DRUPAL_PROJECTS_DIR/legacy" ]]; then
    pass "Unregistered project: shown with manual commands, nothing removed"
else
    fail "unregistered: $output"
fi

# Test 2: --dry-run only shows the plan.

make_project alpha

if output="$(REMOVE_DRY_RUN=1 run_remove_project alpha < /dev/null)" &&
   [[ "$output" == *"Remove project: alpha"* &&
      "$output" == *"database 'alpha' and user 'alpha_user'"* &&
      "$output" == *"Not touched: installed packages"* &&
      "$output" == *"lost for good"* &&
      "$output" == *"[DRY RUN] Nothing was changed."* ]] &&
   everything_kept alpha; then
    pass "--dry-run shows the plan and changes nothing"
else
    fail "dry run: $output"
fi

# Test 3: A wrong name, or no answer, cancels.

if output="$(printf 'n\nalphaa\n' | run_remove_project alpha)"; then
    fail "Wrong confirmation accepted"
elif [[ "$output" == *"Name does not match"* ]] && everything_kept alpha &&
     ! grep -q "sudo-asked" "$CALLS_FILE"; then
    pass "Wrong name cancels before sudo; nothing removed"
else
    fail "wrong name: $output"
fi

if printf 'n\n' | run_remove_project alpha > /dev/null || run_remove_project alpha < /dev/null > /dev/null; then
    fail "End of input accepted as confirmation"
elif everything_kept alpha; then
    pass "End of input cancels; nothing removed"
else
    fail "EOF removed something"
fi

# Test 4: Confirmed without backup: everything goes, newest first,
# the registry entry last.

if output="$(printf 'n\nalpha\n' | run_remove_project alpha)" &&
   [[ "$output" == *"[DONE] alpha was removed."* ]] && everything_gone alpha &&
   grep -qxF "DROP DATABASE IF EXISTS \`alpha\`;" "$CALLS_FILE" &&
   grep -qxF "DROP USER IF EXISTS 'alpha_user'@'localhost';" "$CALLS_FILE" &&
   [[ "$(grep -n 'sudo-asked' "$CALLS_FILE" | cut -d: -f1)" -lt "$(grep -n 'sites-enabled' "$CALLS_FILE" | head -1 | cut -d: -f1)" ]]; then
    pass "Confirmed removal: site, pool, database, folder, then registry"
else
    fail "removal: $output / $(cat "$CALLS_FILE")"
fi

if [[ "$(grep -n 'sites-enabled' "$CALLS_FILE" | head -1 | cut -d: -f1)" -lt "$(grep -n 'pool.d' "$CALLS_FILE" | head -1 | cut -d: -f1)" ]] &&
   [[ "$(grep -n 'pool.d' "$CALLS_FILE" | head -1 | cut -d: -f1)" -lt "$(grep -n 'DROP DATABASE' "$CALLS_FILE" | cut -d: -f1)" ]] &&
   [[ "$(grep -n 'DROP DATABASE' "$CALLS_FILE" | cut -d: -f1)" -lt "$(grep -n "rm -rf -- $DRUPAL_PROJECTS_DIR/alpha" "$CALLS_FILE" | cut -d: -f1)" ]]; then
    pass "Removal order: Nginx, PHP-FPM, database, folder"
else
    fail "order: $(cat "$CALLS_FILE")"
fi

# Test 5: Backup: database dump and files without vendor/, mode 600.

make_project beta

if output="$(printf 'y\nbeta\n' | run_remove_project beta)" && everything_gone beta; then
    backup="$(find "$work_dir/backups" -maxdepth 1 -name 'beta-*' -type d)"

    if [[ -n "$backup" ]] && zcat "$backup/database.sql.gz" | grep -q "CREATE TABLE node" &&
       tar -tzf "$backup/project.tar.gz" | grep -qx "beta/web/sites/default/files/photo.jpg" &&
       ! tar -tzf "$backup/project.tar.gz" | grep -q "^beta/vendor/" &&
       [[ "$(stat -c '%a' "$backup")" == "700" && "$(stat -c '%a' "$backup/project.tar.gz")" == "600" ]] &&
       [[ "$output" == *"[OK] Backup saved: $backup"* ]]; then
        pass "Backup: database dump and files (without vendor/), private"
    else
        fail "backup content: $output"
    fi
else
    fail "backup removal: $output"
fi

# Test 6: A failed backup removes nothing.

make_project gamma

if output="$(printf 'y\ngamma\n' | DUMP_FAILS=1 run_remove_project gamma)"; then
    fail "Removal continued after a failed backup"
elif [[ "$output" == *"Database backup failed. Nothing was removed."* ]] && everything_kept gamma; then
    pass "Failed backup: nothing removed"
else
    fail "failed backup: $output"
fi

# Test 7: SQLite: no dump (the file is in the archive), no database SQL.

make_project delta sqlite
echo "sqlite-data" > "$DRUPAL_PROJECTS_DIR/delta/private/database.sqlite"

if output="$(printf 'y\ndelta\n' | run_remove_project delta)" && everything_gone delta &&
   ! grep -q "^dump \|DROP" "$CALLS_FILE"; then
    backup="$(find "$work_dir/backups" -maxdepth 1 -name 'delta-*' -type d)"

    if tar -tzf "$backup/project.tar.gz" | grep -qx "delta/private/database.sqlite"; then
        pass "SQLite: database file kept in the archive, removed with the folder"
    else
        fail "SQLite archive"
    fi
else
    fail "SQLite removal: $output"
fi

# Test 8: A changed record never makes the installer delete other paths.

make_project epsilon
record="$(record_of epsilon)"

for bad in "project_path=/etc" "project_path=$DRUPAL_PROJECTS_DIR/other" \
           "php_fpm_pool=/etc/passwd" "nginx_available=/etc/nginx/nginx.conf" \
           "database_name=x;DROP" "database_engine=oracle"; do
    cp "$record" "$record.orig"
    key="${bad%%=*}"
    sed -i "s|^$key=.*|$bad|" "$record"

    if printf 'n\nepsilon\n' | run_remove_project epsilon > /dev/null; then
        fail "Changed record accepted: $bad"
    fi

    everything_kept epsilon || fail "Something removed with changed record: $bad"
    mv "$record.orig" "$record"
done

pass "Changed record refused (paths, database, engine); nothing removed"

# Test 9: A failed step keeps the registry entry so --remove can be retried.

: > "$CALLS_FILE"

if output="$(printf 'n\nepsilon\n' | MYSQL_EXIT=1 run_remove_project epsilon)"; then
    fail "Failed database removal reported as success"
elif [[ "$output" == *"[FAILED] Database 'epsilon'"* && "$output" == *"registry entry is kept"* ]] &&
     [[ -e "$(record_of epsilon)" && ! -e "$DRUPAL_PROJECTS_DIR/epsilon" ]]; then
    pass "Failed step reported; registry entry kept for a retry"
else
    fail "failed step: $output"
fi

if output="$(printf 'n\nepsilon\n' | run_remove_project epsilon)" && everything_gone epsilon &&
   [[ "$output" == *"[OK] Project folder removed"* ]]; then
    pass "Retry removes the rest, including parts already gone"
else
    fail "retry: $output"
fi

# Test 10: Unsafe names are turned into safe machine names.

if output="$(run_remove_project "../../etc" < /dev/null)"; then
    fail "Unsafe name accepted"
elif [[ "$output" == *"'______etc' is not in the registry"* ]]; then
    pass "Unsafe name becomes a safe machine name"
else
    fail "unsafe name: $output"
fi

echo "[SUCCESS] Project removal tests passed."
