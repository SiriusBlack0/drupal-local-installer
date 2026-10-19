#!/usr/bin/env bash

# MariaDB / MySQL: database and user.

create_project_database() {
    local engine="$1"
    local database_name="$2"

    if [[ "$engine" != "mariadb" && "$engine" != "mysql" ]]; then
        echo "[ERROR] Unsupported database engine: $engine"
        return 1
    fi

    if ! is_valid_database_name "$database_name"; then
        echo "[ERROR] Invalid database name."
        return 1
    fi

    local database_lookup_status

    if database_exists "$database_name"; then
        database_lookup_status=0
    else
        database_lookup_status=$?
    fi

    case "$database_lookup_status" in
        0)
            echo "Database '$database_name' already exists."
            return 1
            ;;
        1)
            # Database does not exist. Creation can continue.
            ;;
        2)
            echo "[ERROR] Database lookup failed."
            return 1
            ;;
        *)
            echo "[ERROR] Unexpected database lookup status: $database_lookup_status"
            return 1
            ;;
    esac

    case "$engine" in
        mariadb|mysql)
            sudo mysql -e "CREATE DATABASE \`$database_name\`;"
            ;;
        *)
            echo "Unsupported database engine: $engine"
            return 1
            ;;
    esac
}

database_exists() {
    local database_name="$1"
    local result

    if ! result="$(sudo mysql -N -e \
        "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME = '$database_name';")"; then
        return 2
    fi

    if [[ "$result" == "$database_name" ]]; then
        return 0
    fi

    return 1
}

database_user_exists() {
    local database_user="$1"
    local result

    if ! result="$(sudo mysql -N -e \
        "SELECT User FROM mysql.user WHERE User = '$database_user';")"; then
        return 2
    fi

    if [[ "$result" == "$database_user" ]]; then
        return 0
    fi

    return 1
}

create_database_user() {
    local engine="$1"
    local database_user="$2"
    local database_password="$3"

    if [[ "$engine" != "mariadb" && "$engine" != "mysql" ]]; then
        echo "[ERROR] Unsupported database engine: $engine"
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

    local user_lookup_status

    if database_user_exists "$database_user"; then
        user_lookup_status=0
    else
        user_lookup_status=$?
    fi

    case "$user_lookup_status" in
        0)
            echo "Database user '$database_user' already exists."
            return 1
            ;;
        1)
            # User does not exist. Creation can continue.
            ;;
        2)
            echo "[ERROR] Database user lookup failed."
            return 1
            ;;
        *)
            echo "[ERROR] Unexpected database user lookup status: $user_lookup_status"
            return 1
            ;;
    esac

    case "$engine" in
        mariadb|mysql)
            printf "CREATE USER '%s'@'localhost' IDENTIFIED BY '%s';\n" \
                "$database_user" "$database_password" | sudo mysql
            ;;
        *)
            echo "Unsupported database engine: $engine"
            return 1
            ;;
    esac
}

grant_database_privileges() {
    local engine="$1"
    local database_name="$2"
    local database_user="$3"

    if [[ "$engine" != "mariadb" && "$engine" != "mysql" ]]; then
        echo "[ERROR] Unsupported database engine: $engine"
        return 1
    fi

    if ! is_valid_database_name "$database_name"; then
        echo "[ERROR] Invalid database name."
        return 1
    fi

    if ! is_valid_database_user "$database_user"; then
        echo "[ERROR] Invalid database username."
        return 1
    fi

    sudo mysql -e "GRANT ALL PRIVILEGES ON \`$database_name\`.* TO '$database_user'@'localhost';"
}
