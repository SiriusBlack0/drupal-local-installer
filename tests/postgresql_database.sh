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

# Test 11: DROP ROLE command for rollback.

: > "$mock_log"

sudo() {
    local sql
    sql="$(cat)"

    echo "drop_role" >> "$mock_log"

    [[ "$*" == "-u postgres psql -X -q -v ON_ERROR_STOP=1" ]] &&
    [[ "$sql" == *'\set role_name drupal_user'* ]] &&
    [[ "$sql" == *"DROP ROLE IF EXISTS %I"* ]]
}

if drop_postgresql_user "drupal_user" &&
   [[ "$(cat "$mock_log")" == "drop_role" ]]; then
    echo "[PASS] PostgreSQL DROP ROLE executed correctly"
else
    echo "[FAIL] PostgreSQL DROP ROLE incorrect"
    exit 1
fi

# Test 12: Invalid username never reaches DROP ROLE.

: > "$mock_log"

if drop_postgresql_user "bad user" >/dev/null; then
    echo "[FAIL] Invalid username accepted for DROP ROLE"
    exit 1
elif [[ ! -s "$mock_log" ]]; then
    echo "[PASS] Invalid username rejected for DROP ROLE"
else
    echo "[FAIL] DROP ROLE ran for invalid username"
    exit 1
fi

# Mocks for the high-level provisioning tests.
# MOCK_* variables choose the outcome of each step.

postgresql_user_exists() {
    echo "user_lookup" >> "$mock_log"
    return "${MOCK_USER_LOOKUP:-1}"
}

postgresql_database_exists() {
    echo "db_lookup" >> "$mock_log"
    return "${MOCK_DB_LOOKUP:-1}"
}

create_postgresql_user() {
    echo "create_role $1" >> "$mock_log"
    return "${MOCK_CREATE_ROLE:-0}"
}

create_postgresql_database() {
    echo "create_db $1 $2" >> "$mock_log"
    return "${MOCK_CREATE_DB:-0}"
}

drop_postgresql_user() {
    echo "drop_role $1" >> "$mock_log"
    return "${MOCK_DROP_ROLE:-0}"
}

run_provision() {
    : > "$mock_log"
    output="$(provision_postgresql_database "drupal_db" "drupal_user" "TestPassword123")"
}

log_is() {
    [[ "$(cat "$mock_log")" == "$(printf '%s\n' "$@")" ]]
}

# Test 13: Successful provisioning order.

if run_provision &&
   log_is "user_lookup" "db_lookup" "create_role drupal_user" "create_db drupal_db drupal_user" &&
   [[ "$output" == *"[SUCCESS] PostgreSQL database provisioning completed."* ]]; then
    echo "[PASS] PostgreSQL provisioning runs role then database"
else
    echo "[FAIL] PostgreSQL provisioning order incorrect"
    exit 1
fi

# Test 14: Existing user stops provisioning before anything is created.

if MOCK_USER_LOOKUP=0 run_provision; then
    echo "[FAIL] Provisioning continued with existing user"
    exit 1
elif log_is "user_lookup" &&
     [[ "$output" == *"[ERROR] PostgreSQL user already exists: drupal_user"* ]]; then
    echo "[PASS] Existing user stops provisioning"
else
    echo "[FAIL] Unexpected existing user result"
    exit 1
fi

# Test 15: Existing database stops provisioning before the role is created.

if MOCK_DB_LOOKUP=0 run_provision; then
    echo "[FAIL] Provisioning continued with existing database"
    exit 1
elif log_is "user_lookup" "db_lookup" &&
     [[ "$output" == *"[ERROR] PostgreSQL database already exists: drupal_db"* ]]; then
    echo "[PASS] Existing database stops provisioning before role creation"
else
    echo "[FAIL] Unexpected existing database result"
    exit 1
fi

# Test 16: Role creation failure stops provisioning, nothing to roll back.

if MOCK_CREATE_ROLE=1 run_provision; then
    echo "[FAIL] Role creation failure ignored"
    exit 1
elif log_is "user_lookup" "db_lookup" "create_role drupal_user"; then
    echo "[PASS] Role creation failure stops provisioning"
else
    echo "[FAIL] Unexpected role creation failure result"
    exit 1
fi

# Test 17: Database creation failure rolls back the role.

if MOCK_CREATE_DB=1 run_provision; then
    echo "[FAIL] Database creation failure ignored"
    exit 1
elif log_is "user_lookup" "db_lookup" "create_role drupal_user" \
            "create_db drupal_db drupal_user" "drop_role drupal_user" &&
     [[ "$output" == *"[OK] Rollback completed."* ]] &&
     [[ "$output" != *"TestPassword123"* ]]; then
    echo "[PASS] Database creation failure removes the created role"
else
    echo "[FAIL] Rollback after database failure incorrect"
    exit 1
fi

# Test 18: Failed rollback tells the user how to clean up.

if MOCK_CREATE_DB=1 MOCK_DROP_ROLE=1 run_provision; then
    echo "[FAIL] Failed rollback reported success"
    exit 1
elif [[ "$output" == *"[WARNING] Rollback failed."* ]] &&
     [[ "$output" == *'DROP ROLE "drupal_user"'* ]]; then
    echo "[PASS] Failed rollback shows manual cleanup command"
else
    echo "[FAIL] Unexpected failed rollback result"
    exit 1
fi

# Test 19: Dispatcher sends PostgreSQL to the PostgreSQL provisioning.

provision_postgresql_database() {
    echo "pg_provision $1 $2" >> "$mock_log"
    return 0
}

: > "$mock_log"

if provision_project_database "postgresql" "drupal_db" "drupal_user" "TestPassword123" &&
   log_is "pg_provision drupal_db drupal_user"; then
    echo "[PASS] Dispatcher routes PostgreSQL provisioning"
else
    echo "[FAIL] Dispatcher did not route PostgreSQL"
    exit 1
fi

# Test 20: Dispatcher rejects unknown engines.

: > "$mock_log"

if output="$(provision_project_database "oracle" "drupal_db" "drupal_user" "TestPassword123")"; then
    echo "[FAIL] Unknown engine accepted"
    exit 1
elif [[ "$output" == *"[ERROR] Unsupported database engine: oracle"* ]] &&
     [[ ! -s "$mock_log" ]]; then
    echo "[PASS] Dispatcher rejects unknown engine"
else
    echo "[FAIL] Unexpected unknown engine result"
    exit 1
fi

echo "[SUCCESS] PostgreSQL database tests passed."
