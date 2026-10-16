#!/usr/bin/env bash

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

# --------------------------------------------------
# SQLite as seen by PHP
# --------------------------------------------------

# Drupal does not use the sqlite3 command; it uses the SQLite library
# inside PHP's pdo_sqlite extension. Prints that library version for
# the selected PHP version, or fails if PHP or pdo_sqlite is missing.
# Requires PHP_VERSION (chosen before the database in the UI).
get_php_sqlite_version() {
    local php_version="${PHP_VERSION:-}"

    [[ "$php_version" =~ ^[0-9]+\.[0-9]+$ ]] || return 1
    command -v "php${php_version}" >/dev/null 2>&1 || return 1

    "php${php_version}" -r '
        if (!extension_loaded("pdo_sqlite")) {
            exit(1);
        }
        echo (new PDO("sqlite::memory:"))
            ->query("select sqlite_version()")
            ->fetchColumn(), PHP_EOL;
    ' 2>/dev/null
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

install_database_engine() {
    local engine="$1"
    local package

    case "$engine" in
        mariadb)
            package="mariadb-server"
            ;;
        mysql)
            package="mysql-server"
            ;;
        *)
            echo "Unsupported database engine: $engine"
            return 1
            ;;
    esac

    if is_database_engine_installed "$engine"; then
        echo "$engine is already installed."
        return 0
    fi

    echo "Installing $package..."

    sudo apt-get install -y "$package"
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

# --------------------------------------------------
# SQLite
# --------------------------------------------------

# The database file lives outside the web root (web/), so it can never
# be downloaded through Nginx. Drupal creates the file itself during
# site installation; we only prepare the directory.
get_sqlite_database_path() {
    local project_path="$1"

    if [[ "$project_path" != /* ]]; then
        echo "[ERROR] Project path must be absolute: $project_path" >&2
        return 1
    fi

    printf '%s/private/database.sqlite\n' "${project_path%/}"
}

is_valid_sqlite_database_path() {
    local database_path="$1"

    [[ "$database_path" =~ ^/[a-zA-Z0-9_./-]+\.sqlite$ ]] || return 1
    [[ "$database_path" != *"/../"* && "$database_path" != *"/./"* ]] || return 1
    [[ "$database_path" != *"/web/"* ]] || return 1
}

# Optional second argument: the project owner. When the installer runs
# as another user (started with sudo), the directory is handed to the
# owner, because PHP-FPM runs as the owner and must write the database.
provision_sqlite_database() {
    local database_path="$1"
    local owner="${2:-}"
    local database_dir

    if ! is_valid_sqlite_database_path "$database_path"; then
        echo "[ERROR] Invalid SQLite database path: $database_path"
        return 1
    fi

    if [[ -e "$database_path" || -L "$database_path" ]]; then
        echo "[ERROR] SQLite database already exists: $database_path"
        return 1
    fi

    database_dir="$(dirname "$database_path")"

    # No "mkdir -p": the project directory must already exist, so only
    # the final "private" directory is created, with mode 0700.
    if [[ ! -d "$database_dir" ]] && ! mkdir -m 0700 "$database_dir"; then
        echo "[ERROR] Could not create SQLite directory: $database_dir"
        return 1
    fi

    if [[ -n "$owner" && "$owner" != "$(id -un)" ]]; then
        if [[ ! "$owner" =~ ^[a-z_][a-z0-9_-]*$ ]] ||
           ! sudo chown "$owner" "$database_dir"; then
            echo "[ERROR] Could not give $database_dir to $owner"
            return 1
        fi

        echo "[SUCCESS] SQLite database directory ready: $database_dir (owner $owner)"
        return 0
    fi

    if [[ ! -w "$database_dir" ]]; then
        echo "[ERROR] SQLite directory is not writable: $database_dir"
        return 1
    fi

    echo "[SUCCESS] SQLite database directory ready: $database_dir"
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