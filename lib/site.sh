#!/usr/bin/env bash

# ==================================================
# Drupal site installation (drush site:install)
#
# Secrets never appear in a command line, where any local user could
# read them with "ps", and never in the log:
# - the database password is written into settings.local.php through
#   stdin;
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

# A random hash salt, like the one Drupal's installer writes (URL-safe
# base64 of 55 random bytes).
generate_hash_salt() {
    openssl rand -base64 55 | tr -d '\n=' | tr '+/' '-_'
}

# Prints settings.local.php: the database credentials and the hash
# salt. It is the only file with secrets; git ignores it.
# Arguments: engine database user password sqlite_path hash_salt
generate_drupal_local_settings() {
    local engine="$1"
    local database_name="$2"
    local database_user="$3"
    local database_password="$4"
    local sqlite_path="$5"
    local hash_salt="$6"
    local driver

    if ! driver="$(get_drupal_database_driver "$engine")"; then
        echo "[ERROR] Invalid database engine." >&2
        return 1
    fi

    if [[ ! "$hash_salt" =~ ^[A-Za-z0-9_-]{40,}$ ]]; then
        echo "[ERROR] Invalid hash salt." >&2
        return 1
    fi

    printf '%s\n' \
        '<?php' \
        '' \
        '// Written by drupal-local-installer. Secrets of this site: the' \
        '// database credentials and the hash salt. Never commit this file' \
        '// (.gitignore leaves it out); settings.php includes it.' \
        '' \
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
        "\$settings['hash_salt'] = '$hash_salt';"
}

# Prints the block appended to settings.php. No secrets: settings.php
# can be committed to git.
generate_drupal_settings() {
    local machine_name="$1"
    local domain_pattern

    if [[ ! "$machine_name" =~ ^[a-z0-9_]+$ ]]; then
        echo "[ERROR] Invalid project name." >&2
        return 1
    fi

    domain_pattern="^${machine_name}\\.localhost\$"

    # Text between single quotes is PHP code, written literally.
    # shellcheck disable=SC2016
    printf '%s\n' \
        '' \
        '// ------------------------------------------------------------' \
        '// Added by drupal-local-installer.' \
        '// ------------------------------------------------------------' \
        '' \
        '// Only answer for this project'"'"'s own address.' \
        "\$settings['trusted_host_patterns'] = ['$(escape_php_string "$domain_pattern")'];" \
        '' \
        '// Configuration export lives outside the web root.' \
        "\$settings['config_sync_directory'] = '../config/sync';" \
        '' \
        '// Database credentials and the hash salt: settings.local.php (not' \
        '// in git). Keep secrets there, never in this file.' \
        'if (file_exists($app_root . '"'"'/'"'"' . $site_path . '"'"'/settings.local.php'"'"')) {' \
        '  include $app_root . '"'"'/'"'"' . $site_path . '"'"'/settings.local.php'"'"';' \
        '}'
}

# Creates web/sites/default/settings.php from Drupal's own template
# plus the project block, and settings.local.php with the secrets
# (mode 600, written through stdin: never in a command line).
#
# With the database, the hash salt and the config directory all set
# before site:install, Drupal's installer skips its settings form and
# leaves settings.php alone; otherwise it would write the database
# password into settings.php.
write_drupal_settings() {
    local project_path="$1"
    local run_user="$2"
    local settings_dir="$project_path/web/sites/default"
    local settings_file="$settings_dir/settings.php"
    local local_file="$settings_dir/settings.local.php"
    local settings
    local local_settings
    local hash_salt

    if [[ ! -f "$settings_dir/default.settings.php" ]]; then
        echo "[ERROR] Drupal settings template not found: $settings_dir/default.settings.php"
        return 1
    fi

    if [[ -e "$settings_file" || -L "$settings_file" ]]; then
        echo "[ERROR] settings.php already exists: $settings_file"
        return 1
    fi

    if [[ -e "$local_file" || -L "$local_file" ]]; then
        echo "[ERROR] settings.local.php already exists: $local_file"
        return 1
    fi

    if ! hash_salt="$(generate_hash_salt)" || [[ -z "$hash_salt" ]]; then
        echo "[ERROR] Could not generate a hash salt (openssl)."
        return 1
    fi

    settings="$(generate_drupal_settings "$PROJECT_MACHINE_NAME")" || return 1
    local_settings="$(generate_drupal_local_settings \
        "$DATABASE_ENGINE" \
        "${DATABASE_NAME:-}" \
        "${DATABASE_USER:-}" \
        "${DATABASE_PASSWORD:-}" \
        "${SQLITE_DATABASE_PATH:-}" \
        "$hash_salt")" || return 1

    # The empty file is made private first, then filled.
    if ! run_as_project_user "$run_user" touch "$local_file" ||
       ! run_as_project_user "$run_user" chmod 600 "$local_file" ||
       ! printf '%s\n' "$local_settings" |
            run_as_project_user "$run_user" tee "$local_file" > /dev/null; then
        echo "[ERROR] Could not write $local_file"
        return 1
    fi

    if ! run_as_project_user "$run_user" \
            cp "$settings_dir/default.settings.php" "$settings_file" ||
       ! printf '%s\n' "$settings" |
            run_as_project_user "$run_user" tee -a "$settings_file" > /dev/null ||
       ! run_as_project_user "$run_user" mkdir -p "$project_path/config/sync"; then
        echo "[ERROR] Could not write $settings_file"
        return 1
    fi

    echo "[OK] settings.php written (trusted host, config directory)"
    echo "[OK] settings.local.php written (database, hash salt; private, not for git)"
}

# settings.php must stay free of secrets: Drupal's installer could
# still write the database settings into it.
check_settings_without_secrets() {
    local settings_file="$1/web/sites/default/settings.php"

    if grep -qE "^[[:space:]]*\\\$databases\\[|^[[:space:]]*\\\$settings\\['hash_salt'\\][[:space:]]*=[[:space:]]*'[^']" "$settings_file" 2>/dev/null; then
        return 1
    fi

    return 0
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

# site:install prints the temporary password Drupal made up ("User
# password: ..."). It is replaced right after and no longer works, but a
# password in the log only confuses: it is masked there.
mask_temporary_password_in_log() {
    [[ -n "${LOG_FILE:-}" && -f "$LOG_FILE" ]] || return 0
    sed -i -E 's/(User password:[[:space:]]*)[^[:space:]].*$/\1[temporary password, replaced by the installer]/' "$LOG_FILE" || true
    return 0
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

    local headers

    if is_ipv6_loopback_available; then
        families="4 6"
    fi

    for family in $families; do
        headers="$(get_site_headers "$family" "$url")"

        if ! grep -qi '^x-generator: drupal' <<< "$headers"; then
            echo "[ERROR] $url does not answer as an installed Drupal site (IPv$family):"
            echo "        $(describe_site_answer "$headers")"
            log_line "Installed site check over IPv$family failed. Headers:"$'\n'"${headers:-(none)}"
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
    mask_temporary_password_in_log &&
    set_drupal_admin_password "$project_path" "$run_user" "$admin_password" &&
    verify_drupal_site "$project_path" "$run_user" "$PROJECT_MACHINE_NAME"
}

# ==================================================
# Final checks
#
# The site already works at this point (verify_drupal_site), so these
# checks only report: a warning here never rolls the project back.
# ==================================================

# Prints the titles of error-level items of Drupal's status report
# (/admin/reports/status), one per line.
get_drupal_requirement_errors() {
    local project_path="$1"
    local run_user="$2"
    local php_version="$3"
    local json

    json="$(run_as_project_user "$run_user" "$project_path/drush" \
        core:requirements --severity=2 --format=json 2>/dev/null)" || return 1

    # Single quotes: PHP code, not shell code.
    # shellcheck disable=SC2016
    printf '%s' "$json" | "php${php_version}" -r '
$data = json_decode(stream_get_contents(STDIN), true);
if (!is_array($data)) { exit(1); }
foreach ($data as $item) {
    echo strip_tags((string) ($item["title"] ?? "?")), "\n";
}
'
}

run_final_checks() {
    local project_path="$1"
    local run_user="$2"
    local php_version="$3"
    local files_dir="$project_path/web/sites/default/files"
    local settings_file="$project_path/web/sites/default/settings.php"
    local db_status
    local mode
    local errors
    local warnings=0

    db_status="$(run_as_project_user "$run_user" "$project_path/drush" \
        status --field=db-status 2>/dev/null)" || true

    if [[ "$db_status" == *"Connected"* ]]; then
        echo "[OK] Database connection"
    else
        echo "[WARNING] Drush reports no database connection."
        warnings=$((warnings + 1))
    fi

    if [[ -d "$files_dir" ]] && run_as_project_user "$run_user" test -w "$files_dir"; then
        echo "[OK] Files directory is writable: web/sites/default/files"
    else
        echo "[WARNING] Files directory is missing or not writable: $files_dir"
        warnings=$((warnings + 1))
    fi

    if mode="$(stat -c '%a' "$settings_file" 2>/dev/null)" &&
       (( (8#$mode & 8#022) == 0 )); then
        echo "[OK] settings.php cannot be changed by other users ($mode)"
    else
        echo "[WARNING] settings.php is writable by other users: $settings_file"
        warnings=$((warnings + 1))
    fi

    if check_settings_without_secrets "$project_path"; then
        echo "[OK] settings.php has no secrets (they are in settings.local.php)"
    else
        echo "[WARNING] settings.php contains database settings or the hash salt:"
        echo "          do not commit it to git as it is."
        warnings=$((warnings + 1))
    fi

    if errors="$(get_drupal_requirement_errors "$project_path" "$run_user" "$php_version")"; then
        if [[ -z "$errors" ]]; then
            echo "[OK] Drupal status report: no errors"
        else
            echo "[WARNING] Drupal status report has errors:"
            printf '%s\n' "$errors" | sed 's/^/            - /'
            echo "            Details: http://$(get_project_nginx_domain "$PROJECT_MACHINE_NAME")/admin/reports/status"
            warnings=$((warnings + 1))
        fi
    else
        echo "[SKIPPED] Drupal status report could not be read."
    fi

    # Composer 2.9+ refuses "composer require" in a project whose locked
    # packages have security advisories, until they are updated.
    local security_status=0
    has_core_security_advisory "$project_path" "$php_version" || security_status=$?

    case "$security_status" in
        0)
            echo "[WARNING] Drupal core ${DRUPAL_VERSION:-} has published security advisories."
            echo "          Composer refuses to add modules (composer require) until core is"
            echo "          updated: ./install.sh --update $(basename "$project_path")"
            warnings=$((warnings + 1))
            ;;
        1) echo "[OK] No known security advisory for Drupal core" ;;
        *) echo "[SKIPPED] Security advisories could not be checked (composer audit; network?)." ;;
    esac

    if [[ "$warnings" -gt 0 ]]; then
        echo "[INFO] $warnings check(s) need attention; the site itself is installed."
    fi

    return 0
}
