#!/usr/bin/env bash
set -euo pipefail

run_test() {
    local scenario="$1"

    SCENARIO="$scenario" bash -c '
        set -e
        source lib/system.sh

        INSTALL_SERVICES_TO_START=()
        INSTALL_SERVICES_AFTER_INSTALL=()

        start_system_service() {
            echo "MOCK_START $1"

            if [[ "$SCENARIO" == failure && "$1" == "php8.5-fpm" ]]; then
                return 1
            fi

            return 0
        }

        case "$SCENARIO" in
            both_lists|duplicate)
                INSTALL_SERVICES_TO_START=("nginx")
                INSTALL_SERVICES_AFTER_INSTALL=("php8.5-fpm")
                ;;
            failure)
                INSTALL_SERVICES_TO_START=("nginx" "php8.5-fpm" "mariadb")
                ;;
            empty)
                ;;
        esac

        if [[ "$SCENARIO" == duplicate ]]; then
            INSTALL_SERVICES_AFTER_INSTALL+=("nginx")
        fi

        start_planned_services
    '
}

assert_success() {
    local scenario="$1"
    local output="$2"

    if ! output="$(run_test "$scenario")"; then
        echo "[FAIL] $scenario"
        echo "$output"
        exit 1
    fi

    case "$scenario" in
        both_lists|duplicate)
            [[ "$(grep -c "MOCK_START nginx" <<< "$output")" -eq 1 ]]
            [[ "$(grep -c "MOCK_START php8.5-fpm" <<< "$output")" -eq 1 ]]
            ;;
        empty)
            [[ "$output" != *"MOCK_START"* ]]
            ;;
    esac

    echo "[PASS] $scenario"
}

for scenario in both_lists duplicate empty; do
    assert_success "$scenario" ""
done

if output="$(run_test failure)"; then
    echo "[FAIL] failure"
    exit 1
else
    if [[ "$output" == *"Required service 'php8.5-fpm' could not be started."* ]] &&
       [[ "$output" != *"MOCK_START mariadb"* ]]; then
        echo "[PASS] failure"
    else
        echo "[FAIL] failure"
        echo "$output"
        exit 1
    fi
fi

echo "[SUCCESS] Service plan tests passed."
