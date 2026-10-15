#!/usr/bin/env bash
set -euo pipefail

for scenario in already_running starts_successfully start_fails remains_inactive; do
    SCENARIO="$scenario" bash -c '
        set -e

        source lib/system.sh

        has_systemd() {
            return 0
        }

        systemctl() {
            if [[ "$1" != "is-active" ]]; then
                return 1
            fi

            case "$SCENARIO" in
                already_running)
                    return 0
                    ;;
                starts_successfully)
                    [[ "${SERVICE_STARTED:-false}" == true ]]
                    ;;
                *)
                    return 1
                    ;;
            esac
        }

        sudo() {
            echo "MOCK_SUDO $*"

            if [[ "$SCENARIO" == start_fails ]]; then
                return 1
            fi

            SERVICE_STARTED=true
            return 0
        }

        if start_system_service nginx; then
            result=0
        else
            result=$?
        fi

        case "$SCENARIO" in
            already_running)
                [[ "$result" -eq 0 && "${SERVICE_STARTED:-false}" == false ]]
                ;;
            starts_successfully)
                [[ "$result" -eq 0 && "$SERVICE_STARTED" == true ]]
                ;;
            start_fails|remains_inactive)
                [[ "$result" -eq 1 ]]
                ;;
        esac
    '

    echo "[PASS] $scenario"
done

echo "[SUCCESS] Service start tests passed."
