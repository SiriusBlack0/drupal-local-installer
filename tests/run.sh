#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

echo "======================================"
echo "     Drupal Installer Test Suite"
echo "======================================"

echo
echo "[1/8] Bash Syntax"
bash tests/syntax.sh

echo
echo "[2/8] Module Structure"
bash tests/module_structure.sh

echo
echo "[3/8] ShellCheck"
shellcheck -S style -x install.sh
echo "[OK] ShellCheck passed."

echo
echo "[4/8] Project Name Functional Tests"
bash tests/project_name.sh

echo
echo
echo "[5/8] Drupal Version Selection Tests"
bash tests/drupal_version_selection.sh

echo "======================================"
echo
echo "[6/8] PHP Compatibility & Selection Tests"
bash tests/php_selection.sh

echo
echo "[7/8] Database Compatibility & Selection Tests"
bash tests/database_selection.sh

echo
echo "[8/8] Database Configuration Tests"
bash tests/database_configuration.sh

echo "[SUCCESS] All checks passed."
echo "======================================"
