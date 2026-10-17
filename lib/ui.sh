#!/usr/bin/env bash

# ==================================================

# PHASE 1 — CONFIGURATION

# ==================================================



# --------------------------------------------------
# Project name
# --------------------------------------------------

prompt_project_name() {
    local conflict

    PROJECT_NAME_PATTERN='^[a-zA-Z0-9][a-zA-Z0-9 _-]*$'

    while true; do

        if ! read -r -p "Project name: " PROJECT_NAME; then
            echo "Input cancelled."
            exit 0
        fi

        if [ -z "$PROJECT_NAME" ]; then
            echo "Project name cannot be empty."
            continue
        fi

        if ! [[ "$PROJECT_NAME" =~ $PROJECT_NAME_PATTERN ]]; then
            echo "Invalid project name."
            echo "Use Latin letters, numbers, spaces, underscores or hyphens."
            echo "The name must start with a letter or number."
            continue
        fi

        PROJECT_MACHINE_NAME="$(get_project_machine_name "$PROJECT_NAME")"

        # shellcheck disable=SC2034  # Used by lib/preflight.sh and lib/workflow.sh
        if ! PROJECT_PATH="$(get_project_path "$PROJECT_MACHINE_NAME")"; then
            echo "Installation stopped."
            exit 1
        fi

        # Catch existing projects now, not after all other questions.
        # Preflight checks again later, in case something changed.
        if conflict="$(get_project_conflict "$PROJECT_MACHINE_NAME" "$PROJECT_PATH")"; then
            echo "$conflict"
            echo "Choose another project name."
            continue
        fi

        break

    done
}


# --------------------------------------------------

# Drupal version selection
# --------------------------------------------------

read_drupal_input() {
    local prompt="$1"
    local variable="$2"
    local input

    if ! IFS= read -r -p "$prompt" input; then
        echo "Input cancelled."
        exit 0
    fi

    printf -v "$variable" '%s' "$input"
}

select_drupal_latest() {
    echo

    echo "Detecting latest Drupal version..."



    DRUPAL_VERSION="$(

        get_drupal_versions 11 | head -n 1

    )"



    if [ -z "$DRUPAL_VERSION" ]; then

        echo "Could not determine latest Drupal version."

        exit 1

    fi
}

select_drupal_major_minor_patch() {
    # ------------------------------------------

    # Major version

    # ------------------------------------------



    while true; do



        echo

        echo "Select Drupal major version:"

        echo

        echo "1) Drupal 11"

        echo "2) Drupal 10"

        echo



        read_drupal_input "Select [1-2]: " DRUPAL_CHOICE



        case "$DRUPAL_CHOICE" in

            1)

                DRUPAL_MAJOR="11"

                break

                ;;

            2)

                DRUPAL_MAJOR="10"

                break

                ;;

            *)

                echo "Invalid selection. Please choose 1 or 2."

                ;;

        esac



    done





    # ------------------------------------------

    # Minor version

    # ------------------------------------------



    mapfile -t DRUPAL_MINORS < <(

        get_drupal_minor_versions "$DRUPAL_MAJOR"

    )



    if [ "${#DRUPAL_MINORS[@]}" -eq 0 ]; then

        echo "No Drupal releases found."

        exit 1

    fi



    while true; do



        echo

        echo "Available Drupal $DRUPAL_MAJOR releases:"

        echo



        for i in "${!DRUPAL_MINORS[@]}"; do

            echo "$((i + 1))) ${DRUPAL_MINORS[$i]}"

        done



        echo

        read_drupal_input "Select release: " MINOR_CHOICE



        if ! [[ "$MINOR_CHOICE" =~ ^[0-9]+$ ]] ||

           (( MINOR_CHOICE < 1 ||

              MINOR_CHOICE > ${#DRUPAL_MINORS[@]} )); then



            echo "Invalid selection. Try again."

            continue



        fi



        DRUPAL_MINOR="${DRUPAL_MINORS[$((MINOR_CHOICE - 1))]}"

        break



    done





    # ------------------------------------------

    # Patch version

    # ------------------------------------------



    mapfile -t DRUPAL_PATCHES < <(

        get_drupal_versions "$DRUPAL_MAJOR" |

        grep "^${DRUPAL_MINOR}\\."

    )



    if [ "${#DRUPAL_PATCHES[@]}" -eq 0 ]; then

        echo "No patch releases found for Drupal $DRUPAL_MINOR."

        exit 1

    fi



    while true; do



        echo

        echo "Available Drupal $DRUPAL_MINOR versions:"

        echo



        echo "1) Latest (${DRUPAL_PATCHES[0]})"



        for i in "${!DRUPAL_PATCHES[@]}"; do

            echo "$((i + 2))) ${DRUPAL_PATCHES[$i]}"

        done



        echo

        read_drupal_input "Select version: " PATCH_CHOICE



        if ! [[ "$PATCH_CHOICE" =~ ^[0-9]+$ ]]; then

            echo "Invalid selection. Try again."

            continue

        fi



        if [ "$PATCH_CHOICE" -eq 1 ]; then



            DRUPAL_VERSION="${DRUPAL_PATCHES[0]}"

            break



        elif (( PATCH_CHOICE >= 2 &&

                PATCH_CHOICE <= ${#DRUPAL_PATCHES[@]} + 1 )); then



            DRUPAL_VERSION="${DRUPAL_PATCHES[$((PATCH_CHOICE - 2))]}"

            break



        else



            echo "Invalid selection. Try again."



        fi



    done
}

select_drupal_exact() {
    while true; do



        echo

        read_drupal_input "Enter Drupal version (example 11.0.11): " DRUPAL_VERSION



        if ! [[ "$DRUPAL_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then

            echo "Invalid Drupal version format."

            continue

        fi



        echo

        echo "Checking Drupal $DRUPAL_VERSION..."



        if drupal_version_exists "$DRUPAL_VERSION"; then

            echo "Drupal $DRUPAL_VERSION exists."

            break

        fi



        echo "Drupal $DRUPAL_VERSION does not exist."



    done
}

prompt_drupal_version() {
    while true; do



        echo

        echo "Select Drupal version:"

        echo

        echo "1) Latest stable"

        echo "2) Choose major / minor / patch"

        echo "3) Enter exact version"

        echo



        read_drupal_input "Select [1-3]: " VERSION_MODE



        case "$VERSION_MODE" in



            1)
                select_drupal_latest
                break
                ;;

            2)
                select_drupal_major_minor_patch
                break
                ;;

            3)
                select_drupal_exact
                break
                ;;

            *)

                echo "Invalid selection. Please choose 1, 2 or 3."

                ;;



        esac



    done
}


# --------------------------------------------------

# PHP compatibility

# --------------------------------------------------

detect_php_requirements() {
    echo "Detecting PHP requirements..."



    PHP_CONSTRAINT="$(get_drupal_php_constraint "$DRUPAL_VERSION")"



    if [ -z "$PHP_CONSTRAINT" ]; then

        echo "Could not determine PHP requirements for Drupal $DRUPAL_VERSION."

        exit 1

    fi



    DRUPAL_MINOR="$(get_drupal_minor "$DRUPAL_VERSION")"
}

# Shown when the host system cannot run the requested setup.
print_container_hint() {
    echo
    echo "Best practice: a container-based setup (Docker, for example DDEV)"
    echo "runs each project with its own PHP and database versions,"
    echo "without changing the packages of this system."
}

# PHP versions come from config/compatibility.conf (via
# get_supported_php_versions). All supported versions are listed with
# their status; versions that are not available cannot be selected.
resolve_compatible_php_versions() {
    local version
    local found_versions
    local usable_count=0
    local -a required_versions=()

    if ! has_php_support_policy "$DRUPAL_MINOR"; then
        echo
        echo "[UNSUPPORTED] Drupal $DRUPAL_MINOR is not supported by this installer."
        echo "Supported Drupal releases: $(get_supported_drupal_minors | paste -sd ' ' -)"
        echo "Older releases no longer receive security fixes."
        echo "For a new project, choose the latest release of a supported version."
        print_container_hint
        return 1
    fi

    mapfile -t required_versions < <(get_supported_php_versions "$DRUPAL_MINOR")

    PHP_VERSIONS=("${required_versions[@]}")

    for version in "${required_versions[@]}"; do
        if [ "$(get_php_version_status "$version")" != "not_available" ]; then
            usable_count=$((usable_count + 1))
        fi
    done

    echo
    echo "Drupal $DRUPAL_VERSION supports PHP: ${required_versions[*]}"

    if [ "$usable_count" -eq 0 ]; then
        found_versions="$(get_php_candidate_versions | paste -sd ' ' -)"

        echo
        echo "[BLOCKED] No supported PHP version is installed or available."
        echo "Required PHP version(s): ${required_versions[*]}"
        echo "PHP versions on this system or in its package sources: ${found_versions:-none}"
        echo
        echo "Install one of the required PHP versions first."
        echo "This installer does not add package sources automatically."
        print_container_hint
        return 1
    fi
}

# Called when the chosen Drupal release cannot be installed here.
# The user decides what happens next.
choose_after_blocked() {
    local choice

    while true; do
        echo
        echo "What would you like to do?"
        echo
        echo "1) Choose another Drupal version"
        echo "2) Cancel installation"
        echo

        if ! read -r -p "Select [1-2]: " choice; then
            echo
            echo "Input cancelled."
            exit 0
        fi

        case "$choice" in
            1)
                return 0
                ;;
            2)
                echo "Installation cancelled."
                exit 0
                ;;
            *)
                echo "Invalid selection. Please choose 1 or 2."
                ;;
        esac
    done
}

# Supported PHP versions (from PHP_VERSIONS) that this system can
# actually provide right now: installed or installable via apt.
get_usable_php_versions() {
    local version

    for version in "${PHP_VERSIONS[@]}"; do
        if [ "$(get_php_version_status "$version")" != "not_available" ]; then
            printf '%s\n' "$version"
        fi
    done
}

prompt_php_version() {
    while true; do



        echo

        echo "Compatible PHP versions:"

        echo



        for i in "${!PHP_VERSIONS[@]}"; do

            php_version="${PHP_VERSIONS[$i]}"
            php_status="$(get_php_version_status "$php_version")"

            echo "$((i + 1))) PHP $php_version [$php_status]"

        done



        echo

        if ! read -r -p "Select PHP version: " PHP_CHOICE; then
            echo "Input cancelled."
            exit 0
        fi



        if ! [[ "$PHP_CHOICE" =~ ^[0-9]+$ ]] ||

           (( PHP_CHOICE < 1 ||

              PHP_CHOICE > ${#PHP_VERSIONS[@]} )); then



            echo "Invalid selection. Try again."

            continue



        fi



        PHP_VERSION="${PHP_VERSIONS[$((PHP_CHOICE - 1))]}"
        PHP_STATUS="$(get_php_version_status "$PHP_VERSION")"

        if [ "$PHP_STATUS" = "not_available" ]; then
            echo
            echo "[NOT AVAILABLE] PHP $PHP_VERSION is not installed and not available"
            echo "from the package sources of this system."
            echo "Usable for Drupal $DRUPAL_VERSION on this system: $(get_usable_php_versions | paste -sd ' ' -)"
            continue
        fi

        break

    done


    # --------------------------------------------------
}

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
}

prompt_database_selection() {
    while true; do
        echo
        echo "Compatible databases:"
        echo

        for i in "${!DATABASE_OPTIONS[@]}"; do
            IFS='|' read -r engine version status <<< "${DATABASE_OPTIONS[$i]}"
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

# --------------------------------------------------
# Drupal administrator account
# --------------------------------------------------

# Used by lib/workflow.sh and install.sh.
# shellcheck disable=SC2034
ADMIN_USER="admin"
# shellcheck disable=SC2034
ADMIN_MAIL="admin@example.com"
ADMIN_PASSWORD=""
ADMIN_PASSWORD_GENERATED=0

# 20 letters and digits: strong, and easy to copy from the terminal.
generate_admin_password() {
    local password=""

    while [[ "${#password}" -lt 20 ]]; do
        password+="$(openssl rand -base64 30 | tr -dc 'A-Za-z0-9')"
    done

    printf '%s\n' "${password:0:20}"
}

prompt_admin_password() {
    local confirm

    while true; do
        echo

        if ! IFS= read -r -s -p "Administrator password: " ADMIN_PASSWORD; then
            echo
            echo "Input cancelled."
            exit 0
        fi
        echo

        if [[ "${#ADMIN_PASSWORD}" -lt 8 ]]; then
            echo "Use at least 8 characters."
            continue
        fi

        if ! IFS= read -r -s -p "Confirm administrator password: " confirm; then
            echo
            echo "Input cancelled."
            exit 0
        fi
        echo

        if [[ "$ADMIN_PASSWORD" != "$confirm" ]]; then
            echo "Passwords do not match. Try again."
            continue
        fi

        break
    done
}

configure_admin_account() {
    local choice

    while true; do
        echo
        echo "Drupal administrator password (user: $ADMIN_USER):"
        echo
        echo "1) Generate a strong random password (shown once at the end)"
        echo "2) Enter my own password"
        echo

        if ! read -r -p "Select [1-2]: " choice; then
            echo
            echo "Input cancelled."
            exit 0
        fi

        case "$choice" in
            1)
                ADMIN_PASSWORD="$(generate_admin_password)"
                ADMIN_PASSWORD_GENERATED=1
                return 0
                ;;
            2)
                prompt_admin_password
                ADMIN_PASSWORD_GENERATED=0
                return 0
                ;;
            *)
                echo "Invalid selection."
                ;;
        esac
    done
}

# --------------------------------------------------
# Final configuration summary
# --------------------------------------------------

confirm_installation() {
    while true; do
        echo
        echo "======================================"
        echo "        Project configuration"
        echo "======================================"
        echo
        echo "Project:  $PROJECT_NAME"
        echo "Machine:  $PROJECT_MACHINE_NAME"
        echo "Drupal:   $DRUPAL_VERSION"
        echo "PHP:      $PHP_VERSION [$PHP_STATUS]"
        echo "Database: $DATABASE_ENGINE $DATABASE_VERSION [$DATABASE_STATUS]"

        if [ "$DATABASE_ENGINE" = "sqlite" ]; then
            echo "DB File:  $SQLITE_DATABASE_PATH"
        else
            echo "DB Name:  $DATABASE_NAME"
            echo "DB User:  $DATABASE_USER"
        fi

        if [[ "$ADMIN_PASSWORD_GENERATED" -eq 1 ]]; then
            echo "Admin:    $ADMIN_USER (random password, shown at the end)"
        else
            echo "Admin:    $ADMIN_USER (your password)"
        fi

        echo
        echo "======================================"
        echo

        if ! read -r -p "Proceed with installation? [Y/n]: " PROCEED_CHOICE; then
            echo
            echo "Input cancelled."
            exit 0
        fi

        case "$PROCEED_CHOICE" in
            y|Y|"")
                break
                ;;
            n|N)
                echo "Installation cancelled."
                exit 0
                ;;
            *)
                echo "Please enter y or n."
                ;;
        esac
    done
}

# ==================================================
# Phase 1 entry point
# ==================================================

# Asks every configuration question in order.
# Sourcing this file only defines functions; nothing runs until
# install.sh calls run_configuration_ui.
run_configuration_ui() {
    prompt_project_name

    # Repeat the version choice until the system can run it,
    # or until the user cancels.
    while true; do
        prompt_drupal_version

        echo
        detect_php_requirements

        if resolve_compatible_php_versions; then
            break
        fi

        choose_after_blocked
    done

    prompt_php_version

    echo
    detect_compatible_databases
    prompt_database_selection
    determine_database_install_need

    configure_database_credentials
    configure_admin_account
    confirm_installation
}
