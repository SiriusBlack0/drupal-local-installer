#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

source lib/compatibility.sh

check() {
    local label="$1"
    local expected="$2"
    local actual="$3"

    if [[ "$actual" == "$expected" ]]; then
        echo "[PASS] $label"
    else
        echo "[FAIL] $label (expected '$expected', got '$actual')"
        exit 1
    fi
}

# Test 1: Every matrix row is well formed.

line_number=0

while IFS= read -r row; do
    line_number=$((line_number + 1))

    if [[ ! "$row" =~ ^[0-9]+\.[0-9]+\|[0-9]+\.[0-9]+(,[0-9]+\.[0-9]+)*\|[0-9.]+\|[0-9.]+\|[0-9.]+\|[0-9.]+$ ]]; then
        echo "[FAIL] Malformed compatibility row: $row"
        exit 1
    fi
done < <(get_compatibility_rows)

if [[ "$line_number" -gt 0 ]]; then
    echo "[PASS] Compatibility matrix is well formed ($line_number rows)"
else
    echo "[FAIL] Compatibility matrix is empty"
    exit 1
fi

# Test 2: No duplicate Drupal minors.

check "No duplicate Drupal releases" "" \
    "$(get_supported_drupal_minors | sort | uniq -d)"

# Test 3: PHP versions per Drupal minor (drupal.org values).

check "PHP for Drupal 10.4" "8.1 8.2 8.3 8.4" "$(get_supported_php_versions 10.4 | paste -sd ' ' -)"
check "PHP for Drupal 11.2" "8.3 8.4" "$(get_supported_php_versions 11.2 | paste -sd ' ' -)"
check "PHP for Drupal 11.4" "8.3 8.4 8.5" "$(get_supported_php_versions 11.4 | paste -sd ' ' -)"

# Test 4: Releases outside the matrix are unsupported.

for minor in 9.0 10.0 10.3 11.0 abc ""; do
    if has_php_support_policy "$minor"; then
        echo "[FAIL] Unsupported release accepted: '$minor'"
        exit 1
    fi
done

echo "[PASS] Releases outside the matrix are rejected"

# Test 5: Database minimums per Drupal major.

check "MariaDB minimum for Drupal 10" "10.3.7" "$(get_database_minimum_version 10 mariadb)"
check "MySQL minimum for Drupal 11" "8.0" "$(get_database_minimum_version 11 mysql)"
check "PostgreSQL minimum for Drupal 11" "16" "$(get_database_minimum_version 11 postgresql)"
check "SQLite minimum for Drupal 11" "3.45" "$(get_database_minimum_version 11 sqlite)"

if get_database_minimum_version 11 oracle >/dev/null ||
   get_database_minimum_version 9 mariadb >/dev/null; then
    echo "[FAIL] Unknown engine or major accepted"
    exit 1
else
    echo "[PASS] Unknown engine or major rejected"
fi

# Test 6: Version comparison without PHP.

for case in "11.8.6 10.6 0" "10.6 10.6 0" "10.5.2 10.6 1" "18 16 0" "12 16 1" \
            "3.46.1 3.45 0" "3.37.2 3.45 1" "8.4.11 8.0 0" "5.7.44 8.0 1" " 8.0 1"; do
    read -r version minimum expected <<< "$case"

    if [[ -z "$expected" ]]; then
        expected="$minimum"
        minimum="$version"
        version=""
    fi

    if version_at_least "$version" "$minimum"; then
        result=0
    else
        result=1
    fi

    if [[ "$result" != "$expected" ]]; then
        echo "[FAIL] version_at_least '$version' '$minimum' returned $result"
        exit 1
    fi
done

echo "[PASS] Version comparison works without PHP"

# Test 7: Missing matrix file is reported.

if DRUPAL_COMPATIBILITY_FILE=/nonexistent get_supported_php_versions 11.4 2>/dev/null; then
    echo "[FAIL] Missing compatibility file ignored"
    exit 1
else
    echo "[PASS] Missing compatibility file reported"
fi

# Database options: MariaDB and MySQL exclude each other. Runs in a
# subshell so the stubs do not leak into other tests.
(
    source lib/database.sh

    get_database_engines() { printf '%s\n' mariadb mysql postgresql; }
    get_available_database_version() {
        case "$1" in mariadb) echo 11.8.6 ;; mysql) echo 8.4.11 ;; postgresql) echo 18 ;; esac
    }
    is_database_version_compatible() { return 0; }
    is_database_engine_installed() { [[ " $INSTALLED " == *" $1 "* ]]; }

    INSTALLED="mariadb"
    check "MySQL marked as conflict when MariaDB is installed" \
        "mariadb|11.8.6|installed mysql|8.4.11|conflict postgresql|18|available" \
        "$(get_compatible_database_options 11 | tr '\n' ' ' | sed 's/ $//')"

    INSTALLED="mysql"
    check "MariaDB marked as conflict when MySQL is installed" \
        "mariadb|11.8.6|conflict mysql|8.4.11|installed postgresql|18|available" \
        "$(get_compatible_database_options 11 | tr '\n' ' ' | sed 's/ $//')"

    INSTALLED=""
    check "Neither installed: both available" \
        "mariadb|11.8.6|available mysql|8.4.11|available postgresql|18|available" \
        "$(get_compatible_database_options 11 | tr '\n' ' ' | sed 's/ $//')"
)

echo "[SUCCESS] Compatibility matrix tests passed."
