#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

source lib/database.sh

mock_log="$(mktemp)"
trap 'rm -f "$mock_log"' EXIT

# Test 1: PostgreSQL database exists.

: > "$mock_log"

sudo() {
    cat > /dev/null
    echo "1"
    return 0
}

if postgresql_database_exists "drupal_db"; then
    echo "[PASS] PostgreSQL existing database detected"
else
    echo "[FAIL] PostgreSQL existing database not detected"
    exit 1
fi

# Test 2: PostgreSQL database does not exist.

sudo() {
    cat > /dev/null
    return 0
}

if postgresql_database_exists "missing_db"; then
    echo "[FAIL] Non-existing PostgreSQL database detected"
    exit 1
else
    status=$?

    if [[ "$status" -eq 1 ]]; then
        echo "[PASS] Non-existing PostgreSQL database detected correctly"
    else
        echo "[FAIL] Unexpected PostgreSQL database lookup status: $status"
        exit 1
    fi
fi

# Test 3: PostgreSQL database lookup failure.

sudo() {
    cat > /dev/null
    return 1
}

if postgresql_database_exists "drupal_db"; then
    echo "[FAIL] PostgreSQL database lookup failure ignored"
    exit 1
else
    status=$?

    if [[ "$status" -eq 2 ]]; then
        echo "[PASS] PostgreSQL database lookup failure detected"
    else
        echo "[FAIL] Unexpected PostgreSQL database lookup status: $status"
        exit 1
    fi
fi

# Test 4: Missing owner role prevents database creation.

: > "$mock_log"

postgresql_user_exists() {
    echo "user_lookup" >> "$mock_log"
    return 1
}

postgresql_database_exists() {
    echo "db_lookup" >> "$mock_log"
    return 1
}

sudo() {
    echo "sudo_called" >> "$mock_log"
    return 0
}

if output="$(create_postgresql_database "drupal_db" "drupal_user")"; then
    echo "[FAIL] Database created without owner role"
    exit 1
elif [[ "$output" == *"[ERROR] PostgreSQL owner role does not exist: drupal_user"* ]] &&
     [[ "$(cat "$mock_log")" == "user_lookup" ]]; then
    echo "[PASS] Missing owner role prevents database creation"
else
    echo "[FAIL] Unexpected missing owner result"
    exit 1
fi

# Test 5: Owner lookup failure prevents database creation.

: > "$mock_log"

postgresql_user_exists() {
    echo "user_lookup" >> "$mock_log"
    return 2
}

if output="$(create_postgresql_database "drupal_db" "drupal_user")"; then
    echo "[FAIL] Database created after owner lookup failure"
    exit 1
elif [[ "$output" == *"[ERROR] PostgreSQL user lookup failed."* ]] &&
     [[ "$(cat "$mock_log")" == "user_lookup" ]]; then
    echo "[PASS] Owner lookup failure prevents database creation"
else
    echo "[FAIL] Unexpected owner lookup failure result"
    exit 1
fi

# Test 6: Existing database prevents creation.

: > "$mock_log"

postgresql_user_exists() {
    echo "user_lookup" >> "$mock_log"
    return 0
}

postgresql_database_exists() {
    echo "db_lookup" >> "$mock_log"
    return 0
}

expected_order="$(printf '%s\n' "user_lookup" "db_lookup")"

if output="$(create_postgresql_database "drupal_db" "drupal_user")"; then
    echo "[FAIL] Existing PostgreSQL database accepted"
    exit 1
elif [[ "$output" == *"[ERROR] PostgreSQL database already exists: drupal_db"* ]] &&
     [[ "$(cat "$mock_log")" == "$expected_order" ]]; then
    echo "[PASS] Existing PostgreSQL database prevents creation"
else
    echo "[FAIL] Unexpected existing database result"
    exit 1
fi

# Test 7: Database lookup failure prevents creation.

: > "$mock_log"

postgresql_database_exists() {
    echo "db_lookup" >> "$mock_log"
    return 2
}

if output="$(create_postgresql_database "drupal_db" "drupal_user")"; then
    echo "[FAIL] Database created after lookup failure"
    exit 1
elif [[ "$output" == *"[ERROR] PostgreSQL database lookup failed."* ]] &&
     [[ "$(cat "$mock_log")" == "$expected_order" ]]; then
    echo "[PASS] Database lookup failure prevents creation"
else
    echo "[FAIL] Unexpected database lookup failure result"
    exit 1
fi

# Test 8: Successful PostgreSQL database creation.

: > "$mock_log"

postgresql_database_exists() {
    echo "db_lookup" >> "$mock_log"
    return 1
}

sudo() {
    local sql
    sql="$(cat)"

    echo "create_db" >> "$mock_log"

    if [[ "$*" == "-u postgres psql -X -q -v ON_ERROR_STOP=1" ]] &&
       [[ "$sql" == *'\set db_name drupal_db'* ]] &&
       [[ "$sql" == *'\set db_owner drupal_user'* ]] &&
       [[ "$sql" == *"CREATE DATABASE %I OWNER %I ENCODING %L TEMPLATE template0"* ]]; then
        return 0
    fi

    return 1
}

expected_order="$(printf '%s\n' "user_lookup" "db_lookup" "create_db")"

if create_postgresql_database "drupal_db" "drupal_user" &&
   [[ "$(cat "$mock_log")" == "$expected_order" ]]; then
    echo "[PASS] PostgreSQL database creation executed correctly"
else
    echo "[FAIL] PostgreSQL database creation failed"
    exit 1
fi

# Test 9: CREATE DATABASE failure is reported.

: > "$mock_log"

sudo() {
    cat > /dev/null
    echo "create_db" >> "$mock_log"
    return 1
}

if output="$(create_postgresql_database "drupal_db" "drupal_user")"; then
    echo "[FAIL] PostgreSQL CREATE DATABASE failure ignored"
    exit 1
elif [[ "$output" == *"[ERROR] PostgreSQL database creation failed."* ]] &&
     [[ "$(cat "$mock_log")" == "$expected_order" ]]; then
    echo "[PASS] PostgreSQL CREATE DATABASE failure detected"
else
    echo "[FAIL] Unexpected CREATE DATABASE failure result"
    exit 1
fi

# Test 10: Invalid database name and owner are rejected before any lookup.

: > "$mock_log"

if create_postgresql_database "bad-name" "drupal_user" >/dev/null ||
   create_postgresql_database "drupal_db" "bad user" >/dev/null; then
    echo "[FAIL] Invalid PostgreSQL database input accepted"
    exit 1
elif [[ ! -s "$mock_log" ]]; then
    echo "[PASS] Invalid PostgreSQL database input rejected"
else
    echo "[FAIL] Lookup ran for invalid input"
    exit 1
fi

echo "[SUCCESS] PostgreSQL database tests passed."
