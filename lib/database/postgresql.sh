#!/usr/bin/env bash

# PostgreSQL: user, database, extensions.

create_postgresql_user() {
    local database_user="$1"
    local database_password="$2"
    local lookup_status

    if ! is_valid_database_user "$database_user"; then
        echo "[ERROR] Invalid PostgreSQL username."
        return 1
    fi

    if ! is_valid_database_password "$database_password"; then
        echo "[ERROR] Invalid PostgreSQL password."
        return 1
    fi

    # Check whether the PostgreSQL user already exists.
    if postgresql_user_exists "$database_user"; then
        echo "[ERROR] PostgreSQL user already exists: $database_user"
        return 1
    else
        lookup_status=$?

        if [[ "$lookup_status" -ne 1 ]]; then
            echo "[ERROR] PostgreSQL user lookup failed."
            return 1
        fi
    fi

    # Create the PostgreSQL user without putting the password in process arguments.
    if ! {
        printf '\\set role_name %s\n' "$database_user"
        printf '\\set role_password %s\n' "$database_password"
        printf '%s\n' \
            "SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'role_name', :'role_password') \gexec"
    } | sudo -u postgres psql -X -q -v ON_ERROR_STOP=1; then
        echo "[ERROR] PostgreSQL user creation failed."
        return 1
    fi

    return 0
}

postgresql_user_exists() {
    local database_user="$1"
    local result

    if ! is_valid_database_user "$database_user"; then
        return 2
    fi

    if ! result="$(sudo -u postgres psql -X -t -A \
        -v ON_ERROR_STOP=1 \
        -v role_name="$database_user" <<'SQL'
SELECT 1 FROM pg_roles WHERE rolname = :'role_name';
SQL
)"; then
        return 2
    fi

    if [[ "$result" == "1" ]]; then
        return 0
    fi

    return 1
}

postgresql_database_exists() {
    local database_name="$1"
    local result

    if ! is_valid_database_name "$database_name"; then
        return 2
    fi

    if ! result="$(sudo -u postgres psql -X -t -A \
        -v ON_ERROR_STOP=1 \
        -v db_name="$database_name" <<'SQL'
SELECT 1 FROM pg_database WHERE datname = :'db_name';
SQL
)"; then
        return 2
    fi

    if [[ "$result" == "1" ]]; then
        return 0
    fi

    return 1
}

create_postgresql_database() {
    local database_name="$1"
    local database_owner="$2"
    local lookup_status

    if ! is_valid_database_name "$database_name"; then
        echo "[ERROR] Invalid PostgreSQL database name."
        return 1
    fi

    if ! is_valid_database_user "$database_owner"; then
        echo "[ERROR] Invalid PostgreSQL database owner."
        return 1
    fi

    # The owner role must already exist (CREATE ROLE runs first).
    if postgresql_user_exists "$database_owner"; then
        :
    else
        lookup_status=$?

        if [[ "$lookup_status" -eq 1 ]]; then
            echo "[ERROR] PostgreSQL owner role does not exist: $database_owner"
        else
            echo "[ERROR] PostgreSQL user lookup failed."
        fi

        return 1
    fi

    if postgresql_database_exists "$database_name"; then
        echo "[ERROR] PostgreSQL database already exists: $database_name"
        return 1
    else
        lookup_status=$?

        if [[ "$lookup_status" -ne 1 ]]; then
            echo "[ERROR] PostgreSQL database lookup failed."
            return 1
        fi
    fi

    # CREATE DATABASE cannot run inside a transaction block; psql runs
    # each \gexec statement in autocommit mode, which is what we need.
    # Drupal requires UTF8; template0 allows choosing the encoding.
    if ! {
        printf '\\set db_name %s\n' "$database_name"
        printf '\\set db_owner %s\n' "$database_owner"
        printf '%s\n' \
            "SELECT format('CREATE DATABASE %I OWNER %I ENCODING %L TEMPLATE template0', :'db_name', :'db_owner', 'UTF8') \gexec"
    } | sudo -u postgres psql -X -q -v ON_ERROR_STOP=1; then
        echo "[ERROR] PostgreSQL database creation failed."
        return 1
    fi

    return 0
}

drop_postgresql_user() {
    local database_user="$1"

    if ! is_valid_database_user "$database_user"; then
        echo "[ERROR] Invalid PostgreSQL username."
        return 1
    fi

    if ! {
        printf '\\set role_name %s\n' "$database_user"
        printf '%s\n' \
            "SELECT format('DROP ROLE IF EXISTS %I', :'role_name') \gexec"
    } | sudo -u postgres psql -X -q -v ON_ERROR_STOP=1; then
        echo "[ERROR] PostgreSQL user removal failed: $database_user"
        return 1
    fi

    return 0
}

drop_postgresql_database() {
    local database_name="$1"

    if ! is_valid_database_name "$database_name"; then
        echo "[ERROR] Invalid PostgreSQL database name."
        return 1
    fi

    if ! {
        printf '\\set db_name %s\n' "$database_name"
        printf '%s\n' \
            "SELECT format('DROP DATABASE IF EXISTS %I', :'db_name') \gexec"
    } | sudo -u postgres psql -X -q -v ON_ERROR_STOP=1; then
        echo "[ERROR] PostgreSQL database removal failed: $database_name"
        return 1
    fi

    return 0
}

# Extensions are per database, so this connects to the project database.
# Drupal 10, 11 and 12 require pg_trgm (drupal.org database requirements).
create_postgresql_extension() {
    local database_name="$1"
    local extension="$2"

    if ! is_valid_database_name "$database_name"; then
        echo "[ERROR] Invalid PostgreSQL database name."
        return 1
    fi

    # Strict whitelist: the name is placed directly in the SQL statement.
    if [[ ! "$extension" =~ ^[a-z0-9_]+$ ]]; then
        echo "[ERROR] Invalid PostgreSQL extension name."
        return 1
    fi

    if ! sudo -u postgres psql -X -q -v ON_ERROR_STOP=1 \
        -d "$database_name" \
        -c "CREATE EXTENSION IF NOT EXISTS ${extension};"; then
        echo "[ERROR] PostgreSQL extension creation failed: $extension"
        return 1
    fi

    return 0
}

# PostgreSQL order: CREATE ROLE -> CREATE DATABASE ... OWNER role
# -> CREATE EXTENSION pg_trgm. If a later step fails, everything created
# by this function is removed again, so a failed run leaves nothing behind.
provision_postgresql_database() {
    local database_name="$1"
    local database_user="$2"
    local database_password="$3"
    local lookup_status

    if ! is_valid_database_name "$database_name"; then
        echo "[ERROR] Invalid database name."
        return 1
    fi

    if ! is_valid_database_user "$database_user"; then
        echo "[ERROR] Invalid database username."
        return 1
    fi

    if ! is_valid_database_password "$database_password"; then
        echo "[ERROR] Invalid database password."
        return 1
    fi

    # Check both resources before creating anything.
    if postgresql_user_exists "$database_user"; then
        echo "[ERROR] PostgreSQL user already exists: $database_user"
        return 1
    else
        lookup_status=$?

        if [[ "$lookup_status" -ne 1 ]]; then
            echo "[ERROR] PostgreSQL user lookup failed."
            return 1
        fi
    fi

    if postgresql_database_exists "$database_name"; then
        echo "[ERROR] PostgreSQL database already exists: $database_name"
        return 1
    else
        lookup_status=$?

        if [[ "$lookup_status" -ne 1 ]]; then
            echo "[ERROR] PostgreSQL database lookup failed."
            return 1
        fi
    fi

    if ! create_postgresql_user "$database_user" "$database_password"; then
        echo "[ERROR] PostgreSQL provisioning failed at user creation."
        return 1
    fi

    if ! create_postgresql_database "$database_name" "$database_user"; then
        echo "[ERROR] PostgreSQL provisioning failed at database creation."
        echo "Rolling back: removing PostgreSQL user '$database_user'..."

        if drop_postgresql_user "$database_user"; then
            echo "[OK] Rollback completed."
        else
            echo "[WARNING] Rollback failed. Remove the user manually:"
            echo "  sudo -u postgres psql -c 'DROP ROLE \"$database_user\";'"
        fi

        return 1
    fi

    if ! create_postgresql_extension "$database_name" "pg_trgm"; then
        echo "[ERROR] PostgreSQL provisioning failed at extension setup."
        echo "Rolling back: removing database '$database_name' and user '$database_user'..."

        if drop_postgresql_database "$database_name" &&
           drop_postgresql_user "$database_user"; then
            echo "[OK] Rollback completed."
        else
            echo "[WARNING] Rollback failed. Remove them manually:"
            echo "  sudo -u postgres psql -c 'DROP DATABASE IF EXISTS \"$database_name\";'"
            echo "  sudo -u postgres psql -c 'DROP ROLE IF EXISTS \"$database_user\";'"
        fi

        return 1
    fi

    echo "[SUCCESS] PostgreSQL database provisioning completed."
}
