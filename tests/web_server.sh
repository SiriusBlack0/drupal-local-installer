#!/usr/bin/env bash

# Live installation of the Nginx site and the PHP-FPM pool, with
# validation, reload and rollback. Nothing outside a temporary
# directory is touched: /etc paths are redirected and sudo, nginx,
# php-fpm, systemctl, service and mysql are stubs.

set -euo pipefail

cd "$(dirname "$0")/.."

source lib/output.sh
source lib/system.sh
source lib/php_fpm.sh
source lib/nginx.sh
source lib/database.sh

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

etc_dir="$work_dir/etc"
stub_bin="$work_dir/bin"
calls_file="$work_dir/calls"
mkdir -p "$etc_dir/sites-available" "$etc_dir/sites-enabled" "$etc_dir/pool.d" "$stub_bin"

pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; exit 1; }

# Redirect every /etc path into the temporary directory.
get_nginx_config_path() { printf '%s/sites-available/%s.conf\n' "$etc_dir" "$1"; }
get_nginx_enabled_path() { printf '%s/sites-enabled/%s.conf\n' "$etc_dir" "$1"; }
get_php_fpm_pool_config_path() { printf '%s/pool.d/%s.conf\n' "$etc_dir" "$1"; }

# sudo records the command; "install" drops the root ownership options.
cat > "$stub_bin/sudo" <<'STUB'
#!/usr/bin/env bash
echo "sudo $*" >> "$CALLS_FILE"
if [[ "$1" == "install" ]]; then
    exec cp -- "${@: -2:1}" "${@: -1}"
fi
exec "$@"
STUB

# Configuration tests fail when $FAIL_CHECK names the tool.
for tool in nginx php-fpm8.5; do
    cat > "$stub_bin/$tool" <<STUB
#!/usr/bin/env bash
echo "$tool \$*" >> "\$CALLS_FILE"
[[ "\${FAIL_CHECK:-}" != "$tool" ]]
STUB
done

# Reloads fail when $FAIL_RELOAD names the service.
cat > "$stub_bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >> "$CALLS_FILE"
[[ "${FAIL_RELOAD:-}" != "${@: -1}" ]]
STUB

cat > "$stub_bin/service" <<'STUB'
#!/usr/bin/env bash
echo "service $*" >> "$CALLS_FILE"
case "$2" in
    status) [[ "${SERVICE_RUNNING:-0}" == "1" ]] ;;
    *) [[ "${FAIL_RELOAD:-}" != "$1" ]] ;;
esac
STUB

# mysql records the SQL it receives on stdin.
cat > "$stub_bin/mysql" <<'STUB'
#!/usr/bin/env bash
cat >> "$CALLS_FILE"
STUB

chmod +x "$stub_bin"/*
export CALLS_FILE="$calls_file"
PATH="$stub_bin:$PATH"

has_systemd() { return 0; }

reset_state() {
    rm -f "$etc_dir"/sites-available/* "$etc_dir"/sites-enabled/* "$etc_dir"/pool.d/* "$calls_file"
    touch "$calls_file"
    unset FAIL_CHECK FAIL_RELOAD
}

calls() { cat "$calls_file"; }

# Test 1: PHP-FPM pool installed, checked, then reloaded.

reset_state

if output="$(install_php_fpm_pool "mysite" "8.5" "devuser")" &&
   grep -qxF "user = devuser" "$etc_dir/pool.d/mysite.conf" &&
   [[ "$(calls)" == *"php-fpm8.5 -t"*"systemctl reload-or-restart php8.5-fpm"* ]] &&
   [[ "$output" == *"[OK] PHP-FPM pool ready: /run/php/php8.5-fpm-mysite.sock"* ]]; then
    pass "Pool installed, tested with php-fpm -t, then reloaded"
else
    fail "pool install: $output / $(calls)"
fi

if [[ "$(calls)" == *"sudo install -m 0644 -o root -g root"* ]]; then
    pass "Pool file installed as root with mode 0644"
else
    fail "pool install command: $(calls)"
fi

# Test 2: An existing pool is never replaced.

echo "custom" > "$etc_dir/pool.d/other.conf"

if install_php_fpm_pool "other" "8.5" "devuser" > /dev/null; then
    fail "Existing pool replaced"
elif [[ "$(cat "$etc_dir/pool.d/other.conf")" == "custom" ]]; then
    pass "Existing pool left untouched"
else
    fail "Existing pool modified"
fi

# Test 3: Failed check: pool removed, PHP-FPM not reloaded.

reset_state
export FAIL_CHECK="php-fpm8.5"

if output="$(install_php_fpm_pool "mysite" "8.5" "devuser")"; then
    fail "Failed PHP-FPM check reported as success"
elif [[ ! -e "$etc_dir/pool.d/mysite.conf" && "$(calls)" != *"reload"* ]]; then
    pass "Failed php-fpm -t: pool removed, no reload"
else
    fail "failed PHP-FPM check: $output / $(calls)"
fi

# Test 4: Failed reload: pool removed.

reset_state
export FAIL_RELOAD="php8.5-fpm"

if install_php_fpm_pool "mysite" "8.5" "devuser" > /dev/null; then
    fail "Failed PHP-FPM reload reported as success"
elif [[ ! -e "$etc_dir/pool.d/mysite.conf" ]]; then
    pass "Failed PHP-FPM reload: pool removed"
else
    fail "pool left after failed reload"
fi

# Test 5: Nginx site installed, enabled, checked, then reloaded.

reset_state

if output="$(install_nginx_site "mysite" "/var/www/mysite" "8.5")" &&
   grep -qF "server_name mysite.localhost;" "$etc_dir/sites-available/mysite.conf" &&
   [[ "$(readlink "$etc_dir/sites-enabled/mysite.conf")" == "$etc_dir/sites-available/mysite.conf" ]] &&
   [[ "$(calls)" == *"nginx -t"*"systemctl reload-or-restart nginx"* ]] &&
   [[ "$output" == *"[OK] Nginx site enabled: http://mysite.localhost"* ]]; then
    pass "Site installed, enabled, tested with nginx -t, then reloaded"
else
    fail "site install: $output / $(calls)"
fi

# Test 6: Existing site (available or enabled) is never replaced.

reset_state
echo "custom" > "$etc_dir/sites-enabled/mysite.conf"

if install_nginx_site "mysite" "/var/www/mysite" "8.5" > /dev/null; then
    fail "Existing enabled site replaced"
elif [[ "$(cat "$etc_dir/sites-enabled/mysite.conf")" == "custom" &&
        ! -e "$etc_dir/sites-available/mysite.conf" ]]; then
    pass "Existing Nginx site left untouched"
else
    fail "Existing Nginx site modified"
fi

# Test 7: Failed nginx -t: both files removed, Nginx not reloaded.

reset_state
export FAIL_CHECK="nginx"

if install_nginx_site "mysite" "/var/www/mysite" "8.5" > /dev/null; then
    fail "Failed nginx -t reported as success"
elif [[ ! -e "$etc_dir/sites-available/mysite.conf" &&
        ! -L "$etc_dir/sites-enabled/mysite.conf" &&
        "$(calls)" != *"reload"* ]]; then
    pass "Failed nginx -t: site removed, no reload"
else
    fail "failed nginx -t: $(calls)"
fi

# Test 8: Invalid input creates nothing.

reset_state

if install_nginx_site "my-site" "/var/www/mysite" "8.5" > /dev/null 2>&1 ||
   install_php_fpm_pool "mysite" "8;5" "devuser" > /dev/null 2>&1; then
    fail "Invalid input accepted"
elif [[ -z "$(find "$etc_dir" -type f -o -type l)" && ! -s "$calls_file" ]]; then
    pass "Invalid input rejected before anything is written"
else
    fail "invalid input left files: $(calls)"
fi

# Test 9: Removal deletes the files and reloads.

reset_state
install_php_fpm_pool "mysite" "8.5" "devuser" > /dev/null
install_nginx_site "mysite" "/var/www/mysite" "8.5" > /dev/null
: > "$calls_file"

if remove_nginx_site "mysite" && remove_php_fpm_pool "mysite" "8.5" &&
   [[ -z "$(find "$etc_dir" -type f -o -type l)" ]] &&
   [[ "$(calls)" == *"reload-or-restart nginx"*"reload-or-restart php8.5-fpm"* ]]; then
    pass "Site and pool removed, services reloaded"
else
    fail "removal: $(calls)"
fi

if remove_nginx_site "../etc" || remove_php_fpm_pool "mysite" "../8"; then
    fail "Unsafe removal input accepted"
else
    pass "Unsafe removal input rejected"
fi

# Test 10: reload_or_start_service without systemd.

has_systemd() { return 1; }
reset_state

SERVICE_RUNNING=1 reload_or_start_service nginx
SERVICE_RUNNING=0 reload_or_start_service mariadb

if [[ "$(calls)" == *"service nginx reload"* && "$(calls)" == *"service mariadb start"* &&
      "$(calls)" != *"restart"* ]]; then
    pass "Without systemd: running service reloaded, stopped one started"
else
    fail "SysV reload: $(calls)"
fi

has_systemd() { return 0; }

# Test 11: remove_project_database.

reset_state

if remove_project_database "mariadb" "my_db" "my_user" &&
   grep -qxF "DROP DATABASE IF EXISTS \`my_db\`;" "$calls_file" &&
   grep -qxF "DROP USER IF EXISTS 'my_user'@'localhost';" "$calls_file"; then
    pass "MariaDB database and user dropped"
else
    fail "MariaDB removal: $(calls)"
fi

reset_state

if remove_project_database "mysql" "bad\`name" "my_user" > /dev/null ||
   remove_project_database "mariadb" "my_db" "bad'user" > /dev/null; then
    fail "Unsafe database name accepted"
elif [[ ! -s "$calls_file" ]]; then
    pass "Unsafe database name or user rejected before any SQL"
else
    fail "SQL sent for unsafe input: $(calls)"
fi

if remove_project_database "sqlite" "" "" && ! remove_project_database "oracle" "x" "y" > /dev/null; then
    pass "SQLite needs no removal; unknown engine rejected"
else
    fail "SQLite/unknown engine removal"
fi

# Test 12: verify_nginx_site asks the site over IPv4 and IPv6.
# The curl stub answers like Drupal except for the family in
# $CURL_FAIL_FAMILY, where the default site answers instead.

cat > "$stub_bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$CALLS_FILE"
if [[ "$1" == "-${CURL_FAIL_FAMILY:-none}" ]]; then
    printf 'HTTP/1.1 200 OK\r\nServer: nginx\r\n'
else
    printf 'HTTP/1.1 302 Found\r\nLocation: http://mysite.localhost/core/install.php\r\n'
fi
STUB
chmod +x "$stub_bin/curl"
sleep() { echo "sleep $*" >> "$CALLS_FILE"; }

reset_state

if output="$(NGINX_IPV6=1 verify_nginx_site "mysite")" &&
   [[ "$output" == *"[OK] http://mysite.localhost answers (IPv4 and IPv6)"* ]] &&
   [[ "$(calls)" == *"curl -4 "*"curl -6 "* ]]; then
    pass "Site checked over IPv4 and IPv6"
else
    fail "verify both families: $output / $(calls)"
fi

reset_state

if output="$(NGINX_IPV6=1 CURL_FAIL_FAMILY=6 verify_nginx_site "mysite")"; then
    fail "Site answering only over IPv4 reported as OK"
elif [[ "$output" == *"does not answer as this Drupal site over: IPv6"* &&
        "$output" == *"nginx -T"* &&
        "$(grep -c '^curl -6' "$calls_file")" == "5" &&
        "$(grep -c '^sleep' "$calls_file")" == "4" ]]; then
    pass "Wrong answer over IPv6 detected after 5 attempts"
else
    fail "IPv6 failure: $output / $(calls)"
fi

reset_state

if output="$(NGINX_IPV6=0 verify_nginx_site "mysite")" &&
   [[ "$output" == *"answers (IPv4)"* && "$(calls)" != *"curl -6"* ]]; then
    pass "Only IPv4 checked on a system without IPv6"
else
    fail "IPv4-only check: $output / $(calls)"
fi

if output="$(PATH="/nonexistent" verify_nginx_site "mysite")" &&
   [[ "$output" == *"curl is not installed"* ]]; then
    pass "Missing curl: warning, not a failure"
else
    fail "missing curl: $output"
fi

echo "[SUCCESS] Web server installation tests passed."
