#!/usr/bin/env bash
set -e

source lib/database.sh

# Safety guard: never execute real sudo commands in tests.
sudo() {
    echo "[ERROR] Unexpected sudo call during tests." >&2
    return 1
}

mock_log="$(mktemp)"
trap 'rm -f "$mock_log"' EXIT


database_exists() {
    echo "called" > "$mock_log"
    return 1
}

if output="$(create_project_database "mariadb" "invalid-name!")"; then
    echo "[FAIL] Invalid database name accepted"
    exit 1
else
    if [[ "$output" == *"[ERROR] Invalid database name."* ]] &&
       [[ ! -s "$mock_log" ]]; then
        echo "[PASS] Invalid database name rejected"
    else
        echo "[FAIL] Unexpected database validation result"
        exit 1
    fi
fi

# Test 2: Unsupported database engine.

: > "$mock_log"

if output="$(create_project_database "postgresql" "test_drupal")"; then
    echo "[FAIL] Unsupported database engine accepted"
    exit 1
else
    if [[ "$output" == *"[ERROR] Unsupported database engine: postgresql"* ]] &&
       [[ ! -s "$mock_log" ]]; then
        echo "[PASS] Unsupported database engine rejected"
    else
        echo "[FAIL] Unexpected database engine validation result"
        exit 1
    fi
fi

# Test 3: Existing database must be rejected.

: > "$mock_log"

database_exists() {
    echo "lookup" >> "$mock_log"
    return 0
}

if output="$(create_project_database "mariadb" "existing_drupal")"; then
    echo "[FAIL] Existing database accepted"
    exit 1
else
    if [[ "$output" == *"Database 'existing_drupal' already exists."* ]] &&
       [[ "$(cat "$mock_log")" == "lookup" ]]; then
        echo "[PASS] Existing database rejected"
    else
        echo "[FAIL] Unexpected existing database result"
        exit 1
    fi
fi

# Test 4: Successful database creation.

: > "$mock_log"

database_exists() {
    return 1
}

sudo() {
    printf '%s\n' "$*" >> "$mock_log"
    return 0
}

if create_project_database "mariadb" "new_drupal"; then
    expected_sql="mysql -e CREATE DATABASE \`new_drupal\`;"
    
    if [[ "$(cat "$mock_log")" == "$expected_sql" ]]; then
        echo "[PASS] Database creation SQL generated correctly"
    else
        echo "[FAIL] Unexpected database creation command"
        exit 1
    fi
else
    echo "[FAIL] Database creation failed"
    exit 1
fi

# Test 5: Database creation SQL failure.

: > "$mock_log"

sudo() {
    printf '%s\n' "$*" >> "$mock_log"
    return 1
}

if create_project_database "mariadb" "new_drupal"; then
    echo "[FAIL] Database creation failure ignored"
    exit 1
else
    if [[ "$(cat "$mock_log")" == "$expected_sql" ]]; then
        echo "[PASS] Database creation SQL failure detected"
    else
        echo "[FAIL] Unexpected SQL failure result"
        exit 1
    fi
fi

# Test 6: Invalid database username.

: > "$mock_log"

database_user_exists() {
    echo "lookup" >> "$mock_log"
    return 1
}

if output="$(create_database_user "mariadb" "invalid-user!" "TestPassword123")"; then
    echo "[FAIL] Invalid database username accepted"
    exit 1
else
    if [[ "$output" == *"[ERROR] Invalid database username."* ]] &&
       [[ ! -s "$mock_log" ]]; then
        echo "[PASS] Invalid database username rejected"
    else
        echo "[FAIL] Unexpected database username validation result"
        exit 1
    fi
fi

# Test 7: Invalid database password.

: > "$mock_log"

if output="$(create_database_user "mariadb" "drupal_user" "invalid'password")"; then
    echo "[FAIL] Invalid database password accepted"
    exit 1
else
    if [[ "$output" == *"[ERROR] Invalid database password."* ]] &&
       [[ ! -s "$mock_log" ]]; then
        echo "[PASS] Invalid database password rejected"
    else
        echo "[FAIL] Unexpected database password validation result"
        exit 1
    fi
fi

# Test 8: Existing database user.

: > "$mock_log"

database_user_exists() {
    echo "lookup" >> "$mock_log"
    return 0
}

if output="$(create_database_user "mariadb" "existing_user" "TestPassword123")"; then
    echo "[FAIL] Existing database user accepted"
    exit 1
else
    if [[ "$output" == *"Database user 'existing_user' already exists."* ]] &&
       [[ "$(cat "$mock_log")" == "lookup" ]]; then
        echo "[PASS] Existing database user rejected"
    else
        echo "[FAIL] Unexpected existing database user result"
        exit 1
    fi
fi

# Test 9: Successful database user creation.

: > "$mock_log"

database_user_exists() {
    return 1
}

sudo() {
    local sql

    sql="$(cat)"
    printf '%s\n' "$*" >> "$mock_log"
    printf '%s\n' "$sql" >> "$mock_log"

    return 0
}

if create_database_user "mariadb" "drupal_user" "TestPassword123"; then
    expected_sql="$(printf '%s\n' \
        "mysql" \
        "CREATE USER 'drupal_user'@'localhost' IDENTIFIED BY 'TestPassword123';")"

    if [[ "$(cat "$mock_log")" == "$expected_sql" ]]; then
        echo "[PASS] Database user creation SQL generated correctly"
    else
        echo "[FAIL] Unexpected database user creation command"
        exit 1
    fi
else
    echo "[FAIL] Database user creation failed"
    exit 1
fi

# Test 10: Database user creation SQL failure.

: > "$mock_log"

sudo() {
    local sql

    sql="$(cat)"
    printf '%s\n' "$*" >> "$mock_log"
    printf '%s\n' "$sql" >> "$mock_log"

    return 1
}

if create_database_user "mariadb" "drupal_user" "TestPassword123"; then
    echo "[FAIL] Database user creation failure ignored"
    exit 1
else
    if [[ "$(cat "$mock_log")" == "$expected_sql" ]]; then
        echo "[PASS] Database user creation SQL failure detected"
    else
        echo "[FAIL] Unexpected database user creation failure result"
        exit 1
    fi
fi

# Test 11: Invalid database name in GRANT.

: > "$mock_log"

sudo() {
    printf '%s\n' "$*" >> "$mock_log"
    return 0
}

if output="$(grant_database_privileges "mariadb" "invalid-name!" "drupal_user")"; then
    echo "[FAIL] Invalid database name accepted for GRANT"
    exit 1
else
    if [[ "$output" == *"[ERROR] Invalid database name."* ]] &&
       [[ ! -s "$mock_log" ]]; then
        echo "[PASS] Invalid database name rejected for GRANT"
    else
        echo "[FAIL] Unexpected GRANT validation result"
        exit 1
    fi
fi

# Test 12: Invalid database username in GRANT.

: > "$mock_log"

if output="$(grant_database_privileges "mariadb" "drupal_db" "invalid-user!")"; then
    echo "[FAIL] Invalid database username accepted for GRANT"
    exit 1
else
    if [[ "$output" == *"[ERROR] Invalid database username."* ]] &&
       [[ ! -s "$mock_log" ]]; then
        echo "[PASS] Invalid database username rejected for GRANT"
    else
        echo "[FAIL] Unexpected GRANT username validation result"
        exit 1
    fi
fi

# Test 13: Successful database privileges GRANT.

: > "$mock_log"

if grant_database_privileges "mariadb" "drupal_db" "drupal_user"; then
    expected_grant="mysql -e GRANT ALL PRIVILEGES ON \`drupal_db\`.* TO 'drupal_user'@'localhost';"

    if [[ "$(cat "$mock_log")" == "$expected_grant" ]]; then
        echo "[PASS] Database privileges GRANT SQL generated correctly"
    else
        echo "[FAIL] Unexpected GRANT SQL command"
        exit 1
    fi
else
    echo "[FAIL] Database privileges GRANT failed"
    exit 1
fi

# Test 14: Database privileges GRANT failure.

: > "$mock_log"

sudo() {
    printf '%s\n' "$*" >> "$mock_log"
    return 1
}

if grant_database_privileges "mariadb" "drupal_db" "drupal_user"; then
    echo "[FAIL] Database privileges GRANT failure ignored"
    exit 1
else
    if [[ "$(cat "$mock_log")" == "$expected_grant" ]]; then
        echo "[PASS] Database privileges GRANT failure detected"
    else
        echo "[FAIL] Unexpected GRANT failure result"
        exit 1
    fi
fi

# Test 15: Successful database provisioning workflow.

: > "$mock_log"

create_project_database() {
    echo "create_database" >> "$mock_log"
    return 0
}

create_database_user() {
    echo "create_user" >> "$mock_log"
    return 0
}

grant_database_privileges() {
    echo "grant_privileges" >> "$mock_log"
    return 0
}

if provision_project_database "mariadb" "drupal_db" "drupal_user" "TestPassword123"; then

    expected_order="$(printf '%s\n' \
        "create_database" \
        "create_user" \
        "grant_privileges")"

    if [[ "$(cat "$mock_log")" == "$expected_order" ]]; then
        echo "[PASS] Database provisioning workflow executed in correct order"
    else
        echo "[FAIL] Incorrect database provisioning order"
        exit 1
    fi

else
    echo "[FAIL] Database provisioning workflow failed"
    exit 1
fi

# Test 16: Database provisioning stops when database creation fails.

: > "$mock_log"

create_project_database() {
    echo "create_database" >> "$mock_log"
    return 1
}

if output="$(provision_project_database "mariadb" "drupal_db" "drupal_user" "TestPassword123")"; then
    echo "[FAIL] Provisioning continued after database creation failure"
    exit 1
else
    if [[ "$output" == *"[ERROR] Database creation failed."* ]] &&
       [[ "$(cat "$mock_log")" == "create_database" ]]; then
        echo "[PASS] Provisioning stops when database creation fails"
    else
        echo "[FAIL] Unexpected database provisioning failure result"
        exit 1
    fi
fi

# Test 17: Provisioning stops when user creation fails.

: > "$mock_log"

create_project_database() {
    echo "create_database" >> "$mock_log"
    return 0
}

create_database_user() {
    echo "create_user" >> "$mock_log"
    return 1
}

if output="$(provision_project_database "mariadb" "drupal_db" "drupal_user" "TestPassword123")"; then
    echo "[FAIL] Provisioning continued after user creation failure"
    exit 1
else
    expected_order="$(printf '%s\n' \
        "create_database" \
        "create_user")"

    if [[ "$output" == *"[ERROR] Database user creation failed."* ]] &&
       [[ "$(cat "$mock_log")" == "$expected_order" ]]; then
        echo "[PASS] Provisioning stops when user creation fails"
    else
        echo "[FAIL] Unexpected user creation failure result"
        exit 1
    fi
fi

# Test 18: Provisioning fails when GRANT fails.

: > "$mock_log"

create_database_user() {
    echo "create_user" >> "$mock_log"
    return 0
}

grant_database_privileges() {
    echo "grant_privileges" >> "$mock_log"
    return 1
}

if output="$(provision_project_database "mariadb" "drupal_db" "drupal_user" "TestPassword123")"; then
    echo "[FAIL] Provisioning ignored GRANT failure"
    exit 1
else
    expected_order="$(printf '%s\n' \
        "create_database" \
        "create_user" \
        "grant_privileges")"

    if [[ "$output" == *"[ERROR] Database privileges assignment failed."* ]] &&
       [[ "$(cat "$mock_log")" == "$expected_order" ]]; then
        echo "[PASS] Provisioning detects GRANT failure"
    else
        echo "[FAIL] Unexpected GRANT failure result"
        exit 1
    fi
fi

# Test 19: Invalid username stops provisioning before database creation.

: > "$mock_log"

if output="$(provision_project_database "mariadb" "drupal_db" "invalid-user!" "TestPassword123")"; then
    echo "[FAIL] Provisioning accepted invalid username"
    exit 1
else
    if [[ "$output" == *"[ERROR] Invalid database username."* ]] &&
       [[ ! -s "$mock_log" ]]; then
        echo "[PASS] Invalid username prevents database creation"
    else
        echo "[FAIL] Unexpected provisioning validation result"
        exit 1
    fi
fi

# Test 20: Existing user prevents database creation.

: > "$mock_log"

database_user_exists() {
    echo "user_lookup" >> "$mock_log"
    return 0
}

if output="$(provision_project_database "mariadb" "drupal_db" "existing_user" "TestPassword123")"; then
    echo "[FAIL] Provisioning accepted existing database user"
    exit 1
else
    if [[ "$output" == *"[ERROR] Database user already exists: existing_user"* ]] &&
       [[ "$(cat "$mock_log")" == "user_lookup" ]]; then
        echo "[PASS] Existing user prevents database creation"
    else
        echo "[FAIL] Unexpected existing user validation result"
        exit 1
    fi
fi

# Test 21: Database user lookup failure stops provisioning.

: > "$mock_log"

database_user_exists() {
    echo "user_lookup" >> "$mock_log"
    return 2
}

if output="$(provision_project_database "mariadb" "drupal_db" "drupal_user" "TestPassword123")"; then
    echo "[FAIL] Provisioning continued after database user lookup failure"
    exit 1
else
    if [[ "$output" == *"[ERROR] Database user lookup failed."* ]] &&
       [[ "$(cat "$mock_log")" == "user_lookup" ]]; then
        echo "[PASS] Database user lookup failure stops provisioning"
    else
        echo "[FAIL] Unexpected database user lookup failure result"
        exit 1
    fi
fi

# Restore the real implementation for Test 22.
source lib/database.sh

# Test 22: Database lookup failure prevents database creation.

: > "$mock_log"

database_exists() {
    echo "database_lookup" >> "$mock_log"
    return 2
}

sudo() {
    echo "sudo_called" >> "$mock_log"
    return 0
}

if output="$(create_project_database "mariadb" "drupal_db")"; then
    echo "[FAIL] Database creation continued after lookup failure"
    exit 1
else
    if [[ "$output" == *"[ERROR] Database lookup failed."* ]] &&
       [[ "$(cat "$mock_log")" == "database_lookup" ]]; then
        echo "[PASS] Database lookup failure prevents creation"
    else
        echo "[FAIL] Unexpected database lookup failure result"
        exit 1
    fi
fi

# Test 23: User lookup failure prevents CREATE USER.

: > "$mock_log"

database_user_exists() {
    echo "user_lookup" >> "$mock_log"
    return 2
}

sudo() {
    echo "sudo_called" >> "$mock_log"
    return 0
}

if output="$(create_database_user "mariadb" "drupal_user" "TestPassword123")"; then
    echo "[FAIL] User creation continued after lookup failure"
    exit 1
else
    if [[ "$output" == *"[ERROR] Database user lookup failed."* ]] &&
       [[ "$(cat "$mock_log")" == "user_lookup" ]]; then
        echo "[PASS] User lookup failure prevents CREATE USER"
    else
        echo "[FAIL] Unexpected user lookup failure result"
        exit 1
    fi
fi

# Test 24: PostgreSQL user exists.

: > "$mock_log"

sudo() {
    local sql
    sql="$(cat)"

    echo "$*" >> "$mock_log"
    echo "$sql" >> "$mock_log"

    echo "1"
    return 0
}

if postgresql_user_exists "drupal_user"; then
    echo "[PASS] PostgreSQL existing user detected"
else
    echo "[FAIL] PostgreSQL existing user not detected"
    exit 1
fi

# Test 25: PostgreSQL user does not exist.

: > "$mock_log"

sudo() {
    echo "sudo_called" >> "$mock_log"

    # PostgreSQL returns no rows.
    return 0
}

if postgresql_user_exists "missing_user"; then
    echo "[FAIL] Non-existing PostgreSQL user detected"
    exit 1
else
    status=$?

    if [[ "$status" -eq 1 ]] &&
       [[ "$(cat "$mock_log")" == "sudo_called" ]]; then
        echo "[PASS] Non-existing PostgreSQL user correctly detected"
    else
        echo "[FAIL] Unexpected PostgreSQL user lookup result: $status"
        exit 1
    fi
fi

# Test 26: PostgreSQL user lookup failure.

: > "$mock_log"

sudo() {
    echo "sudo_called" >> "$mock_log"
    return 1
}

if postgresql_user_exists "drupal_user"; then
    echo "[FAIL] PostgreSQL lookup failure ignored"
    exit 1
else
    status=$?

    if [[ "$status" -eq 2 ]] &&
       [[ "$(cat "$mock_log")" == "sudo_called" ]]; then
        echo "[PASS] PostgreSQL user lookup failure detected"
    else
        echo "[FAIL] Unexpected PostgreSQL lookup status: $status"
        exit 1
    fi
fi

# Test 27: Existing PostgreSQL user prevents role creation.

: > "$mock_log"

postgresql_user_exists() {
    echo "user_lookup" >> "$mock_log"
    return 0
}

sudo() {
    echo "sudo_called" >> "$mock_log"
    return 0
}

if output="$(create_postgresql_user "existing_user" "TestPassword123")"; then
    echo "[FAIL] Existing PostgreSQL user accepted"
    exit 1
else
    if [[ "$output" == *"[ERROR] PostgreSQL user already exists: existing_user"* ]] &&
       [[ "$(cat "$mock_log")" == "user_lookup" ]]; then
        echo "[PASS] Existing PostgreSQL user prevents role creation"
    else
        echo "[FAIL] Unexpected PostgreSQL role creation result"
        exit 1
    fi
fi

# Test 28: PostgreSQL lookup failure prevents role creation.

: > "$mock_log"

postgresql_user_exists() {
    echo "user_lookup" >> "$mock_log"
    return 2
}

sudo() {
    echo "sudo_called" >> "$mock_log"
    return 0
}

if output="$(create_postgresql_user "drupal_user" "TestPassword123")"; then
    echo "[FAIL] PostgreSQL role creation continued after lookup failure"
    exit 1
else
    if [[ "$output" == *"[ERROR] PostgreSQL user lookup failed."* ]] &&
       [[ "$(cat "$mock_log")" == "user_lookup" ]]; then
        echo "[PASS] PostgreSQL lookup failure prevents role creation"
    else
        echo "[FAIL] Unexpected PostgreSQL lookup failure result"
        exit 1
    fi
fi

# Test 29: Successful PostgreSQL role creation.

: > "$mock_log"

postgresql_user_exists() {
    echo "user_lookup" >> "$mock_log"
    return 1
}

sudo() {
    local sql
    sql="$(cat)"

    echo "create_role" >> "$mock_log"

    if [[ "$*" == "-u postgres psql -X -q -v ON_ERROR_STOP=1" ]] &&
       [[ "$sql" == *'\set role_name drupal_user'* ]] &&
       [[ "$sql" == *'\set role_password TestPassword123'* ]] &&
       [[ "$sql" == *"CREATE ROLE %I LOGIN PASSWORD %L"* ]]; then
        return 0
    fi

    return 1
}

if create_postgresql_user "drupal_user" "TestPassword123"; then
    expected_order="$(printf '%s\n' \
        "user_lookup" \
        "create_role")"

    if [[ "$(cat "$mock_log")" == "$expected_order" ]]; then
        echo "[PASS] PostgreSQL role creation executed correctly"
    else
        echo "[FAIL] Incorrect PostgreSQL role creation order"
        exit 1
    fi
else
    echo "[FAIL] PostgreSQL role creation failed"
    exit 1
fi

# Test 30: PostgreSQL CREATE ROLE failure.

: > "$mock_log"

postgresql_user_exists() {
    echo "user_lookup" >> "$mock_log"
    return 1
}

sudo() {
    local sql
    sql="$(cat)"

    echo "create_role" >> "$mock_log"
    return 1
}

if output="$(create_postgresql_user "drupal_user" "TestPassword123")"; then
    echo "[FAIL] PostgreSQL CREATE ROLE failure ignored"
    exit 1
else
    expected_order="$(printf '%s\n' \
        "user_lookup" \
        "create_role")"

    if [[ "$output" == *"[ERROR] PostgreSQL user creation failed."* ]] &&
       [[ "$(cat "$mock_log")" == "$expected_order" ]]; then
        echo "[PASS] PostgreSQL CREATE ROLE failure detected"
    else
        echo "[FAIL] Unexpected PostgreSQL CREATE ROLE failure result"
        exit 1
    fi
fi