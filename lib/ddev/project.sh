#!/usr/bin/env bash
# PROJECT_RUNTIME and REGISTRY_VALUES are read by install.sh and
# lib/registry.sh; PROJECT_PATH is set by lib/ui/project.sh.
# shellcheck disable=SC2034,SC2153

# ==================================================
# A new project with DDEV
#
# The same questions as a native project (name, Drupal, PHP, database,
# administrator, git), but PHP and the database run in DDEV's containers:
# nothing is installed on the system, no Nginx site, no PHP-FPM pool, no
# database on the system. Only the project folder needs sudo (in
# /var/www, like native projects). The administrator password goes
# through stdin, never in a command line or the log.
# ==================================================

# "native" or "ddev" (prompt_project_runtime).
PROJECT_RUNTIME="native"
# "mariadb:11.8", for ddev config --database.
DDEV_DATABASE=""

# DDEV's name for a project: a host name, so "_" becomes "-".
get_ddev_project_name() {
    printf '%s\n' "${1//_/-}"
}

# The project's URL through DDEV's router (its https port).
get_ddev_project_url() {
    local port

    port="$(get_ddev_global_value router_https_port)"

    if [[ -z "$port" || "$port" == "443" ]]; then
        printf 'https://%s.ddev.site\n' "$(get_ddev_project_name "$1")"
    else
        printf 'https://%s.ddev.site:%s\n' "$(get_ddev_project_name "$1")" "$port"
    fi
}

# The http address, for the installer's own check (no certificate).
get_ddev_project_http_port() {
    local port

    port="$(get_ddev_global_value router_http_port)"
    printf '%s\n' "${port:-80}"
}

# Native or DDEV. DDEV is offered only when the computer is ready for it
# (--ddev-setup); otherwise it is said how to get there.
prompt_project_runtime() {
    local choice

    PROJECT_RUNTIME="native"

    check_ddev_readiness > /dev/null 2>&1 || true

    if ! is_ddev_ready; then
        if command -v ddev > /dev/null 2>&1 || command -v docker > /dev/null 2>&1; then
            echo "DDEV projects: this computer is not ready yet (./install.sh --ddev-setup)."
            echo
        fi
        return 0
    fi

    while true; do
        echo "How should the project run?"
        echo "  1) Native: the system's PHP-FPM, Nginx and database (http://<name>.localhost)"
        echo "  2) DDEV:   containers with their own PHP and database"
        echo "             ($(get_ddev_project_url example | sed 's/example/<name>/'))"
        echo

        if ! read -r -p "Select [1-2, Enter = 1]: " choice; then
            echo
            echo "Input cancelled."
            exit 0
        fi

        case "$choice" in
            1|"") PROJECT_RUNTIME="native"; return 0 ;;
            2) PROJECT_RUNTIME="ddev"; return 0 ;;
            *) echo "Invalid selection." ;;
        esac
    done
}

# PHP for a DDEV project: every version the compatibility table allows
# for the Drupal release (DDEV has them all; nothing to install).
prompt_ddev_php_version() {
    local minor="${DRUPAL_VERSION%.*}"
    local choice
    local i
    local -a versions=()

    mapfile -t versions < <(get_supported_php_versions "$minor")

    if [[ "${#versions[@]}" -eq 0 ]]; then
        echo "[BLOCKED] Drupal $DRUPAL_VERSION is not in the compatibility table."
        exit 1
    fi

    while true; do
        echo
        echo "PHP versions for Drupal $minor (in the DDEV container):"

        for i in "${!versions[@]}"; do
            echo "$((i + 1))) PHP ${versions[$i]}"
        done

        echo
        if ! read -r -p "Select PHP version [Enter = ${versions[-1]}]: " choice; then
            echo "Input cancelled."
            exit 0
        fi

        [[ -z "$choice" ]] && choice="${#versions[@]}"

        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#versions[@]} )); then
            PHP_VERSION="${versions[$((choice - 1))]}"
            # shellcheck disable=SC2034  # Read by the summary.
            PHP_STATUS="in DDEV"
            return 0
        fi

        echo "Invalid selection. Try again."
    done
}

# The databases DDEV offers that this Drupal major supports, newest
# first: "engine|version|ddev type:version" lines.
get_ddev_database_options() {
    local major="${DRUPAL_VERSION%%.*}"
    local line
    local engine
    local version
    local minimum

    for line in "mariadb|11.8|mariadb:11.8" "mariadb|10.11|mariadb:10.11" \
                "mysql|8.4|mysql:8.4" "mysql|8.0|mysql:8.0" "postgresql|17|postgres:17" "postgresql|16|postgres:16"; do
        IFS='|' read -r engine version _ <<< "$line"
        minimum="$(get_database_minimum_version "$major" "$engine")" || continue
        version_at_least "$version" "$minimum" && printf '%s\n' "$line"
    done
}

prompt_ddev_database() {
    local choice
    local i
    local engine
    local version
    local -a options=()

    mapfile -t options < <(get_ddev_database_options)

    while true; do
        echo
        echo "Database (in its own DDEV container):"

        for i in "${!options[@]}"; do
            IFS='|' read -r engine version _ <<< "${options[$i]}"
            echo "$((i + 1))) $engine $version$([[ "$i" -eq 0 ]] && echo "  (DDEV's default)")"
        done

        echo
        if ! read -r -p "Select database [Enter = 1]: " choice; then
            echo "Input cancelled."
            exit 0
        fi

        [[ -z "$choice" ]] && choice=1

        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
            IFS='|' read -r DATABASE_ENGINE DATABASE_VERSION DDEV_DATABASE <<< "${options[$((choice - 1))]}"
            # shellcheck disable=SC2034  # Read by the summary and the registry.
            DATABASE_STATUS="in DDEV"
            return 0
        fi

        echo "Invalid selection. Try again."
    done
}

confirm_ddev_installation() {
    local choice

    while true; do
        echo
        echo "======================================"
        echo "        Project configuration (DDEV)"
        echo "======================================"
        echo
        echo "Project:  $PROJECT_NAME"
        echo "Machine:  $PROJECT_MACHINE_NAME"
        echo "Folder:   $PROJECT_PATH"
        echo "Drupal:   $DRUPAL_VERSION"
        echo "PHP:      $PHP_VERSION (DDEV container)"
        echo "Database: $DATABASE_ENGINE $DATABASE_VERSION (DDEV container)"
        echo "Site:     $(get_ddev_project_url "$PROJECT_MACHINE_NAME")"

        if [[ "$ADMIN_PASSWORD_GENERATED" -eq 1 ]]; then
            echo "Admin:    $ADMIN_USER (random password, shown at the end)"
        else
            echo "Admin:    $ADMIN_USER (your password)"
        fi

        if [[ "${GIT_SETUP:-no}" == "yes" ]]; then
            echo "Git:      git init + initial commit (.ddev/ included)"
        else
            echo "Git:      no repository"
        fi

        echo "System:   not changed (no packages, Nginx site, PHP-FPM pool or database)"
        echo
        echo "======================================"
        echo

        if ! read -r -p "Proceed with installation? [Y/n]: " choice; then
            echo
            echo "Input cancelled."
            exit 0
        fi

        case "$choice" in
            y|Y|"") return 0 ;;
            n|N) echo "Installation cancelled."; exit 0 ;;
            *) echo "Please enter y or n." ;;
        esac
    done
}

run_ddev_configuration_ui() {
    prompt_project_name
    prompt_drupal_version
    prompt_ddev_php_version
    prompt_ddev_database
    configure_admin_account
    prompt_git_setup
    confirm_ddev_installation
}

# --------------------------------------------------
# Installation
# --------------------------------------------------

DDEV_CREATED=()

# Runs a ddev command in the project folder, as the developer.
run_project_ddev() {
    local project_path="$1"
    shift

    (cd "$project_path" && run_as_developer ddev "$@")
}

# ./drush, ./composer and ./start: DDEV's commands from any folder.
write_ddev_launchers() {
    local project_path="$1"
    local name
    local command

    # Literal text: expanded when the launcher runs, not here.
    # shellcheck disable=SC2016
    for name in drush composer start; do
        [[ -e "$project_path/$name" || -L "$project_path/$name" ]] && continue

        case "$name" in
            drush) command='exec ddev drush "$@"' ;;
            composer) command='exec ddev composer "$@"' ;;
            start) command='ddev start && echo "Site: $(ddev describe -j 2>/dev/null | grep -o "\"primary_url\":\"[^\"]*" | cut -d\" -f4)"' ;;
        esac

        printf '%s\n' \
            '#!/usr/bin/env bash' \
            "# $name of this DDEV project (drupal-local-installer); works from any folder." \
            'cd "$(dirname "$(readlink -f "$0")")" || exit 1' \
            "$command" |
            run_as_project_user "$PROJECT_USER" tee "$project_path/$name" > /dev/null &&
        run_as_project_user "$PROJECT_USER" chmod 0755 "$project_path/$name" || return 1
    done

    echo "[OK] ./drush, ./composer and ./start (DDEV)"
}

# Drush bootstraps, and the site answers through DDEV's router as an
# installed Drupal site (http, resolved to this computer, so neither a
# certificate nor DNS is needed for the check).
verify_ddev_site() {
    local project_path="$1"
    local host
    local port
    local headers
    local bootstrap

    bootstrap="$(run_as_project_user "$PROJECT_USER" "$project_path/drush" status --field=bootstrap 2>/dev/null)" || true

    if [[ "$bootstrap" != *"Successful"* ]]; then
        echo "[ERROR] Drush cannot bootstrap the installed site."
        return 1
    fi

    host="$(get_ddev_project_name "$PROJECT_MACHINE_NAME").ddev.site"
    port="$(get_ddev_project_http_port)"
    headers="$(curl -sS -o /dev/null -D - --max-time 20 --resolve "$host:$port:127.0.0.1" "http://$host:$port/" 2>&1)" || true

    if ! grep -qi '^x-generator: drupal' <<< "$headers"; then
        echo "[ERROR] http://$host:$port does not answer as an installed Drupal site."
        log_line "DDEV site check failed. Headers:"$'\n'"${headers:-(none)}"
        return 1
    fi

    echo "[OK] Drupal site installed and answering: $(get_ddev_project_url "$PROJECT_MACHINE_NAME")"
}

# Writes stdin to file $1 as the developer, mode 600.
write_private_file() {
    # shellcheck disable=SC2016  # $1 of the small sh script.
    run_as_project_user "$PROJECT_USER" sh -c 'umask 077 && cat > "$1"' sh "$1"
}

# The administrator password for a DDEV project. It reaches the
# container through a file in the project folder (mode 600, removed right
# after), which the container sees mounted: never a command line, never
# the log, and no reliance on stdin passing through "ddev drush".
set_ddev_admin_password() {
    local project_path="$1"
    local password="$2"
    local dir="$project_path/.drupal-local-installer"
    local file="$dir/admin-password"
    local result

    # Single quotes: this is PHP code for Drush, not shell code.
    # shellcheck disable=SC2016
    local php_code='
$file = dirname(DRUPAL_ROOT) . "/.drupal-local-installer/admin-password";
$password = is_readable($file) ? rtrim(file_get_contents($file), "\n") : "";
if ($password === "") { echo "password-empty"; return; }
$storage = \Drupal::entityTypeManager()->getStorage("user");
$account = $storage->load(1);
$account->setPassword($password);
$account->save();
$account = $storage->loadUnchanged(1);
echo \Drupal::service("password")->check($password, $account->getPassword())
    ? "password-ok" : "password-mismatch";
'

    if ! run_as_project_user "$PROJECT_USER" mkdir -p -m 0700 "$dir" ||
       ! printf '%s' "$password" | write_private_file "$file"; then
        echo "[ERROR] The administrator password could not be handed over."
        return 1
    fi

    result="$(run_as_project_user "$PROJECT_USER" "$project_path/drush" php:eval "$php_code" 2>&1)" || true
    run_as_project_user "$PROJECT_USER" rm -f -- "$file"

    if [[ "$result" == *"password-ok"* ]]; then
        log_line "Administrator password replaced; the temporary one printed by site:install above no longer works."
        echo "[OK] Administrator password set"
        return 0
    fi

    log_line "Setting the administrator password failed: ${result//"$password"/***}"
    echo "[ERROR] The administrator password could not be set."
    return 1
}

# Takes away what this run made: the DDEV project (containers and its
# database volume, no snapshot), then the folder.
rollback_ddev_installation() {
    echo
    echo "Removing what was created..."

    if [[ " ${DDEV_CREATED[*]} " == *" ddev_project "* ]]; then
        if run_project_ddev "$PROJECT_PATH" delete --omit-snapshot --yes > /dev/null 2>&1; then
            echo "[OK] DDEV project removed (containers and database)"
        else
            echo "[WARNING] Remove it by hand: cd $PROJECT_PATH && ddev delete --omit-snapshot --yes"
        fi
    fi

    if [[ " ${DDEV_CREATED[*]} " == *" project_directory "* ]]; then
        if remove_project_directory "$PROJECT_PATH"; then
            echo "[OK] Removed $PROJECT_PATH"
        else
            echo "[WARNING] Remove it by hand: sudo rm -rf $PROJECT_PATH"
        fi
    fi
}

interrupt_ddev_installation() {
    trap '' INT TERM
    to_console
    echo
    echo "[INTERRUPTED] Stopping the installation."
    rollback_ddev_installation
    exit 130
}

run_ddev_installation_workflow() {
    local status=0

    DDEV_CREATED=()
    trap 'interrupt_ddev_installation' INT TERM
    perform_ddev_installation_workflow || status=$?
    trap - INT TERM

    return "$status"
}

perform_ddev_installation_workflow() {
    local project_type="drupal"
    local name

    name="$(get_ddev_project_name "$PROJECT_MACHINE_NAME")"

    case "${DRUPAL_VERSION%%.*}" in
        10|11|12) project_type="drupal${DRUPAL_VERSION%%.*}" ;;
    esac

    step "Creating the project directory"

    if ! create_project_directory "$PROJECT_PATH" "$PROJECT_USER"; then
        echo "[ERROR] Project directory creation failed."
        return 1
    fi

    DDEV_CREATED+=(project_directory)

    step "Configuring and starting DDEV"

    if ! run_logged "DDEV configuration (ddev config)" run_project_ddev "$PROJECT_PATH" config \
            --project-name="$name" --project-type="$project_type" --docroot=web \
            --php-version="$PHP_VERSION" --database="$DDEV_DATABASE"; then
        rollback_ddev_installation
        return 1
    fi

    DDEV_CREATED+=(ddev_project)

    if ! run_logged "Starting the containers (ddev start)" run_project_ddev "$PROJECT_PATH" start; then
        rollback_ddev_installation
        return 1
    fi

    step "Downloading Drupal"

    if ! run_logged_retrying_network "Downloading Drupal $DRUPAL_VERSION (ddev composer create-project)" - \
            run_project_ddev "$PROJECT_PATH" composer create-project --no-interaction \
            "drupal/recommended-project:$DRUPAL_VERSION" ||
       ! run_logged_retrying_network "Adding Drush" - \
            run_project_ddev "$PROJECT_PATH" composer require --no-interaction drush/drush; then
        echo "[ERROR] Drupal could not be downloaded."
        rollback_ddev_installation
        return 1
    fi

    if ! write_ddev_launchers "$PROJECT_PATH"; then
        echo "[ERROR] ./drush could not be written."
        rollback_ddev_installation
        return 1
    fi

    step "Installing the Drupal site"

    # DDEV wrote settings.php and settings.ddev.php (database of its
    # container) on ddev start; site:install uses them.
    if ! run_drupal_site_install "$PROJECT_PATH" "$PROJECT_USER" "$PROJECT_NAME" "$ADMIN_USER" "$ADMIN_MAIL" ||
       ! mask_temporary_password_in_log ||
       ! set_ddev_admin_password "$PROJECT_PATH" "$ADMIN_PASSWORD" ||
       ! verify_ddev_site "$PROJECT_PATH"; then
        echo "[ERROR] Drupal site installation failed."
        rollback_ddev_installation
        return 1
    fi

    step "Registry"

    # shellcheck disable=SC2034  # Read by write_project_record.
    declare -gA REGISTRY_VALUES
    REGISTRY_VALUES=(
        [runtime]="ddev" [url]="$(get_ddev_project_url "$PROJECT_MACHINE_NAME")"
        [database_name]="db" [database_user]="db" [sqlite_path]=""
        [php_fpm_pool]="" [php_fpm_socket]="" [nginx_available]="" [nginx_enabled]=""
    )

    if ! write_project_record; then
        echo "[WARNING] The project works, but it is not in the registry,"
        echo "          so it will not appear in ./install.sh --list."
    fi

    REGISTRY_VALUES=()

    if [[ "${GIT_SETUP:-no}" == "yes" ]]; then
        step "Git repository"

        # Files DDEV writes for this computer only.
        append_missing_lines "$PROJECT_PATH/.gitignore" "$PROJECT_USER" \
            "# Written by DDEV for this computer (drupal-local-installer)." \
            "/web/sites/*/settings.ddev.php" > /dev/null 2>&1 || true

        setup_project_git "$PROJECT_PATH" "$PROJECT_USER" \
            "Initial commit: Drupal $DRUPAL_VERSION project $PROJECT_MACHINE_NAME (DDEV)" |
            copy_to_log || true
    fi

    return 0
}

print_ddev_project_summary() {
    local url

    url="$(get_ddev_project_url "$PROJECT_MACHINE_NAME")"

    echo
    echo "======================================"
    echo "[DONE] $PROJECT_NAME is ready (DDEV)"
    echo "======================================"
    echo
    echo "Path:     $PROJECT_PATH"
    echo "Site:     $url"
    echo "Admin:    $url/user/login"
    echo "User:     $ADMIN_USER"

    if [[ "$ADMIN_PASSWORD_GENERATED" -eq 1 ]]; then
        echo "Password: $ADMIN_PASSWORD"
        echo
        echo "This password is shown only now and is not saved anywhere."
        echo "Store it in your password manager, or change it after logging in."
    else
        echo "Password: the one you entered"
    fi

    echo
    echo "In the project folder: ./drush, ./composer (in the container),"
    echo "./start after a reboot; DDEV's own: ddev describe, ddev stop, ddev logs."
    echo "Log in without the password: cd $PROJECT_PATH && ./drush user:login"
    echo
    echo "All your projects: ./install.sh --list"
    [[ -n "$LOG_FILE" ]] && echo "Log file: $LOG_FILE"
    echo "======================================"

    ADMIN_PASSWORD=""
}
