#!/usr/bin/env bash

get_project_php_fpm_socket() {
    local machine_name="$1"
    local php_version="$2"

    printf '/run/php/php%s-fpm-%s.sock\n' \
        "$php_version" \
        "$machine_name"
}

get_php_fpm_pool_config_path() {
    local machine_name="$1"
    local php_version="$2"

    printf '/etc/php/%s/fpm/pool.d/%s.conf\n' \
        "$php_version" \
        "$machine_name"
}

generate_php_fpm_pool_config() {
    local machine_name="$1"
    local php_version="$2"

    local socket
    socket="$(get_project_php_fpm_socket "$machine_name" "$php_version")"

    cat <<EOF
[$machine_name]

user = www-data
group = www-data

listen = $socket

listen.owner = www-data
listen.group = www-data
listen.mode = 0660

pm = dynamic
pm.max_children = 10
pm.start_servers = 2
pm.min_spare_servers = 2
pm.max_spare_servers = 5

pm.max_requests = 500

chdir = /
EOF
}

php_fpm_pool_exists() {
    local machine_name="$1"
    local php_version="$2"
    local config_path

    config_path="$(get_php_fpm_pool_config_path "$machine_name" "$php_version")"

    [[ -e "$config_path" || -L "$config_path" ]]
}

write_php_fpm_pool_config() {
    local machine_name="$1"
    local php_version="$2"
    local output_path="$3"

    if ! (
        set -C

        generate_php_fpm_pool_config \
            "$machine_name" \
            "$php_version" > "$output_path"
    ); then
        printf 'Error: Could not create pool configuration: %s\n' \
            "$output_path" >&2
        return 1
    fi
}