#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

source lib/database.sh

work_dir="$(mktemp -d)"
trap 'chmod -R u+w "$work_dir" 2>/dev/null; rm -rf "$work_dir"' EXIT

# Test 1: Database path is outside the web root.

if [[ "$(get_sqlite_database_path "/var/www/mydrupal")" == "/var/www/mydrupal/private/database.sqlite" ]] &&
   [[ "$(get_sqlite_database_path "/var/www/mydrupal/")" == "/var/www/mydrupal/private/database.sqlite" ]]; then
    echo "[PASS] SQLite path generated outside web root"
else
    echo "[FAIL] SQLite path generated incorrectly"
    exit 1
fi

# Test 2: Relative project path is rejected.

if get_sqlite_database_path "mydrupal" >/dev/null 2>&1; then
    echo "[FAIL] Relative project path accepted"
    exit 1
else
    echo "[PASS] Relative project path rejected"
fi

# Test 3: Unsafe database paths are rejected.

for bad_path in \
    "relative/database.sqlite" \
    "/var/www/site/../etc/database.sqlite" \
    "/var/www/site/./database.sqlite" \
    "/var/www/site/web/database.sqlite" \
    "/var/www/site/private/database.db" \
    "/var/www/my site/private/database.sqlite"; do

    if is_valid_sqlite_database_path "$bad_path"; then
        echo "[FAIL] Unsafe SQLite path accepted: $bad_path"
        exit 1
    fi
done

echo "[PASS] Unsafe SQLite paths rejected"

# Test 4: Provisioning creates a private directory but not the file.

project_dir="$work_dir/site"
mkdir "$project_dir"
database_path="$project_dir/private/database.sqlite"

if output="$(provision_sqlite_database "$database_path")" &&
   [[ -d "$project_dir/private" ]] &&
   [[ "$(stat -c '%a' "$project_dir/private")" == "700" ]] &&
   [[ ! -e "$database_path" ]] &&
   [[ "$output" == *"[SUCCESS] SQLite database directory ready"* ]]; then
    echo "[PASS] SQLite directory created with mode 700"
else
    echo "[FAIL] SQLite directory provisioning incorrect"
    exit 1
fi

# Test 5: Existing database file is not touched.

touch "$database_path"

if output="$(provision_sqlite_database "$database_path")"; then
    echo "[FAIL] Existing SQLite database accepted"
    exit 1
elif [[ "$output" == *"[ERROR] SQLite database already exists"* ]]; then
    echo "[PASS] Existing SQLite database rejected"
else
    echo "[FAIL] Unexpected existing database result"
    exit 1
fi

rm "$database_path"

# Test 6: Symbolic link at the database path is rejected.

ln -s /tmp/nonexistent-target "$database_path"

if provision_sqlite_database "$database_path" >/dev/null; then
    echo "[FAIL] Symbolic link accepted as SQLite database"
    exit 1
else
    echo "[PASS] Symbolic link at SQLite path rejected"
fi

rm "$database_path"

# Test 7: Read-only parent directory is reported (skipped as root).

if [[ "$(id -u)" -eq 0 ]]; then
    echo "[SKIP] Read-only directory test (running as root)"
else
    readonly_dir="$work_dir/readonly"
    mkdir "$readonly_dir"
    chmod 0500 "$readonly_dir"

    if provision_sqlite_database "$readonly_dir/private/database.sqlite" >/dev/null 2>&1; then
        echo "[FAIL] Read-only parent directory accepted"
        exit 1
    else
        echo "[PASS] Read-only parent directory rejected"
    fi
fi

# Test 7b: The directory is handed to the project owner when needed.

sudo_log="$work_dir/sudo.log"
sudo() { echo "sudo $*" >> "$sudo_log"; }

owner_project="$work_dir/owner_site"
mkdir "$owner_project"
: > "$sudo_log"

if provision_sqlite_database "$owner_project/private/database.sqlite" "otheruser" > /dev/null &&
   [[ "$(cat "$sudo_log")" == "sudo chown otheruser $owner_project/private" ]]; then
    echo "[PASS] SQLite directory given to the project owner"
else
    echo "[FAIL] SQLite owner handling: $(cat "$sudo_log")"
    exit 1
fi

same_project="$work_dir/same_site"
mkdir "$same_project"
: > "$sudo_log"

if provision_sqlite_database "$same_project/private/database.sqlite" "$(id -un)" > /dev/null &&
   [[ ! -s "$sudo_log" ]]; then
    echo "[PASS] No sudo when the owner runs the installer"
else
    echo "[FAIL] Unexpected sudo for the same owner"
    exit 1
fi

unset -f sudo

# Test 8: Dispatcher routes SQLite with the file path.

provision_sqlite_database() {
    echo "sqlite_provision $1"
}

if [[ "$(provision_project_database "sqlite" "/var/www/site/private/database.sqlite")" == \
      "sqlite_provision /var/www/site/private/database.sqlite" ]]; then
    echo "[PASS] Dispatcher routes SQLite provisioning"
else
    echo "[FAIL] Dispatcher did not route SQLite"
    exit 1
fi

# Tests 9-12: SQLite is detected through PHP's pdo_sqlite, not sqlite3.

detection() {
    local installed="no"

    if is_database_engine_installed sqlite; then
        installed="yes"
    fi

    printf '%s|%s' "$installed" "$(get_available_database_version sqlite)"
}

# Stub commands in a temporary bin directory (php8.5, apt-cache).
stub_bin="$work_dir/bin"
mkdir -p "$stub_bin"
PATH="$stub_bin:$PATH"

cat > "$stub_bin/apt-cache" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == "policy libsqlite3-0" ]]; then
    printf '  Installed: (none)\n  Candidate: 3.46.1-7\n'
fi
STUB

# PHP with pdo_sqlite: version comes from PHP itself.
printf '#!/usr/bin/env bash\necho 3.45.3\n' > "$stub_bin/php8.5"
chmod +x "$stub_bin/apt-cache" "$stub_bin/php8.5"
PHP_VERSION="8.5"

if [[ "$(detection)" == "yes|3.45.3" ]] &&
   [[ "$(get_installed_database_version sqlite)" == "3.45.3" ]]; then
    echo "[PASS] SQLite detected through PHP pdo_sqlite"
else
    echo "[FAIL] SQLite PHP detection: $(detection)"
    exit 1
fi

# PHP without pdo_sqlite: not installed, version of the library to install.
printf '#!/usr/bin/env bash\nexit 1\n' > "$stub_bin/php8.5"

if [[ "$(detection)" == "no|3.46.1" ]]; then
    echo "[PASS] Missing pdo_sqlite reported as not installed"
else
    echo "[FAIL] Missing pdo_sqlite detection: $(detection)"
    exit 1
fi

# No PHP version chosen yet.
unset PHP_VERSION

if [[ "$(detection)" == "no|3.46.1" ]]; then
    echo "[PASS] SQLite not installed without a PHP version"
else
    echo "[FAIL] SQLite detection without PHP version: $(detection)"
    exit 1
fi

# Invalid PHP version never reaches a php binary.
PHP_VERSION="8; rm -rf /"

if [[ "$(detection)" == "no|3.46.1" ]]; then
    echo "[PASS] Invalid PHP version rejected for SQLite detection"
else
    echo "[FAIL] Invalid PHP version handling: $(detection)"
    exit 1
fi

echo "[SUCCESS] SQLite database tests passed."
