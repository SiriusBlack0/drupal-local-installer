#!/usr/bin/env bash

# ==================================================
# Project directory and Drupal code (Composer)
#
# Layout of a new project:
#   /var/www/<name>          owner: developer, group: www-data, mode 2750
#                            (setgid: new files keep the www-data group,
#                             so Nginx can read them; others have no access)
# Composer runs as the developer, with the PHP version chosen for the
# project, so dependencies are resolved for that PHP and never for the
# system default.
# ==================================================

check_project_directory() {
    local project_path="$1"

    if [ -e "$project_path" ] || [ -L "$project_path" ]; then
        echo "[ERROR] Project path already exists: $project_path"
        return 1
    fi

    echo "[OK] Project path is available: $project_path"
    return 0
}

# Accept only paths that get_project_path would produce:
# <projects base dir>/<valid machine name>. Protects mkdir and rm -rf.
is_managed_project_path() {
    local project_path="$1"
    local machine_name
    local expected_path

    machine_name="$(basename -- "$project_path")"
    expected_path="$(get_project_path "$machine_name" 2>/dev/null)" || return 1

    [[ "$project_path" == "$expected_path" ]]
}

# Runs a command as the developer who owns the project.
run_as_project_user() {
    local run_user="$1"
    shift

    if [[ "$(id -un)" == "$run_user" ]]; then
        "$@"
    else
        sudo -u "$run_user" -- "$@"
    fi
}

create_project_directory() {
    local project_path="$1"
    local run_user="$2"

    if ! is_managed_project_path "$project_path"; then
        echo "[ERROR] Refusing to create an unmanaged path: $project_path"
        return 1
    fi

    if [[ ! "$run_user" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        echo "[ERROR] Invalid project owner: $run_user"
        return 1
    fi

    if ! check_project_directory "$project_path"; then
        return 1
    fi

    if ! sudo install -d -o "$run_user" -g www-data -m 2750 "$project_path"; then
        echo "[ERROR] Could not create project directory: $project_path"
        return 1
    fi

    echo "[OK] Project directory created: $project_path (owner $run_user, group www-data)"
}

# Only used for rollback of a directory this installer just created.
remove_project_directory() {
    local project_path="$1"

    if ! is_managed_project_path "$project_path"; then
        echo "[ERROR] Refusing to remove an unmanaged path: $project_path"
        return 1
    fi

    sudo rm -rf -- "$project_path"
}

# True when the log lines written since line $1 show that Composer
# failed because of the network (not because of the project).
composer_failed_on_network() {
    local from_line="$1"

    [[ -n "${LOG_FILE:-}" && -f "$LOG_FILE" ]] || return 1

    tail -n "+$((from_line + 1))" "$LOG_FILE" |
        grep -qiE 'curl error|failed to download|could not resolve host|failed to connect|connection timed out|operation timed out|connection reset|network is unreachable'
}

# run_logged, and once more when the first attempt failed because of the
# network: a short network problem should not undo a whole run.
# $2 names a function that cleans up before the second attempt ("-" for
# none).
run_logged_retrying_network() {
    local description="$1"
    local cleanup="$2"
    shift 2
    local from_line=0

    [[ -n "${LOG_FILE:-}" && -f "$LOG_FILE" ]] && from_line="$(wc -l < "$LOG_FILE")"

    if run_logged "$description" "$@"; then
        return 0
    fi

    composer_failed_on_network "$from_line" || return 1

    echo "[RETRY] That was a network problem; trying once more in ${COMPOSER_RETRY_DELAY:-10} seconds..."
    sleep "${COMPOSER_RETRY_DELAY:-10}"

    if [[ "$cleanup" != "-" ]] && ! "$cleanup"; then
        return 1
    fi

    run_logged "$description (second attempt)" "$@"
}

# create-project needs an empty directory: a failed download may have
# left files in the project directory this run created.
empty_new_project_directory() {
    is_managed_project_path "$NEW_PROJECT_PATH" || return 1
    run_as_project_user "$NEW_PROJECT_USER" find "$NEW_PROJECT_PATH" -mindepth 1 -delete
}

create_drupal_project() {
    local drupal_version="$1"
    local project_path="$2"
    local php_version="$3"
    local run_user="$4"
    local composer_path

    if [[ ! "$drupal_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "[ERROR] Invalid Drupal version: $drupal_version"
        return 1
    fi

    if [[ ! "$php_version" =~ ^[0-9]+\.[0-9]+$ ]]; then
        echo "[ERROR] Invalid PHP version: $php_version"
        return 1
    fi

    if ! composer_path="$(command -v composer)"; then
        echo "[ERROR] Composer is not installed."
        return 1
    fi

    if ! command -v "php${php_version}" >/dev/null 2>&1; then
        echo "[ERROR] PHP ${php_version} CLI is not installed."
        return 1
    fi

    NEW_PROJECT_PATH="$project_path"
    NEW_PROJECT_USER="$run_user"

    run_logged_retrying_network "Downloading Drupal $drupal_version (PHP $php_version)" \
        empty_new_project_directory \
        run_as_project_user "$run_user" \
        "php${php_version}" "$composer_path" create-project \
        --no-interaction \
        "drupal/recommended-project:$drupal_version" \
        "$project_path"
}

# Adds Drush to the project with the project PHP. Composer chooses the
# Drush release that matches this Drupal core and PHP version.
install_drush() {
    local project_path="$1"
    local php_version="$2"
    local run_user="$3"
    local composer_path

    if ! composer_path="$(command -v composer)"; then
        echo "[ERROR] Composer is not installed."
        return 1
    fi

    run_logged_retrying_network "Adding Drush" - \
        run_as_project_user "$run_user" \
        "php${php_version}" "$composer_path" require \
        --no-interaction \
        --working-dir="$project_path" \
        drush/drush
}

# Writes a small launcher in the project root that always uses the
# project PHP, e.g. ./drush cr or ./composer update, so the system
# default PHP is never involved. Existing files are never replaced.
#
# Drush and Composer start helper scripts that call plain "php", so the
# launcher puts a per-project "php" (a link to the project PHP) first
# in PATH. This works however those helper scripts are written.
write_project_launcher() {
    local launcher_path="$1"
    local php_binary="$2"
    local command="$3"
    local run_user="$4"
    local extra_line="${5:-}"

    if [[ -e "$launcher_path" || -L "$launcher_path" ]]; then
        echo "[ERROR] File already exists: $launcher_path"
        return 1
    fi

    # Text between single quotes is written literally into the launcher.
    # shellcheck disable=SC2016
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        '# Generated by drupal-local-installer.' \
        '# Runs with the PHP version chosen for this project.' \
        "if [[ ! -x $php_binary ]]; then" \
        "    echo \"This project needs $php_binary, which is not installed on this system.\" >&2" \
        '    exit 1' \
        'fi' \
        'project_dir="$(dirname "$(readlink -f "$0")")"' \
        'export PATH="$project_dir/.drupal-local-installer/bin:$PATH"' \
        ${extra_line:+"$extra_line"} \
        "exec $command \"\$@\"" \
        | run_as_project_user "$run_user" tee "$launcher_path" > /dev/null &&
    run_as_project_user "$run_user" chmod 0750 "$launcher_path"
}

create_project_launchers() {
    local project_path="$1"
    local php_version="$2"
    local run_user="$3"
    local php_binary
    local composer_path
    local shim_dir="$project_path/.drupal-local-installer/bin"

    if ! php_binary="$(command -v "php${php_version}")" ||
       ! composer_path="$(command -v composer)"; then
        echo "[ERROR] PHP ${php_version} or Composer not found."
        return 1
    fi

    # Per-project "php" that points to the project PHP version.
    if ! run_as_project_user "$run_user" mkdir -p "$shim_dir" ||
       ! run_as_project_user "$run_user" ln -s "$php_binary" "$shim_dir/php"; then
        echo "[ERROR] Could not create the project PHP link in $shim_dir"
        return 1
    fi

    # Literal text: expanded when the launcher runs, not now.
    # shellcheck disable=SC2016
    local drush_command='"$project_dir/vendor/bin/drush"'
    local machine_name
    local drush_uri

    # The project URL lets Drush build correct links ("./drush user:login").
    # An environment variable is used because the drush/ config directory
    # name is taken by the ./drush launcher itself.
    machine_name="$(basename "$project_path")"

    if [[ ! "$machine_name" =~ ^[a-z0-9_]+$ ]]; then
        echo "[ERROR] Invalid project directory name: $machine_name"
        return 1
    fi

    drush_uri="export DRUSH_OPTIONS_URI=\"\${DRUSH_OPTIONS_URI:-http://$(get_project_nginx_domain "$machine_name")}\""

    write_project_launcher "$project_path/drush" "$php_binary" \
        "$drush_command" "$run_user" "$drush_uri" &&
    write_project_launcher "$project_path/composer" "$php_binary" \
        "$php_binary $composer_path" "$run_user" &&
    echo "[OK] Project launchers created: ./drush and ./composer (PHP $php_version)"
}

verify_drush() {
    local project_path="$1"
    local run_user="$2"
    local version

    # Exit code alone is not enough: check that Drush itself answered.
    if ! version="$(run_as_project_user "$run_user" "$project_path/drush" --version 2>&1)" ||
       [[ "$version" != *"Drush Commandline Tool"* ]]; then
        echo "[ERROR] Drush does not run correctly. Output:"
        printf '%s\n' "$version" | head -n 5
        return 1
    fi

    echo "[OK] $version"
}

# Writes ./start in the project root: starts the services the project
# needs (PHP-FPM of the project PHP, Nginx, the database server) and
# prints the project URL. Running services are left alone, so it is
# safe to run at any time. Nothing is ever stopped: other projects may
# use the same services.
create_start_script() {
    local project_path="$1"
    local php_version="$2"
    local database_engine="$3"
    local machine_name="$4"
    local run_user="$5"
    local start_path="$project_path/start"
    local database_service
    local services

    if [[ ! "$php_version" =~ ^[0-9]+\.[0-9]+$ ]] ||
       [[ ! "$machine_name" =~ ^[a-z0-9_]+$ ]] ||
       ! database_service="$(get_database_service_name "$database_engine")"; then
        echo "[ERROR] Invalid input for the start script."
        return 1
    fi

    if [[ -e "$start_path" || -L "$start_path" ]]; then
        echo "[ERROR] File already exists: $start_path"
        return 1
    fi

    services="php${php_version}-fpm nginx${database_service:+ $database_service}"

    # Text between single quotes is written literally into ./start.
    # shellcheck disable=SC2016
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        '# Generated by drupal-local-installer.' \
        '# Starts the services this project needs. Safe to run at any time:' \
        '# running services are left alone and nothing is ever stopped.' \
        '' \
        "services=($services)" \
        "site_config=/etc/nginx/sites-enabled/${machine_name}.conf" \
        "socket=$(get_project_php_fpm_socket "$machine_name" "$php_version")" \
        "fpm_service=php${php_version}-fpm" \
        "fpm_binary=php-fpm${php_version}" \
        "error_log=/var/log/nginx/${machine_name}.error.log" \
        'ipv6_flag=/proc/net/if_inet6' \
        "url=http://$(get_project_nginx_domain "$machine_name")" \
        '' \
        'has_systemd() { [[ -d /run/systemd/system ]]; }' \
        '' \
        'is_running() {' \
        '    if has_systemd; then systemctl is-active --quiet "$1"' \
        '    else service "$1" status > /dev/null 2>&1; fi' \
        '}' \
        '' \
        'start_service() {' \
        '    if has_systemd; then sudo systemctl start "$1"' \
        '    else sudo service "$1" start; fi' \
        '}' \
        '' \
        '# Reload, never restart: other projects keep running.' \
        'reload_service() {' \
        '    if has_systemd; then sudo systemctl reload "$1"' \
        '    else sudo service "$1" reload; fi' \
        '}' \
        '' \
        '# Before site:install Drupal redirects to install.php,' \
        '# afterwards it answers with "X-Generator: Drupal".' \
        '# Checked over IPv4, and over IPv6 when ::1 exists: browsers try it first.' \
        '# curl connects to the loopback address and sends the site name as' \
        '# "Host", so it works even where curl cannot resolve *.localhost.' \
        'is_drupal_answering() {' \
        '    local family' \
        '    local address' \
        '    for family in 4 6; do' \
        '        if [[ "$family" == 6 ]] && ! grep -qi "^0\{31\}1 " "$ipv6_flag" 2>/dev/null; then continue; fi' \
        '        address="127.0.0.1"' \
        '        if [[ "$family" == 6 ]]; then address="[::1]"; fi' \
        '        curl -sI --max-time 5 -H "Host: ${url#http://}" "http://$address/" 2>/dev/null |' \
        "            grep -qiE '^(x-generator: drupal|location: .*install\\.php)' || return 1" \
        '    done' \
        '}' \
        '' \
        'failed=()' \
        '' \
        'for service in "${services[@]}"; do' \
        '    if is_running "$service"; then' \
        '        echo "[RUNNING] $service"' \
        '    elif start_service "$service" > /dev/null && is_running "$service"; then' \
        '        echo "[STARTED] $service"' \
        '    else' \
        '        echo "[FAILED]  $service"' \
        '        failed+=("$service")' \
        '    fi' \
        'done' \
        '' \
        'echo' \
        '' \
        'if [[ "${#failed[@]}" -gt 0 ]]; then' \
        '    echo "Some services could not be started: ${failed[*]}" >&2' \
        '    if has_systemd; then' \
        '        echo "Details: sudo journalctl -u ${failed[0]} -n 30" >&2' \
        '    else' \
        '        echo "Details: sudo service ${failed[0]} status, and the logs in /var/log/" >&2' \
        '    fi' \
        '    exit 1' \
        'fi' \
        '' \
        'if [[ ! -e "$site_config" ]]; then' \
        '    echo "Services are running, but the Nginx site for this project is not set up yet."' \
        '    exit 0' \
        'fi' \
        '' \
        '# A pool added while PHP-FPM was already running is loaded on reload.' \
        'if [[ ! -S "$socket" ]]; then' \
        '    if sudo "$fpm_binary" -t > /dev/null 2>&1 &&' \
        '       reload_service "$fpm_service" > /dev/null; then' \
        '        sleep 1' \
        '    fi' \
        '    if [[ -S "$socket" ]]; then' \
        '        echo "[RELOADED] $fpm_service (loaded this project'"'"'s pool)"' \
        '    else' \
        '        echo "[FAILED]  $fpm_service: this project'"'"'s pool is not running ($socket)" >&2' \
        '        echo "Details: sudo $fpm_binary -t" >&2' \
        '        exit 1' \
        '    fi' \
        'fi' \
        '' \
        'if ! command -v curl > /dev/null; then' \
        '    echo "Project ready: $url (install curl to let ./start check it)"' \
        '    exit 0' \
        'fi' \
        '' \
        '# A site added while Nginx was already running is loaded on reload.' \
        'if ! is_drupal_answering; then' \
        '    if sudo nginx -t > /dev/null 2>&1 && reload_service nginx > /dev/null; then' \
        '        sleep 1' \
        '    fi' \
        '    if is_drupal_answering; then' \
        '        echo "[RELOADED] nginx (loaded this project'"'"'s site)"' \
        '    else' \
        '        echo "[FAILED]  $url does not answer as a Drupal site." >&2' \
        '        echo "Details: sudo nginx -t, and sudo tail $error_log" >&2' \
        '        exit 1' \
        '    fi' \
        'fi' \
        '' \
        'echo "Project ready: $url"' \
        | run_as_project_user "$run_user" tee "$start_path" > /dev/null &&
    run_as_project_user "$run_user" chmod 0750 "$start_path" &&
    echo "[OK] Start script created: ./start ($services)"
}

# Downloads Drupal with Composer into the (empty) project directory,
# adds Drush and the launchers, and checks that Drush runs.
#
# Composer runs "sudo -K" on every start: it deliberately forgets the
# cached sudo password so that scripts from downloaded packages cannot
# use it. All sudo work is therefore done before this step, and
# Composer and Drush only ever run as the project user.
install_drupal_codebase() {
    local drupal_version="$1"
    local project_path="$2"
    local php_version="$3"
    local run_user="$4"

    if ! create_drupal_project \
            "$drupal_version" "$project_path" "$php_version" "$run_user" ||
       ! install_drush "$project_path" "$php_version" "$run_user" ||
       ! create_project_launchers "$project_path" "$php_version" "$run_user" ||
       ! verify_drush "$project_path" "$run_user"; then
        echo "[ERROR] Drupal download failed."
        return 1
    fi

    echo "[SUCCESS] Drupal project files created."
}
