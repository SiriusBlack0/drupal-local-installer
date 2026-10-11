#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

echo "======================================"
echo "     Drupal Installer Test Suite"
echo "======================================"

echo
echo "[1/14] Bash Syntax"
bash tests/syntax.sh

echo
echo "[2/14] Module Structure"
bash tests/module_structure.sh

echo
echo "[3/14] ShellCheck"
shellcheck -S style -x install.sh
echo "[OK] ShellCheck passed."

echo
echo "[4/14] Project Name Functional Tests"
bash tests/project_name.sh

echo
echo
echo "[5/14] Drupal Version Selection Tests"
bash tests/drupal_version_selection.sh

echo "======================================"
echo
echo "[6/14] PHP Compatibility & Selection Tests"
bash tests/php_selection.sh

echo
echo "[7/14] Database Compatibility & Selection Tests"
bash tests/database_selection.sh

echo
echo "[8/14] Database Configuration Tests"
bash tests/database_configuration.sh

echo
echo "[9/14] Final Confirmation Tests"
bash tests/final_confirmation.sh

echo
echo "[10/14] Installation Execution Tests"
bash tests/install_execution.sh

echo
echo "[11/14] Service Start Tests"
bash tests/service_start.sh

echo
echo "[12/14] Service Plan Tests"
bash tests/service_plan.sh

echo
echo "[13/14] Preflight Tests"
bash tests/preflight.sh

echo
echo "[14/14] Environment Readiness Tests"
bash tests/readiness.sh

echo "[SUCCESS] All checks passed."
echo "======================================"
