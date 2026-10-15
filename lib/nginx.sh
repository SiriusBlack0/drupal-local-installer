#!/usr/bin/env bash

get_project_nginx_domain() {
    local machine_name="$1"

    printf '%s.localhost\n' "$machine_name"
}

generate_nginx_config() {
    local machine_name="$1"
    local project_dir="$2"
    local php_version="$3"

    local domain
    local socket

    domain="$(get_project_nginx_domain "$machine_name")"
    socket="$(get_project_php_fpm_socket "$machine_name" "$php_version")"

    cat <<EOF
server {
    listen 80;
    server_name $domain;

    root $project_dir/web;
    index index.php;

    location / {
        try_files \$uri /index.php?\$query_string;
    }

    location ~* ^/sites/[^/]+/files/.*\.php(?:/|$) {
        return 403;
    }

    location = /index.php {
        include /etc/nginx/snippets/fastcgi-php.conf;
        fastcgi_pass unix:$socket;
    }

    location ~ \.php$ {
        return 404;
    }

    location ~ /\\. {
        deny all;
    }

    location ~* ^/sites/[^/]+/(settings(\..*)?\.php|services(\..*)?\.yml)$ {
        deny all;
    }
}
EOF
}

get_nginx_config_path() {
    local machine_name="$1"

    printf '/etc/nginx/sites-available/%s.conf\n' "$machine_name"
}

nginx_config_exists() {
    local machine_name="$1"
    local config_path

    config_path="$(get_nginx_config_path "$machine_name")"

    [[ -e "$config_path" || -L "$config_path" ]]
}

write_nginx_config() {
    local machine_name="$1"
    local project_dir="$2"
    local php_version="$3"
    local output_path="$4"

    if [[ -e "$output_path" || -L "$output_path" ]]; then
        printf 'Error: Configuration already exists: %s\n' "$output_path" >&2
        return 1
    fi

    (
        set -C

        generate_nginx_config \
            "$machine_name" \
            "$project_dir" \
            "$php_version" > "$output_path"
    )
}