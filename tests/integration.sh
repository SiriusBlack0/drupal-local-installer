#!/usr/bin/env bash

set -euo pipefail

# Extract only the confirm_installation function.
eval "$(sed -n '/^confirm_installation() {/,/^}/p' lib/ui/confirm.sh)"

# Mock project configuration.
export PROJECT_NAME="Test Project"
export PROJECT_MACHINE_NAME="test_project"
export DRUPAL_VERSION="11.4.8"
export PHP_VERSION="8.5"
export PHP_STATUS="installed"
export DATABASE_ENGINE="sqlite"
export DATABASE_VERSION="3"
export DATABASE_STATUS="installed"
export SQLITE_DATABASE_PATH="/tmp/test.sqlite"
export ADMIN_USER="admin"
export ADMIN_PASSWORD_GENERATED=1

# Test 1: User cancels installation.

if output="$(printf 'n\n' | confirm_installation)" &&
   [[ "$output" == *"Installation cancelled."* ]]; then
    echo "[PASS] Installation cancelled by user"
else
    echo "[FAIL] Installation cancelled by user"
    exit 1
fi

# Test 2: User confirms installation.

if output="$(printf 'y\n' | confirm_installation)" &&
   [[ "$output" == *"Project configuration"* ]] &&
   [[ "$output" == *"Admin:    admin (random password, shown at the end)"* ]] &&
   [[ "$output" != *"Installation cancelled."* ]]; then
    echo "[PASS] Installation confirmed by user"
else
    echo "[FAIL] Installation confirmed by user"
    exit 1
fi

# Test 3: User accepts default confirmation (Enter).

if output="$(printf '\n' | confirm_installation)" &&
   [[ "$output" == *"Project configuration"* ]] &&
   [[ "$output" != *"Installation cancelled."* ]]; then
    echo "[PASS] Default installation confirmation"
else
    echo "[FAIL] Default installation confirmation"
    exit 1
fi

# Test 4: Input ends unexpectedly (EOF).

if output="$(confirm_installation </dev/null)" &&
   [[ "$output" == *"Input cancelled."* ]]; then
    echo "[PASS] Installation confirmation EOF"
else
    echo "[FAIL] Installation confirmation EOF"
    exit 1
fi

# Test 5: Installation plan with available packages.

if output="$(
    bash -c '
        set -euo pipefail

        INSTALL_PACKAGES=("php8.3-cli" "php8.3-fpm")
        INSTALL_SERVICES_TO_START=("nginx")
        INSTALL_SERVICES_AFTER_INSTALL=("php8.3-fpm")
        UNAVAILABLE_PACKAGES=()

        check_apt_repository_compatibility() {
            return 0
        }

        check_install_packages_availability() {
            return 0
        }

        source lib/plan.sh
        prepare_installation_plan

        [[ "$APT_REPOSITORIES_COMPATIBLE" == true ]]
        [[ "$PACKAGES_AVAILABLE" == true ]]
    '
)" &&
   [[ "$output" == *"php8.3-cli"* ]] &&
   [[ "$output" == *"php8.3-fpm"* ]] &&
   [[ "$output" == *"nginx"* ]]; then
    echo "[PASS] Installation plan with available packages"
else
    echo "[FAIL] Installation plan with available packages"
    exit 1
fi

# Test 6: Installation plan with unavailable packages.

if output="$(
    bash -c '
        set -euo pipefail

        INSTALL_PACKAGES=("php8.3-cli")
        INSTALL_SERVICES_TO_START=()
        INSTALL_SERVICES_AFTER_INSTALL=()
        UNAVAILABLE_PACKAGES=("php8.3-cli")

        check_apt_repository_compatibility() {
            return 0
        }

        check_install_packages_availability() {
            return 1
        }

        source lib/plan.sh
        prepare_installation_plan


        [[ "$APT_REPOSITORIES_COMPATIBLE" == true ]]
        [[ "$PACKAGES_AVAILABLE" == false ]]
    '
)" &&
   [[ "$output" == *"[PENDING] Additional repositories may be required."* ]] &&
   [[ "$output" == *"php8.3-cli"* ]]; then
    echo "[PASS] Installation plan with unavailable packages"
else
    echo "[FAIL] Installation plan with unavailable packages"
    exit 1
fi

# Test 7: Block installation when packages are unavailable.

if output="$(
    bash -c '
        set -euo pipefail

        APT_REPOSITORIES_COMPATIBLE=true
        PACKAGES_AVAILABLE=false
        INSTALL_PACKAGES=("php8.3-cli")

        eval "$(sed -n "/^prepare_package_installation() {/,/^}/p" lib/install_execution.sh)"

        if prepare_package_installation; then
            exit 1
        fi
    '
)" &&
   [[ "$output" == *"[BLOCKED] Package installation cannot proceed."* ]] &&
   [[ "$output" == *"Some required packages are unavailable."* ]]; then
    echo "[PASS] Installation blocked for unavailable packages"
else
    echo "[FAIL] Installation blocked for unavailable packages"
    exit 1
fi

# Test 8: Installation plan with incompatible repositories.

if output="$(
    bash -c '
        set -euo pipefail

        INSTALL_PACKAGES=()
        INSTALL_SERVICES_TO_START=()
        INSTALL_SERVICES_AFTER_INSTALL=()

        check_apt_repository_compatibility() {
            return 1
        }

        check_install_packages_availability() {
            return 0
        }

        source lib/plan.sh
        prepare_installation_plan

        [[ "$APT_REPOSITORIES_COMPATIBLE" == false ]]
        [[ "$PACKAGES_AVAILABLE" == true ]]
    '
)" &&
   [[ "$output" == *"Checking APT repository compatibility..."* ]]; then
    echo "[PASS] Installation plan with incompatible repositories"
else
    echo "[FAIL] Installation plan with incompatible repositories"
    exit 1
fi

# Test 9: Block package installation with incompatible repositories.

if output="$(
    bash -c '
        set -euo pipefail

        APT_REPOSITORIES_COMPATIBLE=false
        PACKAGES_AVAILABLE=true
        INSTALL_PACKAGES=("php8.3-cli")

        eval "$(sed -n "/^prepare_package_installation() {/,/^}/p" lib/install_execution.sh)"

        if prepare_package_installation; then
            exit 1
        fi
    '
)" &&
   [[ "$output" == *"[BLOCKED] Incompatible APT repositories detected."* ]] &&
   [[ "$output" == *"Package installation cannot proceed safely."* ]]; then
    echo "[PASS] Installation blocked for incompatible repositories"
else
    echo "[FAIL] Installation blocked for incompatible repositories"
    exit 1
fi

# Test 10: No packages required despite incompatible repositories.

if output="$(
    bash -c '
        set -euo pipefail

        APT_REPOSITORIES_COMPATIBLE=false
        PACKAGES_AVAILABLE=true
        INSTALL_PACKAGES=()

        eval "$(sed -n "/^prepare_package_installation() {/,/^}/p" lib/install_execution.sh)"

        prepare_package_installation
    '
)" &&
   [[ "$output" == *"[OK] No additional packages need installation."* ]] &&
   [[ "$output" != *"[BLOCKED]"* ]]; then
    echo "[PASS] No packages required with incompatible repositories"
else
    echo "[FAIL] No packages required with incompatible repositories"
    exit 1
fi

# Test 11: Installation execution with no packages required.

if output="$(
    bash -c '
        set -euo pipefail

        APT_REPOSITORIES_COMPATIBLE=true
        PACKAGES_AVAILABLE=true
        INSTALL_PACKAGES=()

        start_planned_services() {
            echo "[MOCK] Services started successfully."
            return 0
        }

        source lib/install_execution.sh
        execute_installation_plan
    '
)" &&
   [[ "$output" == *"[OK] No additional packages need installation."* ]] &&
   [[ "$output" == *"[MOCK] Services started successfully."* ]] &&
   [[ "$output" == *"[OK] All planned services are running."* ]]; then
    echo "[PASS] Installation execution without additional packages"
else
    echo "[FAIL] Installation execution without additional packages"
    exit 1
fi

# Test 12: Installation stops when service startup fails.

if output="$(
    bash -c '
        set -euo pipefail

        APT_REPOSITORIES_COMPATIBLE=true
        PACKAGES_AVAILABLE=true
        INSTALL_PACKAGES=()

        start_planned_services() {
            echo "[MOCK] Service failed to start."
            return 1
        }

        source lib/install_execution.sh

        if execute_installation_plan; then
            echo "[FAIL] Installation should have stopped."
            exit 1
        else
            echo "[PASS] Installation stopped correctly."
        fi
    '
)" &&
   [[ "$output" == *"[MOCK] Service failed to start."* ]] &&
   [[ "$output" == *"[ERROR] Required services could not be started."* ]] &&
   [[ "$output" == *"[PASS] Installation stopped correctly."* ]]; then
    echo "[PASS] Installation stops on service startup failure"
else
    echo "[FAIL] Installation stops on service startup failure"
    exit 1
fi

# Test 13: Installation stops when APT simulation fails.

if output="$(
    bash -c '
        set -euo pipefail

        APT_REPOSITORIES_COMPATIBLE=true
        PACKAGES_AVAILABLE=true
        INSTALL_PACKAGES=("php8.5-cli")

        simulate_apt_package_installation() {
            echo "[MOCK] APT simulation failed."
            return 1
        }

        execute_apt_package_installation() {
            echo "[FAIL] Actual installation should not run."
            return 0
        }

        start_planned_services() {
            echo "[FAIL] Services should not start."
            return 0
        }

        source lib/install_execution.sh

        if execute_installation_plan <<< "y"; then
            echo "[FAIL] Installation should have stopped."
            exit 1
        else
            echo "[PASS] Installation stopped after simulation failure."
        fi
    '
)" &&
   [[ "$output" == *"[MOCK] APT simulation failed."* ]] &&
   [[ "$output" == *"[ERROR] APT installation simulation failed."* ]] &&
   [[ "$output" == *"[ERROR] Package preparation failed. Installation stopped."* ]] &&
   [[ "$output" == *"[PASS] Installation stopped after simulation failure."* ]] &&
   [[ "$output" != *"[FAIL]"* ]]; then
    echo "[PASS] Installation stops on APT simulation failure"
else
    echo "[FAIL] Installation stops on APT simulation failure"
    exit 1
fi

# Test 14: Installation stops when actual APT installation fails.

if output="$(
    bash -c '
        set -euo pipefail

        APT_REPOSITORIES_COMPATIBLE=true
        PACKAGES_AVAILABLE=true
        INSTALL_PACKAGES=("php8.5-cli")

        simulate_apt_package_installation() {
            echo "[MOCK] APT simulation succeeded."
            return 0
        }

        execute_apt_package_installation() {
            echo "[MOCK] Actual APT installation failed."
            return 1
        }

        start_planned_services() {
            echo "[FAIL] Services should not start."
            return 0
        }

        source lib/install_execution.sh

        if execute_installation_plan <<< $'"'"'y\ny'"'"'; then
            echo "[FAIL] Installation should have stopped."
            exit 1
        else
            echo "[PASS] Installation stopped after APT installation failure."
        fi
    '
)" &&
   [[ "$output" == *"[MOCK] APT simulation succeeded."* ]] &&
   [[ "$output" == *"[MOCK] Actual APT installation failed."* ]] &&
   [[ "$output" == *"[ERROR] Package installation failed."* ]] &&
   [[ "$output" == *"[ERROR] Package preparation failed. Installation stopped."* ]] &&
   [[ "$output" == *"[PASS] Installation stopped after APT installation failure."* ]] &&
   [[ "$output" != *"[FAIL]"* ]]; then
    echo "[PASS] Installation stops on actual APT installation failure"
else
    echo "[FAIL] Installation stops on actual APT installation failure"
    exit 1
fi

# Test 15: Successful installation execution.

if output="$(
    bash -c '
        set -euo pipefail

        APT_REPOSITORIES_COMPATIBLE=true
        PACKAGES_AVAILABLE=true
        INSTALL_PACKAGES=("php8.5-cli")

        simulate_apt_package_installation() {
            echo "[MOCK] Simulation succeeded."
            return 0
        }

        execute_apt_package_installation() {
            echo "[MOCK] Packages installed."
            return 0
        }

        start_planned_services() {
            echo "[MOCK] Services started."
            return 0
        }

        source lib/install_execution.sh
        execute_installation_plan <<< $'"'"'y\ny'"'"'
    '
)" &&
   [[ "$output" == *"[MOCK] Simulation succeeded."* ]] &&
   [[ "$output" == *"[MOCK] Packages installed."* ]] &&
   [[ "$output" == *"[MOCK] Services started."* ]] &&
   [[ "$output" == *"[OK] All planned services are running."* ]]; then
    echo "[PASS] Successful installation execution"
else
    echo "[FAIL] Successful installation execution"
    exit 1
fi

# Test 16: Drupal project creation with mocked Composer and PHP.

if output="$(
    bash -c '
        set -euo pipefail

        source lib/output.sh
        source lib/project.sh

        stub_bin="$(mktemp -d)"
        trap "rm -rf \"$stub_bin\"" EXIT
        printf "#!/usr/bin/env bash\nexit 0\n" > "$stub_bin/php8.5"
        printf "#!/usr/bin/env bash\nexit 0\n" > "$stub_bin/composer"
        chmod +x "$stub_bin/php8.5" "$stub_bin/composer"
        PATH="$stub_bin:$PATH"

        run_as_project_user() {
            printf "[MOCK] As %s:" "$1"
            shift
            printf " <%s>" "$@"
            printf "\n"
        }

        create_drupal_project "11.4.8" "/var/www/demo" "8.5" "devuser"
    '
)" &&
   [[ "$output" == *"[MOCK] As devuser: <php8.5> <"*"/composer> <create-project> <--no-interaction> <drupal/recommended-project:11.4.8> </var/www/demo>"* ]]; then
    echo "[PASS] Drupal project creation integration"
else
    echo "[FAIL] Drupal project creation integration"
    exit 1
fi

# Test 17: Drupal project creation fails when Composer fails.

if output="$(
    bash -c '
        set -euo pipefail

        source lib/output.sh
        source lib/project.sh

        stub_bin="$(mktemp -d)"
        trap "rm -rf \"$stub_bin\"" EXIT
        printf "#!/usr/bin/env bash\nexit 0\n" > "$stub_bin/php8.5"
        printf "#!/usr/bin/env bash\nexit 0\n" > "$stub_bin/composer"
        chmod +x "$stub_bin/php8.5" "$stub_bin/composer"
        PATH="$stub_bin:$PATH"

        run_as_project_user() {
            echo "[MOCK] Composer installation failed."
            return 1
        }

        if create_drupal_project "11.4.8" "/var/www/demo" "8.5" "devuser"; then
            echo "[FAIL] Composer failure was ignored."
            exit 1
        else
            echo "[PASS] Composer failure propagated."
        fi
    '
)" &&
   [[ "$output" == *"[MOCK] Composer installation failed."* ]] &&
   [[ "$output" == *"[PASS] Composer failure propagated."* ]] &&
   [[ "$output" != *"[FAIL]"* ]]; then
    echo "[PASS] Drupal project creation failure integration"
else
    echo "[FAIL] Drupal project creation failure integration"
    exit 1
fi