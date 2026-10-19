#!/usr/bin/env bash

# Services: state, start, reload, and the services the plan starts.

# Native Ubuntu runs systemd; WSL may not. This is the standard
# systemd check (same test that sd_booted() performs).
has_systemd() {
    [[ -d /run/systemd/system ]]
}

is_service_active() {
    local service="$1"

    if has_systemd; then
        systemctl is-active --quiet "$service"
    else
        service "$service" status >/dev/null 2>&1
    fi
}

run_service_start() {
    local service="$1"

    if has_systemd; then
        sudo systemctl start "$service"
    else
        sudo service "$service" start
    fi
}

# Reads new configuration without stopping a running service, so other
# projects keep working. A stopped service is started instead.
reload_or_start_service() {
    local service="$1"

    if has_systemd; then
        sudo systemctl reload-or-restart "$service"
    elif is_service_active "$service"; then
        sudo service "$service" reload
    else
        sudo service "$service" start
    fi
}

# --------------------------------------------------
# Check whether PHP-FPM service is running
# --------------------------------------------------

is_php_fpm_running() {
    local php_version="$1"

    [[ "$php_version" =~ ^[0-9]+\.[0-9]+$ ]] || return 2

    is_service_active "php${php_version}-fpm"
}

# --------------------------------------------------
# Check whether Nginx service is running
# --------------------------------------------------

is_nginx_running() {
    is_service_active nginx
}

# --------------------------------------------------
# Check whether a database service is running
# --------------------------------------------------

# Prints the system service of a database engine.
# SQLite has no service: prints nothing and succeeds.
get_database_service_name() {
    case "$1" in
        mariadb) echo "mariadb" ;;
        mysql) echo "mysql" ;;
        postgresql) echo "postgresql" ;;
        sqlite) ;;
        *) return 2 ;;
    esac
}

is_database_service_running() {
    local database_engine="$1"
    local service_name

    service_name="$(get_database_service_name "$database_engine")" || return 2

    if [[ -z "$service_name" ]]; then
        return 0
    fi

    is_service_active "$service_name"
}

INSTALL_SERVICES_TO_START=()

add_service_to_start() {
    local service="$1"
    local existing

    for existing in "${INSTALL_SERVICES_TO_START[@]}"; do
        if [ "$existing" = "$service" ]; then
            return 0
        fi
    done

    INSTALL_SERVICES_TO_START+=("$service")
}

INSTALL_SERVICES_AFTER_INSTALL=()

add_service_after_install() {
    local service="$1"
    local existing

    for existing in "${INSTALL_SERVICES_AFTER_INSTALL[@]}"; do
        if [ "$existing" = "$service" ]; then
            return 0
        fi
    done

    INSTALL_SERVICES_AFTER_INSTALL+=("$service")
}

# --------------------------------------------------
# Start a system service
# --------------------------------------------------

start_system_service() {
    local service="$1"

    if is_service_active "$service"; then
        echo "[OK] Service '$service' is already running."
        return 0
    fi

    echo "[STARTING] Service '$service'..."

    if run_service_start "$service"; then
        if is_service_active "$service"; then
            echo "[OK] Service '$service' started successfully."
            return 0
        fi
    fi

    echo "[ERROR] Failed to start service '$service'."
    return 1
}

# --------------------------------------------------
# Start services from the installation plan
# --------------------------------------------------

start_planned_services() {
    local service
    local existing
    local already_processed
    local -a processed_services=()

    for service in \
        "${INSTALL_SERVICES_TO_START[@]}" \
        "${INSTALL_SERVICES_AFTER_INSTALL[@]}"; do

        already_processed=false

        for existing in "${processed_services[@]}"; do
            if [ "$existing" = "$service" ]; then
                already_processed=true
                break
            fi
        done

        if [ "$already_processed" = true ]; then
            continue
        fi

        processed_services+=("$service")

        if ! start_system_service "$service"; then
            echo "[ERROR] Required service '$service' could not be started."
            return 1
        fi
    done

    return 0
}
