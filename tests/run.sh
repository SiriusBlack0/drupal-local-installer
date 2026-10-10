#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

echo "======================================"
echo "     Drupal Installer Test Suite"
echo "======================================"

echo
echo "[1/9] Bash Syntax"
bash tests/syntax.sh

echo
echo "[2/9] Module Structure"
bash tests/module_structure.sh

echo
echo "[3/9] ShellCheck"
shellcheck -S style -x install.sh
echo "[OK] ShellCheck passed."

echo
echo "[4/9] Project Name Functional Tests"
bash tests/project_name.sh

echo
echo
echo "[5/9] Drupal Version Selection Tests"
bash tests/drupal_version_selection.sh

echo "======================================"
echo
echo "[6/9] PHP Compatibility & Selection Tests"
bash tests/php_selection.sh

echo
echo "[7/9] Database Compatibility & Selection Tests"
bash tests/database_selection.sh

echo
echo "[8/9] Database Configuration Tests"
bash tests/database_configuration.sh

echo
echo "[9/9] Final Confirmation Tests"
bash tests/final_confirmation.sh

echo "[SUCCESS] All checks passed."
echo "======================================"
