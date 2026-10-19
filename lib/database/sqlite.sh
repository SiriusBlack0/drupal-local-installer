#!/usr/bin/env bash

# SQLite: the PHP extension and the database file.

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
