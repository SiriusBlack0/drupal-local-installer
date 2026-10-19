#!/usr/bin/env bash

# Database engines (detection, versions, conflicts), names and
# credentials checks, and the per-engine dispatch (provision, remove).

get_installed_database_engines() {
    if dpkg-query -W -f='${db:Status-Abbrev}' mariadb-server 2>/dev/null \
        | grep -q '^ii'; then
        echo "mariadb"
    fi

    if dpkg-query -W -f='${db:Status-Abbrev}' mysql-server 2>/dev/null \
        | grep -q '^ii'; then
        echo "mysql"
    fi

    if dpkg-query -W -f='${db:Status-Abbrev}' postgresql 2>/dev/null \
        | grep -q '^ii'; then
        echo "postgresql"
    fi

    if is_database_engine_installed sqlite; then
        echo "sqlite"
    fi
}

get_installed_database_version() {

    local engine="$1"

    if ! is_database_engine_installed "$engine"; then
        return 1
    fi

    case "$engine" in
        mariadb)
            dpkg-query -W -f='${Version}\n' mariadb-server 2>/dev/null \
                | sed -E 's/^[0-9]+://' \
                | cut -d'-' -f1
            ;;

        mysql)
            dpkg-query -W -f='${Version}\n' mysql-server 2>/dev/null \
                | sed -E 's/^[0-9]+://' \
                | cut -d'-' -f1
            ;;

        sqlite)
            get_php_sqlite_version
            ;;

        *)
            return 1
            ;;
    esac
}

is_database_engine_installed() {
    local engine="$1"
    local package

    case "$engine" in
        mariadb)
            package="mariadb-server"
            ;;

        mysql)
            package="mysql-server"
            ;;

        postgresql)
            package="postgresql"
            ;;

        sqlite)
            get_php_sqlite_version >/dev/null
            return
            ;;

        *)
            return 1
            ;;
    esac

    dpkg-query -W -f='${db:Status-Abbrev}' "$package" 2>/dev/null \
        | grep -q '^ii'
}

get_available_database_version() {
    local engine="$1"
    local package

    case "$engine" in
        mariadb)
            package="mariadb-server"
            ;;

        mysql)
            package="mysql-server"
            ;;

        postgresql)
            apt-cache show postgresql 2>/dev/null \
                | awk '/^Depends:/ {
                    if (match($0, /postgresql-[0-9]+/)) {
                        version = substr($0, RSTART, RLENGTH)
                        sub(/^postgresql-/, "", version)
                        print version
                        exit
                    }
                }'
            return
            ;;

        sqlite)
            # Version PHP really uses; otherwise the SQLite library
            # that php-sqlite3 would be installed with.
            if get_php_sqlite_version; then
                return 0
            fi
            package="libsqlite3-0"
            ;;

        *)
            return 1
            ;;
    esac

    apt-cache policy "$package" 2>/dev/null \
        | awk '/Candidate:/ {print $2}' \
        | sed -E 's/^[0-9]+://' \
        | cut -d'-' -f1
}

get_database_engines() {
    printf '%s\n' \
        "mariadb" \
        "mysql" \
        "postgresql" \
        "sqlite"
}

# MariaDB and MySQL replace each other: the Ubuntu packages use the
# same port (3306), socket, /etc/mysql and /var/lib/mysql, so apt
# removes one when the other is installed.
get_conflicting_database_engine() {
    case "$1" in
        mariadb) echo "mysql" ;;
        mysql) echo "mariadb" ;;
        *) return 1 ;;
    esac
}

# Prints the installed engine that blocks installing this one.
get_installed_conflicting_engine() {
    local other

    other="$(get_conflicting_database_engine "$1")" || return 1
    is_database_engine_installed "$other" || return 1
    echo "$other"
}

# Ubuntu package that provides the database server.
get_database_server_package() {
    case "$1" in
        mariadb) echo "mariadb-server" ;;
        mysql) echo "mysql-server" ;;
        postgresql) echo "postgresql" ;;
        *) return 1 ;;
    esac
}

is_database_port_in_use() {
    ss -ltn 2>/dev/null \
        | awk '{print $4}' \
        | grep -Eq '(^|:)3306$'
}

get_active_database_engine() {
    if pgrep -x mariadbd >/dev/null 2>&1; then
        echo "mariadb"
        return 0
    fi

    if pgrep -x mysqld >/dev/null 2>&1; then
        echo "mysql"
        return 0
    fi

    return 1
}

has_database_engine_conflict() {
    local selected_engine="$1"
    local active_engine

    active_engine="$(get_active_database_engine)" || return 1

    if [ "$selected_engine" != "$active_engine" ] &&
       is_database_port_in_use; then
        return 0
    fi

    return 1
}

get_project_machine_name() {
    local project_name="$1"

    printf '%s\n' "$project_name" \
        | tr '[:upper:]' '[:lower:]' \
        | sed 's/[^a-z0-9_]/_/g'
}

get_project_database_name() {
    local project_name="$1"

    get_project_machine_name "$project_name"
}

get_project_database_user() {
    local project_name="$1"
    local database_name

    database_name="$(get_project_database_name "$project_name")"

    echo "${database_name}_user"
}

generate_database_password() {
    openssl rand -hex 16
}

is_valid_database_name() {
    local database_name="$1"

    [[ "$database_name" =~ ^[a-zA-Z0-9_]+$ ]]
}

is_valid_database_user() {
    local database_user="$1"

    [[ "$database_user" =~ ^[a-zA-Z0-9_]+$ ]]
}

# Removes a project database and its user (rollback, and later the
# "remove project" feature). SQLite lives inside the project directory,
# so there is nothing to remove here.
remove_project_database() {
    local engine="$1"
    local database_name="$2"
    local database_user="${3:-}"

    case "$engine" in
        mariadb|mysql)
            if ! is_valid_database_name "$database_name" ||
               ! is_valid_database_user "$database_user"; then
                echo "[ERROR] Invalid database name or user."
                return 1
            fi

            printf "DROP DATABASE IF EXISTS \`%s\`;\nDROP USER IF EXISTS '%s'@'localhost';\n" \
                "$database_name" "$database_user" | sudo mysql
            ;;
        postgresql)
            drop_postgresql_database "$database_name" &&
            drop_postgresql_user "$database_user"
            ;;
        sqlite)
            return 0
            ;;
        *)
            echo "[ERROR] Unsupported database engine: $engine"
            return 1
            ;;
    esac
}

is_valid_database_password() {
    local password="$1"

    [[ "$password" =~ ^[a-zA-Z0-9_@#%+=.-]+$ ]]
}

get_database_engine_status() {
    local engine="$1"
    local available_version

    if is_database_engine_installed "$engine"; then
        echo "installed"
        return 0
    fi

    available_version="$(get_available_database_version "$engine")"

    if [ -n "$available_version" ] &&
       [ "$available_version" != "(none)" ]; then
        echo "available"
        return 0
    fi

    echo "not_available"
}

provision_project_database() {
    local engine="$1"
    local database_name="$2"
    # SQLite passes only the engine and file path, so these are optional.
    local database_user="${3:-}"
    local database_password="${4:-}"

    case "$engine" in
        mariadb|mysql)
            # Continues below.
            ;;
        postgresql)
            provision_postgresql_database \
                "$database_name" \
                "$database_user" \
                "$database_password"
            return
            ;;
        sqlite)
            # For SQLite: second argument is the database file path,
            # third (optional) is the project owner.
            provision_sqlite_database "$database_name" "$database_user"
            return
            ;;
        *)
            echo "[ERROR] Unsupported database engine: $engine"
            return 1
            ;;
    esac

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

    local user_lookup_status

    if database_user_exists "$database_user"; then
        user_lookup_status=0
    else
        user_lookup_status=$?
    fi

    case "$user_lookup_status" in
        0)
            echo "[ERROR] Database user already exists: $database_user"
            return 1
            ;;
        1)
            # User does not exist. Provisioning can continue.
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

    if ! create_project_database "$engine" "$database_name"; then
        echo "[ERROR] Database creation failed."
        return 1
    fi

    if ! create_database_user "$engine" "$database_user" "$database_password"; then
        echo "[ERROR] Database user creation failed."
        return 1
    fi

    if ! grant_database_privileges "$engine" "$database_name" "$database_user"; then
        echo "[ERROR] Database privileges assignment failed."
        return 1
    fi

    echo "[SUCCESS] Database provisioning completed."
}
