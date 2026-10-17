#!/usr/bin/env bash

# ==================================================
# Drupal site installation (drush site:install)
#
# Secrets never appear in a command line, where any local user could
# read them with "ps", and never in the log:
# - the database password is written into settings.php through stdin;
# - the administrator password is passed to Drush through stdin.
# ==================================================

DRUPAL_INSTALL_PROFILE="standard"

# Escapes a value for a single-quoted PHP string.
escape_php_string() {
    local value="$1"

    value="${value//\\/\\\\}"
    value="${value//\'/\\\'}"
    printf '%s' "$value"
}

# PHP namespace of the core database driver (Drupal 10.4+ / 11).
get_drupal_database_driver() {
    case "$1" in
        mariadb|mysql) echo "mysql" ;;
        postgresql) echo "pgsql" ;;
        sqlite) echo "sqlite" ;;
        *) return 1 ;;
    esac
}

# Prints the settings.php block for the project.
# Arguments: machine_name engine database user password sqlite_path
generate_drupal_settings() {
    local machine_name="$1"
    local engine="$2"
    local database_name="$3"
    local database_user="$4"
    local database_password="$5"
    local sqlite_path="$6"
    local driver
    local domain_pattern

    if [[ ! "$machine_name" =~ ^[a-z0-9_]+$ ]] ||
       ! driver="$(get_drupal_database_driver "$engine")"; then
        echo "[ERROR] Invalid project name or database engine." >&2
        return 1
    fi

    domain_pattern="^${machine_name}\\.localhost\$"

    printf '%s\n' \
        '' \
        '// ------------------------------------------------------------' \
        '// Added by drupal-local-installer.' \
        '// ------------------------------------------------------------' \
        "\$databases['default']['default'] = ["

    case "$driver" in
        sqlite)
            if [[ ! "$sqlite_path" =~ ^/[a-zA-Z0-9_./-]+$ || "$sqlite_path" == *".."* ]]; then
                echo "[ERROR] Invalid SQLite path: $sqlite_path" >&2
                return 1
            fi

            printf '%s\n' \
                "  'driver' => 'sqlite'," \
                "  'database' => '$(escape_php_string "$sqlite_path")',"
            ;;
        *)
            if ! is_valid_database_name "$database_name" ||
               ! is_valid_database_user "$database_user" ||
               [[ -z "$database_password" ]]; then
                echo "[ERROR] Invalid database name, user or password." >&2
                return 1
            fi

            printf '%s\n' \
                "  'driver' => '$driver'," \
                "  'database' => '$(escape_php_string "$database_name")'," \
                "  'username' => '$(escape_php_string "$database_user")'," \
                "  'password' => '$(escape_php_string "$database_password")'," \
                "  'host' => 'localhost'," \
                "  'prefix' => '',"

            if [[ "$driver" == "mysql" ]]; then
                printf '%s\n' \
                    "  'port' => '3306'," \
                    "  'isolation_level' => 'READ COMMITTED',"
            else
                printf '%s\n' "  'port' => '5432',"
            fi
            ;;
    esac

    printf '%s\n' \
        "  'namespace' => 'Drupal\\\\${driver}\\\\Driver\\\\Database\\\\${driver}'," \
        "  'autoload' => 'core/modules/${driver}/src/Driver/Database/${driver}/'," \
        '];' \
        '' \
        '// Only answer for this project'"'"'s own address.' \
        "\$settings['trusted_host_patterns'] = ['$(escape_php_string "$domain_pattern")'];" \
        '' \
        '// Configuration export lives outside the web root.' \
        "\$settings['config_sync_directory'] = '../config/sync';"
}

# Creates web/sites/default/settings.php from Drupal's own template
# and appends the project settings. The database password travels
# through stdin, never through a command line.
write_drupal_settings() {
    local project_path="$1"
    local run_user="$2"
    local settings_dir="$project_path/web/sites/default"
    local settings_file="$settings_dir/settings.php"
    local settings

    if [[ ! -f "$settings_dir/default.settings.php" ]]; then
        echo "[ERROR] Drupal settings template not found: $settings_dir/default.settings.php"
        return 1
    fi

    if [[ -e "$settings_file" || -L "$settings_file" ]]; then
        echo "[ERROR] settings.php already exists: $settings_file"
        return 1
    fi

    settings="$(generate_drupal_settings \
        "$PROJECT_MACHINE_NAME" \
        "$DATABASE_ENGINE" \
        "${DATABASE_NAME:-}" \
        "${DATABASE_USER:-}" \
        "${DATABASE_PASSWORD:-}" \
        "${SQLITE_DATABASE_PATH:-}")" || return 1

    if ! run_as_project_user "$run_user" \
            cp "$settings_dir/default.settings.php" "$settings_file" ||
       ! printf '%s\n' "$settings" |
            run_as_project_user "$run_user" tee -a "$settings_file" > /dev/null; then
        echo "[ERROR] Could not write $settings_file"
        return 1
    fi

    echo "[OK] settings.php written (database, trusted host, config directory)"
}

# Drupal itself generates a temporary administrator password here; it
# is replaced right after by set_drupal_admin_password.
run_drupal_site_install() {
    local project_path="$1"
    local run_user="$2"
    local site_name="$3"
    local admin_user="$4"
    local admin_mail="$5"

    run_logged "Installing Drupal (${DRUPAL_INSTALL_PROFILE} profile)" \
        run_as_project_user "$run_user" "$project_path/drush" \
        site:install "$DRUPAL_INSTALL_PROFILE" \
        --yes \
        --site-name="$site_name" \
        --site-mail="$admin_mail" \
        --account-name="$admin_user" \
        --account-mail="$admin_mail"
}

# Sets and verifies the administrator password. The password is read
# by PHP from stdin, so it is never in a command line or the log.
set_drupal_admin_password() {
    local project_path="$1"
    local run_user="$2"
    local password="$3"
    local result

    # Single quotes: this is PHP code for Drush, not shell code.
    # shellcheck disable=SC2016
    local php_code='
$password = rtrim(stream_get_contents(STDIN), "\n");
if ($password === "") { echo "password-empty"; return; }
$storage = \Drupal::entityTypeManager()->getStorage("user");
$account = $storage->load(1);
$account->setPassword($password);
$account->save();
$account = $storage->loadUnchanged(1);
echo \Drupal::service("password")->check($password, $account->getPassword())
    ? "password-ok" : "password-mismatch";
'

    result="$(printf '%s' "$password" |
        run_as_project_user "$run_user" "$project_path/drush" php:eval "$php_code" 2>&1)" || true

    if [[ "$result" == *"password-ok"* ]]; then
        log_line "Administrator password replaced; the temporary one printed by site:install above no longer works."
        echo "[OK] Administrator password set"
        return 0
    fi

    log_line "Setting the administrator password failed: ${result//"$password"/***}"
    echo "[ERROR] The administrator password could not be set."
    return 1
}

# Drush must bootstrap the site, and the site must answer over HTTP
# (IPv4 and IPv6) as an installed Drupal site.
verify_drupal_site() {
    local project_path="$1"
    local run_user="$2"
    local machine_name="$3"
    local url
    local bootstrap
    local families="4"
    local family

    bootstrap="$(run_as_project_user "$run_user" "$project_path/drush" \
        status --field=bootstrap 2>/dev/null)" || true

    if [[ "$bootstrap" != *"Successful"* ]]; then
        echo "[ERROR] Drush cannot bootstrap the installed site."
        return 1
    fi

    url="http://$(get_project_nginx_domain "$machine_name")"

    if ! command -v curl > /dev/null; then
        echo "[OK] Drush bootstraps the site (curl missing: HTTP not checked)"
        return 0
    fi

    if is_ipv6_available; then
        families="4 6"
    fi

    for family in $families; do
        if ! curl "-$family" -sI --max-time 10 "$url/" 2>/dev/null |
                grep -qi '^x-generator: drupal'; then
            echo "[ERROR] $url does not answer as an installed Drupal site (IPv$family)."
            return 1
        fi
    done

    echo "[OK] Drupal site installed and answering: $url"
}

install_drupal_site() {
    local project_path="$1"
    local run_user="$2"
    local site_name="$3"
    local admin_user="$4"
    local admin_mail="$5"
    local admin_password="$6"

    write_drupal_settings "$project_path" "$run_user" &&
    run_drupal_site_install \
        "$project_path" "$run_user" "$site_name" "$admin_user" "$admin_mail" &&
    set_drupal_admin_password "$project_path" "$run_user" "$admin_password" &&
    verify_drupal_site "$project_path" "$run_user" "$PROJECT_MACHINE_NAME"
}
