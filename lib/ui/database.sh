#!/usr/bin/env bash

# Phase 1: choosing the database and its credentials.

# --------------------------------------------------
# Database compatibility

# --------------------------------------------------

detect_compatible_databases() {
    echo
    echo "Detecting compatible databases..."

    DRUPAL_MAJOR="${DRUPAL_VERSION%%.*}"

    mapfile -t DATABASE_OPTIONS < <(
        get_compatible_database_options "$DRUPAL_MAJOR"
    )

    if [ "${#DATABASE_OPTIONS[@]}" -eq 0 ]; then
        echo "No compatible database options were found."
        exit 1
    fi

    # Every option is listed, but some cannot be chosen.
    if ! printf '%s\n' "${DATABASE_OPTIONS[@]}" | grep -qE '\|(installed|available)$'; then
        printf '%s\n' "${DATABASE_OPTIONS[@]}" | while IFS='|' read -r engine version status; do
            echo "  - $engine $version: $status"
        done
        echo
        echo "No database on this system can be used for Drupal $DRUPAL_MAJOR."
        print_container_hint
        exit 1
    fi
}

# Shown when the chosen database would replace the installed one.
explain_database_conflict() {
    local engine="$1"
    local version="$2"
    local installed
    local short_version

    installed="$(get_conflicting_database_engine "$engine")"
    short_version="$(echo "$version" | cut -d. -f1,2)"

    echo
    echo "[NOT POSSIBLE] $engine cannot be installed next to the installed $installed."
    echo
    echo "Both use the same port (3306), socket, configuration (/etc/mysql)"
    echo "and data directory (/var/lib/mysql). Installing $engine would remove"
    echo "$installed and break every project that uses it."
    echo
    echo "What you can do:"
    echo "  1. Use $installed for this project. Drupal supports both with the"
    echo "     same code, so this is fine for most local work."
    echo "  2. Need $engine exactly (for example the same as production)?"
    echo "     Use a container-based setup: DDEV (Docker) runs every project"
    echo "     with its own database type and version, next to this system:"
    echo "       ddev config --database=$engine:$short_version"
    echo "     Supported versions: https://docs.ddev.com/en/stable/users/extend/database-types/"
    echo
    echo "Choose another database."
}

# DDEV image name of each engine.
get_ddev_database_type() {
    case "$1" in
        postgresql) echo "postgres" ;;
        *) echo "$1" ;;
    esac
}

# Shown when the system version is older than this Drupal release needs.
explain_database_too_old() {
    local engine="$1"
    local version="$2"
    local minimum
    local older_major
    local older_minimum

    minimum="$(get_database_minimum_version "$DRUPAL_MAJOR" "$engine")"

    echo
    echo "[TOO OLD] This system provides $engine $version; Drupal $DRUPAL_MAJOR needs $minimum or newer."
    echo
    echo "What you can do:"

    case "$engine" in
        postgresql)
            echo "  - Install a newer PostgreSQL from the official PostgreSQL apt"
            echo "    repository (https://www.postgresql.org/download/linux/ubuntu/)."
            echo "    The installer does not add package sources for you."
            ;;
        sqlite)
            echo "  - SQLite is part of the system and of its PHP packages; a newer"
            echo "    version comes with a newer Ubuntu release."
            ;;
        *)
            echo "  - A newer $engine comes with a newer Ubuntu release or from the"
            echo "    vendor's own apt repository."
            ;;
    esac

    echo "  - Use another database from the list."

    if [[ "$engine" == "sqlite" ]]; then
        echo "  - Use a container-based setup such as DDEV (Docker) with a server"
        echo "    database, e.g.  ddev config --database=mariadb:11.8"
    else
        echo "  - Use a container-based setup such as DDEV (Docker):"
        echo "      ddev config --database=$(get_ddev_database_type "$engine"):$minimum"
    fi

    # An older Drupal major that accepts this version, if there is one.
    older_major=$((DRUPAL_MAJOR - 1))

    if older_minimum="$(get_database_minimum_version "$older_major" "$engine" 2>/dev/null)" &&
       [[ -n "$older_minimum" ]] &&
       database_version_meets_minimum "$version" "$older_minimum"; then
        echo "  - Choose Drupal $older_major instead: it supports $engine $older_minimum and newer."
    fi

    echo
    echo "Choose another database."
}

prompt_database_selection() {
    while true; do
        echo
        echo "Compatible databases:"
        echo

        for i in "${!DATABASE_OPTIONS[@]}"; do
            IFS='|' read -r engine version status <<< "${DATABASE_OPTIONS[$i]}"

            case "$status" in
                conflict)
                    status="conflicts with installed $(get_conflicting_database_engine "$engine")"
                    ;;
                too_old)
                    status="too old: Drupal $DRUPAL_MAJOR needs $(get_database_minimum_version "$DRUPAL_MAJOR" "$engine")+"
                    ;;
            esac

            echo "$((i + 1))) $engine $version [$status]"
        done

        echo

        if ! read -r -p "Select database: " DATABASE_CHOICE; then
            echo "Input cancelled."
            exit 0
        fi

        if ! [[ "$DATABASE_CHOICE" =~ ^[0-9]+$ ]] ||
           (( DATABASE_CHOICE < 1 ||
              DATABASE_CHOICE > ${#DATABASE_OPTIONS[@]} )); then
            echo "Invalid selection. Try again."
            continue
        fi

        IFS='|' read -r \
            DATABASE_ENGINE \
            DATABASE_VERSION \
            DATABASE_STATUS \
            <<< "${DATABASE_OPTIONS[$((DATABASE_CHOICE - 1))]}"

        if [[ "$DATABASE_STATUS" == "conflict" ]]; then
            explain_database_conflict "$DATABASE_ENGINE" "$DATABASE_VERSION"
            continue
        fi

        if [[ "$DATABASE_STATUS" == "too_old" ]]; then
            explain_database_too_old "$DATABASE_ENGINE" "$DATABASE_VERSION"
            continue
        fi

        break
    done
}


# --------------------------------------------------

# Database installation state

#

# PHASE 1 only records whether the selected database

# engine still needs to be installed.

# No installation or conflict checks happen here.

# --------------------------------------------------


# shellcheck disable=SC2034  # DATABASE_NEEDS_INSTALL is used by lib/preflight.sh
determine_database_install_need() {
    DATABASE_NEEDS_INSTALL="no"

    if [ "$DATABASE_STATUS" != "installed" ]; then
        DATABASE_NEEDS_INSTALL="yes"
    fi
}


# --------------------------------------------------

# Database name

# --------------------------------------------------


configure_sqlite_database() {
    DATABASE_NAME=""
    DATABASE_USER=""
    DATABASE_PASSWORD=""
    # Read in lib/ui/confirm.sh, lib/workflow.sh, lib/site.sh, lib/registry.sh.
    # shellcheck disable=SC2034
    if ! SQLITE_DATABASE_PATH="$(get_sqlite_database_path "$PROJECT_PATH")"; then
        echo "Installation stopped."
        exit 1
    fi

    echo
    echo "SQLite selected."
    echo "SQLite does not require a database server, user, or password."
}

prompt_database_name() {
    SUGGESTED_DATABASE_NAME="$(
        get_project_database_name "$PROJECT_NAME"
    )"

    while true; do
        echo
        echo "Database name:"
        echo
        echo "1) Use suggested name: $SUGGESTED_DATABASE_NAME"
        echo "2) Enter custom database name"
        echo

        if ! read -r -p "Select [1-2]: " DATABASE_NAME_CHOICE; then
            echo "Input cancelled."
            exit 0
        fi

        case "$DATABASE_NAME_CHOICE" in
            1)
                DATABASE_NAME="$SUGGESTED_DATABASE_NAME"
                break
                ;;
            2)
                if ! read -r -p "Enter database name: " DATABASE_NAME; then
                    echo "Input cancelled."
                    exit 0
                fi

                if ! is_valid_database_name "$DATABASE_NAME"; then
                    echo "Invalid database name."
                    echo "Use only letters, numbers and underscores."
                    continue
                fi

                break
                ;;
            *)
                echo "Invalid selection. Please choose 1 or 2."
                ;;
        esac
    done
}


# --------------------------------------------------

# Database user

# --------------------------------------------------


prompt_database_user() {
    SUGGESTED_DATABASE_USER="$(
        get_project_database_user "$PROJECT_NAME"
    )"

    while true; do
        echo
        echo "Database user:"
        echo
        echo "1) Use suggested user: $SUGGESTED_DATABASE_USER"
        echo "2) Enter custom database user"
        echo

        if ! read -r -p "Select [1-2]: " DATABASE_USER_CHOICE; then
            echo "Input cancelled."
            exit 0
        fi

        case "$DATABASE_USER_CHOICE" in
            1)
                DATABASE_USER="$SUGGESTED_DATABASE_USER"
                break
                ;;

            2)
                if ! read -r -p "Enter database user: " DATABASE_USER; then
                    echo "Input cancelled."
                    exit 0
                fi

                if ! is_valid_database_user "$DATABASE_USER"; then
                    echo "Invalid database user."
                    echo "Use only letters, numbers and underscores."
                    continue
                fi

                break
                ;;

            *)
                echo "Invalid selection. Please choose 1 or 2."
                ;;
        esac
    done
}


# --------------------------------------------------

# Database password

# --------------------------------------------------

prompt_database_password() {
    while true; do
        echo

        if ! read -r -s -p "Database password: " DATABASE_PASSWORD; then
            echo
            echo "Input cancelled."
            exit 0
        fi
        echo

        if [ -z "$DATABASE_PASSWORD" ]; then
            echo "Database password cannot be empty."
            continue
        fi

        if ! is_valid_database_password "$DATABASE_PASSWORD"; then
            echo "Invalid database password."
            echo "Use only letters, numbers and these characters: _ @ # % + = . -"
            continue
        fi

        if ! read -r -s -p "Confirm database password: " DATABASE_PASSWORD_CONFIRM; then
            echo
            echo "Input cancelled."
            exit 0
        fi
        echo

        if [ "$DATABASE_PASSWORD" != "$DATABASE_PASSWORD_CONFIRM" ]; then
            echo "Passwords do not match. Try again."
            continue
        fi

        break
    done
}

# --------------------------------------------------
# Database credentials (name, user, password or SQLite file)
# --------------------------------------------------

configure_database_credentials() {
    if [ "$DATABASE_ENGINE" = "sqlite" ]; then
        configure_sqlite_database
        return
    fi

    prompt_database_name
    prompt_database_user
    prompt_database_password
}
