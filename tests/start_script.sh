#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

source lib/output.sh
source lib/system.sh
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
esac
STUB

cat > "$stub_bin/service" <<STUB
#!/usr/bin/env bash
case "\$2" in
    status) [[ -e "$state_dir/\$1" ]] ;;
    start) grep -qx "\$1" "$state_dir/.fail" 2>/dev/null && exit 1; touch "$state_dir/\$1" ;;
esac
STUB

printf '#!/usr/bin/env bash\nexec "$@"\n' > "$stub_bin/sudo"
chmod +x "$stub_bin/systemctl" "$stub_bin/service" "$stub_bin/sudo"
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

# Test 8: The generated script itself passes ShellCheck.

if ! command -v shellcheck > /dev/null; then
    echo "[SKIP] ShellCheck not installed"
elif shellcheck -S style "$project/start"; then
    pass "Generated ./start passes ShellCheck"
else
    fail "Generated ./start has ShellCheck findings"
fi

echo "[SUCCESS] Start script tests passed."
