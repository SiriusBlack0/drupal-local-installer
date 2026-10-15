#!/usr/bin/env bash

set -e

source lib/php_fpm.sh
source lib/nginx.sh

actual=$(get_project_nginx_domain "mydrupal")
expected="mydrupal.localhost"

if [[ "$actual" == "$expected" ]]; then
    echo "[PASS] Nginx domain generated correctly"
else
    echo "[FAIL] Nginx domain generated incorrectly"
    exit 1
fi

actual=$(get_nginx_config_path "mydrupal")
expected="/etc/nginx/sites-available/mydrupal.conf"

if [[ "$actual" == "$expected" ]]; then
    echo "[PASS] Nginx config path generated correctly"
else
    echo "[FAIL] Nginx config path generated incorrectly"
    exit 1
fi

config=$(generate_nginx_config "mydrupal" "/var/www/mydrupal" "8.5")

if [[ "$config" == *"server_name mydrupal.localhost;"* ]]; then
    echo "[PASS] Nginx server name generated correctly"
else
    echo "[FAIL] Nginx server name generated incorrectly"
    exit 1
fi

if [[ "$config" == *"root /var/www/mydrupal/web;"* ]]; then
    echo "[PASS] Nginx Drupal root generated correctly"
else
    echo "[FAIL] Nginx Drupal root generated incorrectly"
    exit 1
fi

if [[ "$config" == *"fastcgi_pass unix:/run/php/php8.5-fpm-mydrupal.sock;"* ]]; then
    echo "[PASS] Nginx PHP-FPM socket generated correctly"
else
    echo "[FAIL] Nginx PHP-FPM socket generated incorrectly"
    exit 1
fi

test_file=$(mktemp)

echo "ORIGINAL CONFIG" > "$test_file"

if write_nginx_config "mydrupal" "/var/www/mydrupal" "8.5" "$test_file" 2>/dev/null; then
    echo "[FAIL] Existing Nginx config was overwritten"
    rm -f "$test_file"
    exit 1
fi

if [[ "$(cat "$test_file")" == "ORIGINAL CONFIG" ]]; then
    echo "[PASS] Existing Nginx config protected"
else
    echo "[FAIL] Existing Nginx config content changed"
    rm -f "$test_file"
    exit 1
fi

rm -f "$test_file"

test_dir=$(mktemp -d)
test_file="$test_dir/mydrupal.conf"

if write_nginx_config "mydrupal" "/var/www/mydrupal" "8.5" "$test_file" &&
   [[ -f "$test_file" ]] &&
   grep -qF "server_name mydrupal.localhost;" "$test_file"; then
    echo "[PASS] New Nginx config created correctly"
else
    echo "[FAIL] New Nginx config creation failed"
    rm -rf "$test_dir"
    exit 1
fi

rm -rf "$test_dir"