#!/usr/bin/env bash
set -euo pipefail

source lib/readiness.sh

# Test 1: Composer available.
is_composer_installed() {
    return 0
}

if output="$(verify_composer_ready)" &&
   [[ "$output" == *"[READY] Composer"* ]]; then
    echo "[PASS] Composer available"
else
    echo "[FAIL] Composer available"
    exit 1
fi

# Test 2: Composer missing.
is_composer_installed() {
    return 1
}

if output="$(verify_composer_ready)"; then
    echo "[FAIL] Composer missing"
    exit 1
elif [[ "$output" == *"[NOT READY] Composer is missing."* ]]; then
    echo "[PASS] Composer missing"
else
    echo "[FAIL] Composer missing"
    exit 1
fi

# Test 3: Nginx installed and running.
is_nginx_installed() {
    return 0
}

is_nginx_running() {
    return 0
}

if output="$(verify_nginx_ready)" &&
   [[ "$output" == *"[READY] Nginx"* ]]; then
    echo "[PASS] Nginx ready"
else
    echo "[FAIL] Nginx ready"
    exit 1
fi

# Test 4: Nginx not installed.
is_nginx_installed() {
    return 1
}

if output="$(verify_nginx_ready)"; then
    echo "[FAIL] Nginx missing"
    exit 1
elif [[ "$output" == *"[NOT READY] Nginx is not installed."* ]]; then
    echo "[PASS] Nginx missing"
else
    echo "[FAIL] Nginx missing"
    exit 1
fi

# Test 5: Nginx installed but stopped.
is_nginx_installed() {
    return 0
}

is_nginx_running() {
    return 1
}

if output="$(verify_nginx_ready)"; then
    echo "[FAIL] Nginx stopped"
    exit 1
elif [[ "$output" == *"[NOT READY] Nginx service is not running."* ]]; then
    echo "[PASS] Nginx stopped"
else
    echo "[FAIL] Nginx stopped"
    exit 1
fi

# Test 6: PHP CLI installed.
is_php_cli_installed() {
    [[ "$1" == "8.3" ]]
}

if output="$(verify_php_cli_ready "8.3")" &&
   [[ "$output" == *"[READY] PHP 8.3 CLI"* ]]; then
    echo "[PASS] PHP CLI installed"
else
    echo "[FAIL] PHP CLI installed"
    exit 1
fi

# Test 7: PHP CLI missing.
is_php_cli_installed() {
    return 1
}

if output="$(verify_php_cli_ready "8.5")"; then
    echo "[FAIL] PHP CLI missing"
    exit 1
elif [[ "$output" == *"[NOT READY] PHP 8.5 CLI is not installed."* ]]; then
    echo "[PASS] PHP CLI missing"
else
    echo "[FAIL] PHP CLI missing"
    exit 1
fi

# Test 8: PHP-FPM installed and running.
is_php_fpm_installed() {
    [[ "$1" == "8.3" ]]
}

is_php_fpm_running() {
    return 0
}

if output="$(verify_php_fpm_ready "8.3")" &&
   [[ "$output" == *"[READY] PHP 8.3 FPM"* ]]; then
    echo "[PASS] PHP-FPM ready"
else
    echo "[FAIL] PHP-FPM ready"
    exit 1
fi

# Test 9: PHP-FPM missing.
is_php_fpm_installed() {
    return 1
}

if output="$(verify_php_fpm_ready "8.5")"; then
    echo "[FAIL] PHP-FPM missing"
    exit 1
elif [[ "$output" == *"[NOT READY] PHP 8.5 FPM is not installed."* ]]; then
    echo "[PASS] PHP-FPM missing"
else
    echo "[FAIL] PHP-FPM missing"
    exit 1
fi

# Test 10: PHP-FPM installed but stopped.
is_php_fpm_installed() {
    return 0
}

is_php_fpm_running() {
    return 1
}

if output="$(verify_php_fpm_ready "8.4")"; then
    echo "[FAIL] PHP-FPM stopped"
    exit 1
elif [[ "$output" == *"[NOT READY] PHP 8.4 FPM service is not running."* ]]; then
    echo "[PASS] PHP-FPM stopped"
else
    echo "[FAIL] PHP-FPM stopped"
    exit 1
fi

# Test 11: All PHP extensions available.
check_php_extensions() {
    [[ "$1" == "8.3" &&
       "$2" == "curl" &&
       "$3" == "gd" &&
       "$4" == "mbstring" ]]
}

if output="$(verify_php_extensions_ready "8.3" curl gd mbstring)" &&
   [[ "$output" == *"[READY] PHP 8.3 extensions"* ]]; then
    echo "[PASS] PHP extensions available"
else
    echo "[FAIL] PHP extensions available"
    exit 1
fi

# Test 12: Required PHP extension missing.
check_php_extensions() {
    return 1
}

if output="$(verify_php_extensions_ready "8.5" curl gd mbstring)"; then
    echo "[FAIL] PHP extension missing"
    exit 1
elif [[ "$output" == *"[NOT READY] Required PHP extensions are missing."* ]]; then
    echo "[PASS] PHP extension missing"
else
    echo "[FAIL] PHP extension missing"
    exit 1
fi

# Test 13: MariaDB running.
is_database_service_running() {
    [[ "$1" == "mariadb" ]]
}

if output="$(verify_database_ready "mariadb")" &&
   [[ "$output" == *"[READY] mariadb service"* ]]; then
    echo "[PASS] MariaDB running"
else
    echo "[FAIL] MariaDB running"
    exit 1
fi

# Test 14: MariaDB stopped.
is_database_service_running() {
    return 1
}

if output="$(verify_database_ready "mariadb")"; then
    echo "[FAIL] MariaDB stopped"
    exit 1
elif [[ "$output" == *"[NOT READY] mariadb service is not running."* ]]; then
    echo "[PASS] MariaDB stopped"
else
    echo "[FAIL] MariaDB stopped"
    exit 1
fi

# Test 15: SQLite requires no service.
is_database_service_running() {
    echo "UNEXPECTED_DATABASE_CHECK"
    return 1
}

if output="$(verify_database_ready "sqlite")" &&
   [[ "$output" == *"[READY] SQLite - no database service required."* ]] &&
   [[ "$output" != *"UNEXPECTED_DATABASE_CHECK"* ]]; then
    echo "[PASS] SQLite ready"
else
    echo "[FAIL] SQLite ready"
    exit 1
fi

# Test 16: Complete environment ready.

PHP_VERSION="8.3"
DATABASE_ENGINE="mariadb"
REQUIRED_PHP_EXTENSIONS=(curl gd mbstring)

verify_composer_ready() {
    return 0
}

verify_nginx_ready() {
    return 0
}

verify_php_cli_ready() {
    [[ "$1" == "8.3" ]]
}

verify_php_fpm_ready() {
    [[ "$1" == "8.3" ]]
}

verify_php_extensions_ready() {
    [[ "$1" == "8.3" ]]
}

verify_database_ready() {
    [[ "$1" == "mariadb" ]]
}

if output="$(verify_environment_ready)" &&
   [[ "$output" == *"[SUCCESS] Environment is ready."* ]]; then
    echo "[PASS] Complete environment ready"
else
    echo "[FAIL] Complete environment ready"
    exit 1
fi

# Test 17: One dependency fails.

verify_nginx_ready() {
    echo "[NOT READY] Nginx service is not running."
    return 1
}

verify_database_ready() {
    echo "[READY] Database checked"
    return 0
}

if output="$(verify_environment_ready)"; then
    echo "[FAIL] Environment failure detection"
    exit 1
elif [[ "$output" == *"[NOT READY] Nginx service is not running."* ]] &&
     [[ "$output" == *"[READY] Database checked"* ]] &&
     [[ "$output" == *"[ERROR] Environment is not ready."* ]]; then
    echo "[PASS] Environment failure detection"
else
    echo "[FAIL] Environment failure detection"
    exit 1
fi