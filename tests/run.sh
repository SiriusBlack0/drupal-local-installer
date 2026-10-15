#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

# Each entry: "Title|command". Numbering is computed automatically.
SUITES=(
    "Bash Syntax|bash tests/syntax.sh"
    "Module Structure|bash tests/module_structure.sh"
    "ShellCheck|shellcheck -S style -x install.sh lib/*.sh tests/*.sh"
    "Project Name Functional Tests|bash tests/project_name.sh"
    "Drupal Version Selection Tests|bash tests/drupal_version_selection.sh"
    "PHP Compatibility & Selection Tests|bash tests/php_selection.sh"
    "Database Compatibility & Selection Tests|bash tests/database_selection.sh"
    "Database Configuration Tests|bash tests/database_configuration.sh"
    "Final Confirmation Tests|bash tests/final_confirmation.sh"
    "Installation Execution Tests|bash tests/install_execution.sh"
    "Service Start Tests|bash tests/service_start.sh"
    "Service Plan Tests|bash tests/service_plan.sh"
    "Preflight Tests|bash tests/preflight.sh"
    "Environment Readiness Tests|bash tests/readiness.sh"
    "Project Directory Tests|bash tests/project.sh"
    "Installation Workflow Tests|bash tests/workflow.sh"
    "Database Provisioning Tests|bash tests/database_provisioning.sh"
    "Nginx Configuration Tests|bash tests/nginx.sh"
    "PHP-FPM Configuration Tests|bash tests/php_fpm.sh"
    "Confirmation Integration Tests|bash tests/integration.sh"
    "Runtime User Tests|bash tests/runtime_user.sh"
)

echo "======================================"
echo "     Drupal Installer Test Suite"
echo "======================================"

total="${#SUITES[@]}"
index=0

for suite in "${SUITES[@]}"; do
    index=$((index + 1))
    title="${suite%%|*}"
    command="${suite#*|}"

    echo
    echo "[$index/$total] $title"

    # Word splitting is intentional: the command and its file globs expand here.
    # shellcheck disable=SC2086
    if ! $command; then
        echo
        echo "[FAILED] Suite $index/$total: $title"
        exit 1
    fi
done

echo
echo "[SUCCESS] All $total suites passed."
echo "======================================"