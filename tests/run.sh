#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

echo "======================================"
echo "     Drupal Installer Test Suite"
echo "======================================"

echo
echo "[1/17] Bash Syntax"
bash tests/syntax.sh

echo
echo "[2/17] Module Structure"
bash tests/module_structure.sh

echo
echo "[3/17] ShellCheck"
shellcheck -S style -x install.sh
echo "[OK] ShellCheck passed."

echo
echo "[4/17] Project Name Functional Tests"
bash tests/project_name.sh

echo
echo
echo "[5/17] Drupal Version Selection Tests"
bash tests/drupal_version_selection.sh

echo "======================================"
echo
echo "[6/17] PHP Compatibility & Selection Tests"
bash tests/php_selection.sh

echo
echo "[7/17] Database Compatibility & Selection Tests"
bash tests/database_selection.sh

echo
echo "[8/17] Database Configuration Tests"
bash tests/database_configuration.sh

echo
echo "[9/17] Final Confirmation Tests"
bash tests/final_confirmation.sh

echo
echo "[10/17] Installation Execution Tests"
bash tests/install_execution.sh

echo
echo "[11/17] Service Start Tests"
bash tests/service_start.sh

echo
echo "[12/17] Service Plan Tests"
bash tests/service_plan.sh

echo
echo "[13/17] Preflight Tests"
bash tests/preflight.sh

echo
echo "[14/17] Environment Readiness Tests"
bash tests/readiness.sh

echo
echo "[15/17] Project Directory Tests"
bash tests/project.sh

echo
echo "[16/17] Installation Workflow Tests"
bash tests/workflow.sh

echo
echo "[17/17] Database Provisioning Tests"
bash tests/database_provisioning.sh

echo

echo "[SUCCESS] All checks passed."
echo "======================================"
