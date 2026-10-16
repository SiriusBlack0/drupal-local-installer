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

echo "[SUCCESS] SQLite database tests passed."
