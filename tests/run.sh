#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

echo "======================================"
echo "     Drupal Installer Test Suite"
echo "======================================"

echo
echo "[1/16] Bash Syntax"
bash tests/syntax.sh

echo
echo "[2/16] Module Structure"
bash tests/module_structure.sh

echo
echo "[3/16] ShellCheck"
shellcheck -S style -x install.sh
echo "[OK] ShellCheck passed."

echo
echo "[4/16] Project Name Functional Tests"
bash tests/project_name.sh

echo
echo
echo "[5/16] Drupal Version Selection Tests"
bash tests/drupal_version_selection.sh

echo "======================================"
echo
echo "[6/16] PHP Compatibility & Selection Tests"
bash tests/php_selection.sh

echo
echo "[7/16] Database Compatibility & Selection Tests"
bash tests/database_selection.sh

echo
echo "[8/16] Database Configuration Tests"
bash tests/database_configuration.sh

echo
echo "[9/16] Final Confirmation Tests"
bash tests/final_confirmation.sh

echo
echo "[10/16] Installation Execution Tests"
bash tests/install_execution.sh

echo
echo "[11/16] Service Start Tests"
bash tests/service_start.sh

echo
echo "[12/16] Service Plan Tests"
bash tests/service_plan.sh

echo
echo "[13/16] Preflight Tests"
bash tests/preflight.sh

echo
echo "[14/16] Environment Readiness Tests"
bash tests/readiness.sh

echo
echo "[15/16] Project Directory Tests"
bash tests/project.sh

echo
echo "[16/16] Installation Workflow Tests"
bash tests/workflow.sh

echo "[SUCCESS] All checks passed."
echo "======================================"
