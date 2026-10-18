#!/usr/bin/env bash

# --scan: finding existing projects, registering them as "adopted", and
# removing them without touching shared resources. Everything happens
# in a temporary directory; sudo, mysql, nginx, systemctl are stubs.

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
export XDG_STATE_HOME="$work_dir/state"
export DRUPAL_PROJECTS_DIR="$work_dir/www"
export NGINX_SITES_ENABLED_DIR="$work_dir/nginx/sites-enabled"
export NGINX_SITES_AVAILABLE_DIR="$work_dir/nginx/sites-available"
export PHP_ETC_DIR="$work_dir/php"
export CALLS_FILE="$work_dir/calls"
stub_bin="$work_dir/bin"
www="$DRUPAL_PROJECTS_DIR"
mkdir -p "$www" "$NGINX_SITES_ENABLED_DIR" "$NGINX_SITES_AVAILABLE_DIR" "$stub_bin" \
    "$PHP_ETC_DIR/8.3/fpm/pool.d" "$PHP_ETC_DIR/7.4/fpm/pool.d"
touch "$CALLS_FILE"

pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; exit 1; }

PROJECT_USER="$(id -un)"
has_systemd() { return 0; }
require_sudo() { :; }
get_backup_base_dir() { printf '%s/backups\n' "$work_dir"; }
is_database_engine_installed() { [[ "$1" == "mariadb" ]]; }

cat > "$stub_bin/sudo" <<'STUB'
#!/usr/bin/env bash
echo "sudo $*" >> "$CALLS_FILE"
[[ "$1" == "-u" ]] && shift 2
exec "$@"
STUB

cat > "$stub_bin/mysql" <<'STUB'
#!/usr/bin/env bash
cat >> "$CALLS_FILE"
STUB

for tool in nginx systemctl php-fpm7.4; do
    {
        echo '#!/usr/bin/env bash'
        # Literal: the stub expands $* and $CALLS_FILE when it runs.
        # shellcheck disable=SC2016
        printf 'echo "%s $*" >> "$CALLS_FILE"\n' "$tool"
    } > "$stub_bin/$tool"
done

# PHP 8.3 for the projects is the PHP of this machine (it only parses
# the JSON that the Drush stub prints).
have_php=0

# A small wrapper, not a symlink: chmod on a symlink would change the
# real (root-owned) php binary.
if command -v php > /dev/null; then
    printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$(command -v php)" > "$stub_bin/php8.3"
    have_php=1
fi

chmod +x "$stub_bin"/*
PATH="$stub_bin:$PATH"

# A Drupal 8+ project with web/ and a Drush that reports its database.
make_modern_project() {
    local dir="$www/$1"
    local version="$2"
    local db_json="$3"

    mkdir -p "$dir/web/core/lib" "$dir/vendor/bin"
    printf "<?php\nclass Drupal {\n  const VERSION = '%s';\n}\n" "$version" > "$dir/web/core/lib/Drupal.php"
    printf '#!/usr/bin/env bash\necho %q\n' "$db_json" > "$dir/vendor/bin/drush"
    chmod +x "$dir/vendor/bin/drush"
}

# An Nginx site (sites-available file + sites-enabled link).
make_site() {
    local file="$1"
    local root="$2"
    local server="$3"
    local socket="$4"

    printf 'server {\n    listen 80;\n    server_name %s;\n    root %s;\n    location ~ \\.php$ {\n        fastcgi_pass unix:%s;\n    }\n}\n' \
        "$server" "$root" "$socket" > "$NGINX_SITES_AVAILABLE_DIR/$file"
    ln -s "$NGINX_SITES_AVAILABLE_DIR/$file" "$NGINX_SITES_ENABLED_DIR/$file"
}

# Projects as found on a real work machine:
# ElBarberTon: Drupal 10.2 (end of life), capital letters, shared PHP 8.3 pool.
make_modern_project ElBarberTon 10.2.5 '{"db-driver":"mysql","db-name":"elbarber","db-username":"root"}'
make_site ElBarberTon "$www/ElBarberTon/web" ElBarberTon.localhost /run/php/php8.3-fpm.sock
echo "[www]" > "$PHP_ETC_DIR/8.3/fpm/pool.d/www.conf"

# legacy7: Drupal 7 in the project root, its own PHP 7.4 pool, no Drush.
mkdir -p "$www/legacy7/includes"
echo "define('VERSION', '7.98');" > "$www/legacy7/includes/bootstrap.inc"
make_site legacy7.conf "$www/legacy7" legacy7.localhost /run/php/php7.4-fpm-legacy7.sock
printf '[legacy7]\nlisten = /run/php/php7.4-fpm-legacy7.sock\n' > "$PHP_ETC_DIR/7.4/fpm/pool.d/legacy7.conf"

# modern: Drupal 11.4 for a PHP that is not installed here.
make_modern_project modern 11.4.10 '{"db-driver":"sqlite","db-name":"sites/default/files/.ht.sqlite","db-username":""}'
make_site modern.conf "$www/modern/web" modern.localhost /run/php/php9.9-fpm.sock

# Not Drupal, and a project already in the registry.
mkdir -p "$www/notdrupal/src"
make_modern_project ours 11.4.10 '{}'
PROJECT_NAME="ours" PROJECT_MACHINE_NAME="ours" PROJECT_PATH="$www/ours" DRUPAL_VERSION="11.4.10" \
    PHP_VERSION="8.5" DATABASE_ENGINE="sqlite" SQLITE_DATABASE_PATH="$www/ours/private/db.sqlite" \
    LOG_FILE="" write_project_record > /dev/null

records="$XDG_DATA_HOME/drupal-local-installer/projects"

# Test 1: Detection reads Drupal version, web root, URL, PHP, pool, database.

output="$(printf 'y\ny\nn\n' | run_scan_projects)"

if [[ "$output" == *"ElBarberTon"*"Drupal:   10.2.5  [unsupported (Drupal 10.2 is end of life)]"* ]] &&
   [[ "$output" == *"URL:      http://ElBarberTon.localhost"* ]] &&
   [[ "$output" == *"PHP:      8.3  (pool: shared, never removed)"* ]] &&
   [[ "$output" == *"legacy7"*"Drupal:   7.98  [unsupported (Drupal 7 is end of life)]"* ]] &&
   [[ "$output" == *"pool: $PHP_ETC_DIR/7.4/fpm/pool.d/legacy7.conf"* ]] &&
   [[ "$output" == *"Database: unknown"* ]] &&
   [[ "$output" == *"modern"*"[php_missing (PHP 9.9 is not installed)]"* ]] &&
   [[ "$output" != *"notdrupal"* && "$output" != *"  ours  ("* ]] &&
   [[ "$output" == *"Found 3 unregistered project(s), registered 2."* ]]; then
    pass "Projects detected: version, web root, URL, PHP, pool; others skipped"
else
    fail "detection: $output"
fi

if [[ "$have_php" -eq 1 ]]; then
    if [[ "$output" == *"Database: mariadb 'elbarber' (user 'root')"* ]]; then
        pass "Database read through the project's Drush (no password)"
    else
        fail "database detection: $output"
    fi
else
    echo "[SKIP] PHP not installed: database detection"
fi

# Support levels.
if [[ "$(get_project_support 12.9.0 8.5)" == "unsupported (Drupal 12.9 is not in the compatibility table yet)" &&
      "$(get_project_support 9.5.11 8.1)" == "unsupported (Drupal 9 is end of life)" ]]; then
    pass "End of life and not-yet-supported releases are told apart"
else
    fail "support levels"
fi

# Test 2: Records: adopted, real paths, shared pool never recorded.

r="$records/elbarberton.conf"

if [[ -f "$r" && -f "$records/legacy7.conf" && ! -f "$records/modern.conf" ]] &&
   grep -qxF "managed_by=adopted" "$r" &&
   grep -qxF "project_path=$www/ElBarberTon" "$r" &&
   grep -qxF "web_root=$www/ElBarberTon/web" "$r" &&
   grep -qxF "php_fpm_pool=" "$r" &&
   grep -qxF "nginx_enabled=$NGINX_SITES_ENABLED_DIR/ElBarberTon" "$r" &&
   grep -qxF "nginx_available=$NGINX_SITES_AVAILABLE_DIR/ElBarberTon" "$r" &&
   grep -qxF "php_fpm_pool=$PHP_ETC_DIR/7.4/fpm/pool.d/legacy7.conf" "$records/legacy7.conf" &&
   grep -qxF "web_root=$www/legacy7" "$records/legacy7.conf"; then
    pass "Adopted records: real paths, shared pool not recorded"
else
    fail "records: $(cat "$r" 2>/dev/null)"
fi

# Test 3: A second scan only offers what is still unregistered.

output="$(printf 'n\n' | run_scan_projects)"

if [[ "$output" == *"modern"* && "$output" != *"ElBarberTon  ("* &&
      "$output" == *"Found 1 unregistered project(s), registered 0."* ]]; then
    pass "Registered projects are not offered again"
else
    fail "second scan: $output"
fi

# Test 4: --list shows type and support.

output="$(list_registered_projects)"

if [[ "$output" == *"elbarberton"*"adopted"*"unsupported (Drupal 10.2 is end of life)"* &&
      "$output" == *"ours"*"installer"* ]]; then
    pass "List shows adopted projects and their support state"
else
    fail "list: $output"
fi

# Test 5: Removing an adopted project: its own files only. The shared
# pool and the database user are never touched.

output="$(REMOVE_DRY_RUN=1 run_remove_project elbarberton < /dev/null)"

if [[ "$output" == *"Type: adopted"* && "$output" == *"shared with other projects: not touched"* &&
      "$output" == *"the user 'root' is kept"* ]]; then
    pass "Adopted plan: shared pool and database user are kept"
else
    fail "adopted plan: $output"
fi

: > "$CALLS_FILE"

if output="$(printf 'n\nelbarberton\n' | run_remove_project elbarberton)" &&
   [[ ! -e "$www/ElBarberTon" && ! -e "$NGINX_SITES_AVAILABLE_DIR/ElBarberTon" &&
      ! -L "$NGINX_SITES_ENABLED_DIR/ElBarberTon" && ! -e "$r" ]] &&
   [[ -f "$PHP_ETC_DIR/8.3/fpm/pool.d/www.conf" ]] &&
   grep -qxF "DROP DATABASE IF EXISTS \`elbarber\`;" "$CALLS_FILE" &&
   ! grep -q "DROP USER" "$CALLS_FILE" &&
   grep -q "^nginx -t" "$CALLS_FILE"; then
    pass "Adopted removal: site, database, folder; www.conf and user kept; nginx -t first"
else
    fail "adopted removal: $output / $(cat "$CALLS_FILE")"
fi

# Test 6: Own pool of an adopted project is removed (after php-fpm -t).

: > "$CALLS_FILE"

if printf 'n\nlegacy7\n' | run_remove_project legacy7 > /dev/null &&
   [[ ! -e "$PHP_ETC_DIR/7.4/fpm/pool.d/legacy7.conf" && ! -e "$www/legacy7" ]] &&
   grep -q "^php-fpm7.4 -t" "$CALLS_FILE" && ! grep -q "DROP" "$CALLS_FILE"; then
    pass "Adopted project's own pool removed; unknown database untouched"
else
    fail "legacy7 removal: $(cat "$CALLS_FILE")"
fi

# Test 7: Changed adopted records are refused.

printf 'n\n' | run_scan_projects > /dev/null
printf 'y\n' | run_scan_projects > /dev/null
r="$records/modern.conf"

for bad in "project_path=/etc" "project_path=$www/../etc" "php_fpm_pool=$PHP_ETC_DIR/8.3/fpm/pool.d/www.conf" \
           "nginx_enabled=/etc/nginx/nginx.conf" "database_engine=mariadb"; do
    cp "$r" "$r.orig"
    sed -i "s|^${bad%%=*}=.*|$bad|" "$r"
    [[ "$bad" == "database_engine=mariadb" ]] && sed -i "s|^database_name=.*|database_name=mysql|" "$r"

    if printf 'n\nmodern\n' | run_remove_project modern > /dev/null; then
        fail "Changed adopted record accepted: $bad"
    fi

    [[ -d "$www/modern" ]] || fail "Something removed with changed record: $bad"
    mv "$r.orig" "$r"
done

pass "Changed adopted records refused (paths, www.conf, system database)"

# Test 8: A site that no longer serves the project is left in place.

sed -i "s|root .*;|root /somewhere/else;|" "$NGINX_SITES_AVAILABLE_DIR/modern.conf"

if output="$(printf 'n\nmodern\n' | run_remove_project modern)" &&
   [[ "$output" == *"[SKIPPED]"*"no longer serves"* ]] &&
   [[ -f "$NGINX_SITES_AVAILABLE_DIR/modern.conf" && ! -e "$www/modern" ]]; then
    pass "Nginx site that now serves something else is not removed"
else
    fail "changed site: $output"
fi

# Test 9: --unregister removes only the registry entry.

if output="$(run_unregister_project ours)" && [[ "$output" == *"Nothing else was changed."* ]] &&
   [[ ! -e "$records/ours.conf" && -d "$www/ours" ]] &&
   ! run_unregister_project ours > /dev/null; then
    pass "--unregister removes only the registry entry"
else
    fail "unregister: $output"
fi

# Test 10: Socket names without a PHP version (a real work setup):
#   fastcgi_pass unix:/var/run/php-fpm-crmManager.sock;
#   /etc/php/8.3/fpm/pool.d/crmManager.conf: listen = /var/run/php-fpm-crmManager.sock
# The version comes from the pool that listens on the socket. Also TCP
# pools, and a project whose PHP cannot be found at all.

make_modern_project crmManager 10.6.18 '{"db-driver":"mysql","db-name":"crm","db-username":"crm_user"}'
make_site crmManager "$www/crmManager/web" crmManager.localhost /var/run/php-fpm-crmManager.sock
printf '[crmManager]\nlisten = /var/run/php-fpm-crmManager.sock\n' > "$PHP_ETC_DIR/8.3/fpm/pool.d/crmManager.conf"

make_modern_project tcpsite 11.4.10 '{}'
make_site tcpsite.conf "$www/tcpsite/web" tcpsite.localhost 127.0.0.1:9001
sed -i 's|unix:127.0.0.1:9001|127.0.0.1:9001|' "$NGINX_SITES_AVAILABLE_DIR/tcpsite.conf"
printf '[tcpsite]\nlisten = 127.0.0.1:9001\n' > "$PHP_ETC_DIR/7.4/fpm/pool.d/tcpsite.conf"

make_modern_project nopool 11.4.10 '{"db-driver":"mysql","db-name":"nopool","db-username":"np"}'
make_site nopool.conf "$www/nopool/web" nopool.localhost /var/run/somewhere.sock

rm -f "$records/ours.conf"
output="$(printf 'y\ny\ny\ny\n' | run_scan_projects)"

if grep -qxF "php_version=8.3" "$records/crmmanager.conf" &&
   grep -qxF "php_fpm_pool=$PHP_ETC_DIR/8.3/fpm/pool.d/crmManager.conf" "$records/crmmanager.conf" &&
   grep -qxF "php_fpm_socket=/var/run/php-fpm-crmManager.sock" "$records/crmmanager.conf"; then
    pass "PHP version and own pool found from the pool's listen (/var/run socket)"
else
    fail "crmManager: $output / $(cat "$records/crmmanager.conf" 2>/dev/null)"
fi

if grep -qxF "php_version=7.4" "$records/tcpsite.conf" &&
   grep -qxF "php_fpm_pool=$PHP_ETC_DIR/7.4/fpm/pool.d/tcpsite.conf" "$records/tcpsite.conf"; then
    pass "TCP pool (127.0.0.1:9001) found the same way"
else
    fail "tcpsite: $(cat "$records/tcpsite.conf" 2>/dev/null)"
fi

if grep -qxF "php_version=" "$records/nopool.conf" && grep -qxF "php_fpm_pool=" "$records/nopool.conf"; then
    pass "Unknown PHP: nothing guessed, no pool recorded"
else
    fail "nopool: $(cat "$records/nopool.conf" 2>/dev/null)"
fi

if [[ "$have_php" -eq 1 ]]; then
    if grep -qxF "database_name=crm" "$records/crmmanager.conf" &&
       grep -qxF "database_name=nopool" "$records/nopool.conf"; then
        pass "Database read with the project PHP, or the default php when unknown"
    else
        fail "database fallback: $(cat "$records/nopool.conf")"
    fi
fi

if [[ "$(list_registered_projects)" == *"nopool"*"http://nopool.localhost"*"?"* ]]; then
    pass "Unknown PHP shown as ? in the list"
else
    fail "list with unknown PHP: $(list_registered_projects)"
fi

# The pool lookup treats /var/run and /run as the same directory.
if [[ "$(find_pool_for_listen /run/php-fpm-crmManager.sock)" == "$PHP_ETC_DIR/8.3/fpm/pool.d/crmManager.conf" ]] &&
   ! find_pool_for_listen /run/php-fpm-nothing.sock > /dev/null; then
    pass "/var/run and /run are the same path for the pool lookup"
else
    fail "run path normalisation"
fi

echo "[SUCCESS] Project scan tests passed."
