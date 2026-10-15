#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

echo "======================================"
echo "     Drupal Installer Test Suite"
echo "======================================"

echo
echo "[1/19] Bash Syntax"
bash tests/syntax.sh

echo
echo "[2/19] Module Structure"
bash tests/module_structure.sh

echo
echo "[3/19] ShellCheck"
shellcheck -S style -x install.sh
echo "[OK] ShellCheck passed."

echo
echo "[4/19] Project Name Functional Tests"
bash tests/project_name.sh

echo
echo
echo "[5/19] Drupal Version Selection Tests"
bash tests/drupal_version_selection.sh

echo "======================================"
echo
echo "[6/19] PHP Compatibility & Selection Tests"
bash tests/php_selection.sh

echo
echo "[7/19] Database Compatibility & Selection Tests"
bash tests/database_selection.sh

echo
echo "[8/19] Database Configuration Tests"
bash tests/database_configuration.sh

echo
echo "[9/19] Final Confirmation Tests"
bash tests/final_confirmation.sh

echo
echo "[10/19] Installation Execution Tests"
bash tests/install_execution.sh

echo
echo "[11/19] Service Start Tests"
bash tests/service_start.sh

echo
echo "[12/19] Service Plan Tests"
bash tests/service_plan.sh

echo
echo "[13/19] Preflight Tests"
bash tests/preflight.sh

echo
echo "[14/19] Environment Readiness Tests"
bash tests/readiness.sh

echo
echo "[15/19] Project Directory Tests"
bash tests/project.sh

echo
echo "[16/19] Installation Workflow Tests"
bash tests/workflow.sh

echo
echo "[17/19] Database Provisioning Tests"
bash tests/database_provisioning.sh

echo
echo "[18/19] Nginx Configuration Tests"
bash tests/nginx.sh

echo
echo "[19/19] PHP-FPM Configuration Tests"
bash tests/php_fpm.sh

echo

echo "[SUCCESS] All checks passed."
echo "======================================"
