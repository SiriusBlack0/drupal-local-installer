#!/usr/bin/env bash

set -e

source lib/php_fpm.sh

actual=$(get_project_php_fpm_socket "mydrupal" "8.5")
expected="/run/php/php8.5-fpm-mydrupal.sock"

if [[ "$actual" == "$expected" ]]; then
    echo "[PASS] PHP-FPM socket generated correctly"
else
    echo "[FAIL] PHP-FPM socket generated incorrectly"
    exit 1
fi

actual=$(get_php_fpm_pool_config_path "mydrupal" "8.5")
expected="/etc/php/8.5/fpm/pool.d/mydrupal.conf"

if [[ "$actual" == "$expected" ]]; then
    echo "[PASS] PHP-FPM pool config path generated correctly"
else
    echo "[FAIL] PHP-FPM pool config path generated incorrectly"
    exit 1
fi

config=$(generate_php_fpm_pool_config "mydrupal" "8.5")

if [[ "$config" == *"[mydrupal]"* ]]; then
    echo "[PASS] PHP-FPM pool name generated correctly"
else
    echo "[FAIL] PHP-FPM pool name generated incorrectly"
    exit 1
fi

expected_socket=$(get_project_php_fpm_socket "mydrupal" "8.5")

if [[ "$config" == *"listen = $expected_socket"* ]]; then
    echo "[PASS] PHP-FPM pool listen socket generated correctly"
else
    echo "[FAIL] PHP-FPM pool listen socket generated incorrectly"
    exit 1
fi

source lib/nginx.sh

nginx_config=$(generate_nginx_config "mydrupal" "/var/www/mydrupal" "8.5")
fpm_config=$(generate_php_fpm_pool_config "mydrupal" "8.5")

socket=$(get_project_php_fpm_socket "mydrupal" "8.5")

if [[ "$nginx_config" == *"fastcgi_pass unix:$socket;"* ]] &&
   [[ "$fpm_config" == *"listen = $socket"* ]]; then
    echo "[PASS] Nginx and PHP-FPM socket integration"
else
    echo "[FAIL] Nginx and PHP-FPM socket integration"
    exit 1
fi

test_file=$(mktemp)

if write_php_fpm_pool_config "mydrupal" "8.5" "$test_file" 2>/dev/null; then
    echo "[FAIL] Existing PHP-FPM config was overwritten"
    rm -f "$test_file"
    exit 1
else
    echo "[PASS] Existing PHP-FPM config protected"
fi

rm -f "$test_file"

test_dir=$(mktemp -d)
test_file="$test_dir/mydrupal.conf"

if write_php_fpm_pool_config "mydrupal" "8.5" "$test_file" &&
   [[ -f "$test_file" ]] &&
   grep -qFx "[mydrupal]" "$test_file" &&
   grep -qFx "listen = /run/php/php8.5-fpm-mydrupal.sock" "$test_file"; then
    echo "[PASS] New PHP-FPM pool config created correctly"
else
    echo "[FAIL] New PHP-FPM pool config creation failed"
    rm -rf "$test_dir"
    exit 1
fi

rm -rf "$test_dir"