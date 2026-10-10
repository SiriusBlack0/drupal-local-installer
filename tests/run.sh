#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

echo "======================================"
echo "     Drupal Installer Test Suite"
echo "======================================"

echo
echo "[1/10] Bash Syntax"
bash tests/syntax.sh

echo
echo "[2/10] Module Structure"
bash tests/module_structure.sh

echo
echo "[3/10] ShellCheck"
shellcheck -S style -x install.sh
echo "[OK] ShellCheck passed."

echo
echo "[4/10] Project Name Functional Tests"
bash tests/project_name.sh

echo
echo
echo "[5/10] Drupal Version Selection Tests"
bash tests/drupal_version_selection.sh

echo "======================================"
echo
echo "[6/10] PHP Compatibility & Selection Tests"
bash tests/php_selection.sh

echo
echo "[7/10] Database Compatibility & Selection Tests"
bash tests/database_selection.sh

echo
echo "[8/10] Database Configuration Tests"
bash tests/database_configuration.sh

echo
echo "[9/10] Final Confirmation Tests"
bash tests/final_confirmation.sh

echo
echo "[10/10] Installation Execution Tests"
bash tests/install_execution.sh

echo "[SUCCESS] All checks passed."
echo "======================================"
