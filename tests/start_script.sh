#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

source lib/output.sh
source lib/system.sh
source lib/php_fpm.sh
source lib/nginx.sh
source lib/registry.sh
source lib/project.sh

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

current_user="$(id -un)"
state_dir="$work_dir/state"
stub_bin="$work_dir/bin"
mkdir -p "$state_dir" "$stub_bin"

pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; exit 1; }

# Stub service tools. A file in $state_dir means "service is running".
# Services listed in $state_dir/.fail cannot be started.
# Both systemctl and service are stubbed, so the test works with or
# without systemd on the machine that runs it.
cat > "$stub_bin/systemctl" <<STUB
#!/usr/bin/env bash
case "\$1" in
    is-active) [[ -e "$state_dir/\$3" ]] ;;
    start) grep -qx "\$2" "$state_dir/.fail" 2>/dev/null && exit 1; touch "$state_dir/\$2" ;;
    reload) "$stub_bin/on_reload" "\$2" ;;
esac
STUB

cat > "$stub_bin/service" <<STUB
#!/usr/bin/env bash
case "\$2" in
    status) [[ -e "$state_dir/\$1" ]] ;;
    start) grep -qx "\$1" "$state_dir/.fail" 2>/dev/null && exit 1; touch "$state_dir/\$1" ;;
    reload) "$stub_bin/on_reload" "\$1" ;;
esac
STUB

# Reload stub: PHP-FPM creates the pending pool socket, Nginx starts
# serving the pending site. Every reload is recorded in .reloads.
cat > "$stub_bin/on_reload" <<STUB
#!/usr/bin/env bash
echo "\$1" >> "$state_dir/.reloads"
case "\$1" in
    php8.5-fpm)
        [[ -e "$state_dir/.pool_pending" ]] &&
            python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$state_dir/pool.sock"
        ;;
    nginx)
        [[ -e "$state_dir/.site_pending" ]] && cp "$state_dir/.site_pending" "$state_dir/.http"
        ;;
esac
exit 0
STUB

# curl prints the headers stored in .http (nothing = no answer).
# With .ipv6_default, IPv6 requests get the default Nginx page instead.
cat > "$stub_bin/curl" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "-6" && -e "$state_dir/.ipv6_default" ]]; then
    printf 'HTTP/1.1 200 OK\\r\\nServer: nginx\\r\\n'
    exit 0
fi
cat "$state_dir/.http" 2>/dev/null
STUB

# Configuration tests fail when .config_bad exists.
printf '#!/usr/bin/env bash\n[[ ! -e "%s/.config_bad" ]]\n' "$state_dir" > "$stub_bin/nginx"
cp "$stub_bin/nginx" "$stub_bin/php-fpm8.5"

printf '#!/usr/bin/env bash\nexec "$@"\n' > "$stub_bin/sudo"
printf '#!/usr/bin/env bash\n' > "$stub_bin/sleep"
chmod +x "$stub_bin/systemctl" "$stub_bin/service" "$stub_bin/sudo" \
    "$stub_bin/on_reload" "$stub_bin/curl" "$stub_bin/nginx" \
    "$stub_bin/php-fpm8.5" "$stub_bin/sleep"
PATH="$stub_bin:$PATH"

new_project() {
    local project="$work_dir/$1"
    rm -rf "$project"
    mkdir "$project"
    printf '%s\n' "$project"
}

# Test 1: Services depend on the chosen database.

project="$(new_project mariadb_site)"
create_start_script "$project" "8.5" "mariadb" "mysite" "$current_user" > /dev/null

if grep -qxF 'services=(php8.5-fpm nginx mariadb)' "$project/start" &&
   grep -qxF 'url=http://mysite.localhost' "$project/start" &&
   [[ "$(stat -c '%a' "$project/start")" == "750" ]]; then
    pass "./start for MariaDB starts PHP-FPM, Nginx and MariaDB"
else
    fail "MariaDB start script content"
fi

sqlite_project="$(new_project sqlite_site)"
create_start_script "$sqlite_project" "8.4" "sqlite" "mysite" "$current_user" > /dev/null
pg_project="$(new_project pg_site)"
create_start_script "$pg_project" "8.5" "postgresql" "mysite" "$current_user" > /dev/null

if grep -qxF 'services=(php8.4-fpm nginx)' "$sqlite_project/start" &&
   grep -qxF 'services=(php8.5-fpm nginx postgresql)' "$pg_project/start"; then
    pass "SQLite needs no database service; PostgreSQL is included"
else
    fail "service list per database"
fi

# Test 2: Everything already running is left alone.

touch "$state_dir/php8.5-fpm" "$state_dir/nginx" "$state_dir/mariadb"

if output="$("$project/start")" &&
   [[ "$output" == *"[RUNNING] php8.5-fpm"*"[RUNNING] nginx"*"[RUNNING] mariadb"* ]]; then
    pass "Running services are reported and left alone"
else
    fail "running services: $output"
fi

# Test 3: Stopped services are started.

rm -f "$state_dir/nginx" "$state_dir/mariadb"

if output="$("$project/start")" &&
   [[ "$output" == *"[RUNNING] php8.5-fpm"*"[STARTED] nginx"*"[STARTED] mariadb"* ]] &&
   [[ -e "$state_dir/nginx" && -e "$state_dir/mariadb" ]]; then
    pass "Stopped services are started"
else
    fail "stopped services: $output"
fi

# Test 4: A service that cannot start is reported, exit code 1.

rm -f "$state_dir/mariadb"
echo "mariadb" > "$state_dir/.fail"

if output="$("$project/start" 2>&1)"; then
    fail "Start failure reported as success"
elif [[ "$output" == *"[FAILED]  mariadb"* && "$output" == *"could not be started: mariadb"* && "$output" == *"Details:"* ]]; then
    pass "Failed service reported with exit code 1"
else
    fail "failed service: $output"
fi

rm -f "$state_dir/.fail"

# Test 5: Without an Nginx site yet, ./start says so instead of a URL.

touch "$state_dir/mariadb"
output="$("$project/start")"

if [[ "$output" == *"Nginx site for this project is not set up yet"* ]] &&
   [[ "$output" != *"Project ready"* ]]; then
    pass "No URL shown before the Nginx site exists"
else
    fail "site message: $output"
fi

# Test 6: ./start works from any directory.

if (cd / && "$project/start" > /dev/null); then
    pass "./start works from any directory"
else
    fail "./start from another directory"
fi

# Test 7: Invalid input and existing files.

if create_start_script "$(new_project bad1)" "8;x" "mariadb" "mysite" "$current_user" > /dev/null ||
   create_start_script "$(new_project bad2)" "8.5" "oracle" "mysite" "$current_user" > /dev/null ||
   create_start_script "$(new_project bad3)" "8.5" "mariadb" "my-site" "$current_user" > /dev/null; then
    fail "Invalid start script input accepted"
else
    pass "Invalid PHP version, engine or name rejected"
fi

keep_project="$(new_project keep_site)"
echo "custom" > "$keep_project/start"

if create_start_script "$keep_project" "8.5" "mariadb" "mysite" "$current_user" > /dev/null; then
    fail "Existing ./start replaced"
elif [[ "$(cat "$keep_project/start")" == "custom" ]]; then
    pass "Existing ./start left untouched"
else
    fail "Existing ./start modified"
fi

# Tests 8-11 use a copy of ./start whose Nginx site and pool socket
# point into the temporary directory.

site_project="$(new_project site_ready)"
create_start_script "$site_project" "8.5" "mariadb" "mysite" "$current_user" > /dev/null
touch "$state_dir/site.conf"
sed -i \
    -e "s#^site_config=.*#site_config=$state_dir/site.conf#" \
    -e "s#^socket=.*#socket=$state_dir/pool.sock#" \
    -e "s#^ipv6_flag=.*#ipv6_flag=$state_dir/ipv6#" \
    "$site_project/start"

reset_site_state() {
    rm -f "$state_dir/pool.sock" "$state_dir/.http" "$state_dir/.reloads" \
        "$state_dir/.pool_pending" "$state_dir/.site_pending" "$state_dir/.config_bad"
}

make_socket() {
    python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$1"
}

# Test 8: Everything loaded: no reload, URL shown.

reset_site_state
make_socket "$state_dir/pool.sock"
printf 'HTTP/1.1 302 Found\r\nLocation: http://mysite.localhost/core/install.php\r\n' > "$state_dir/.http"

if output="$("$site_project/start")" &&
   [[ "$output" == *"Project ready: http://mysite.localhost"* ]] &&
   [[ ! -e "$state_dir/.reloads" ]]; then
    pass "Loaded project: URL shown, nothing reloaded"
else
    fail "loaded project: $output"
fi

# Test 9: New pool and site while services were already running:
# both are reloaded (not restarted) and then the URL is shown.

reset_site_state
touch "$state_dir/.pool_pending"
printf 'HTTP/1.1 200 OK\r\nX-Generator: Drupal 11 (https://www.drupal.org)\r\n' > "$state_dir/.site_pending"

if output="$("$site_project/start")" &&
   [[ "$output" == *"[RELOADED] php8.5-fpm"*"[RELOADED] nginx"*"Project ready"* ]] &&
   [[ "$(tr '\n' ' ' < "$state_dir/.reloads")" == "php8.5-fpm nginx " ]]; then
    pass "Pending pool and site are loaded with a reload"
else
    fail "pending pool/site: $output"
fi

# Test 10: An invalid configuration is never reloaded.

reset_site_state
touch "$state_dir/.pool_pending" "$state_dir/.config_bad"

if output="$("$site_project/start" 2>&1)"; then
    fail "Invalid PHP-FPM configuration reported as success"
elif [[ ! -e "$state_dir/.reloads" && "$output" == *"pool is not running"* ]]; then
    pass "Invalid configuration: no reload, exit code 1"
else
    fail "invalid configuration: $output"
fi

# Test 11: A site that never answers as Drupal is reported.

reset_site_state
make_socket "$state_dir/pool.sock"
printf 'HTTP/1.1 200 OK\r\nServer: nginx\r\n' > "$state_dir/.http"

if output="$("$site_project/start" 2>&1)"; then
    fail "Non-Drupal answer reported as success"
elif [[ "$output" == *"does not answer as a Drupal site"* && "$output" == *"mysite.error.log"* ]] &&
     [[ "$(cat "$state_dir/.reloads")" == "nginx" ]]; then
    pass "Non-Drupal answer: one Nginx reload, then reported"
else
    fail "non-Drupal answer: $output"
fi

# Test 12: A site that answers over IPv4 but not over IPv6 is not
# reported as ready (browsers try ::1 first for *.localhost).

touch "$state_dir/ipv6"
reset_site_state
make_socket "$state_dir/pool.sock"
printf 'HTTP/1.1 302 Found\r\nLocation: http://mysite.localhost/core/install.php\r\n' > "$state_dir/.http"
touch "$state_dir/.ipv6_default"

if output="$("$site_project/start" 2>&1)"; then
    fail "Site missing on IPv6 reported as ready"
elif [[ "$output" == *"does not answer as a Drupal site"* ]]; then
    pass "Site missing on IPv6 is reported"
else
    fail "IPv6 check: $output"
fi

rm -f "$state_dir/.ipv6_default"

# Without IPv6 only IPv4 is asked.
rm -f "$state_dir/ipv6"
touch "$state_dir/.ipv6_default"

if output="$("$site_project/start")" && [[ "$output" == *"Project ready"* ]]; then
    pass "Without IPv6 only IPv4 is checked"
else
    fail "IPv4-only ./start: $output"
fi

rm -f "$state_dir/.ipv6_default"

# Test 13: The generated script itself passes ShellCheck.

if ! command -v shellcheck > /dev/null; then
    echo "[SKIP] ShellCheck not installed"
elif shellcheck -S style "$project/start"; then
    pass "Generated ./start passes ShellCheck"
else
    fail "Generated ./start has ShellCheck findings"
fi

echo "[SUCCESS] Start script tests passed."
