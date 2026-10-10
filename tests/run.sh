#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

echo "======================================"
echo "     Drupal Installer Test Suite"
echo "======================================"

echo
echo "[1/7] Bash Syntax"
bash tests/syntax.sh

echo
echo "[2/7] Module Structure"
bash tests/module_structure.sh

echo
echo "[3/7] ShellCheck"
shellcheck -S style -x install.sh
echo "[OK] ShellCheck passed."

echo
echo "[4/7] Project Name Functional Tests"
bash tests/project_name.sh

echo
echo
echo "[5/7] Drupal Version Selection Tests"
bash tests/drupal_version_selection.sh

echo "======================================"
echo
echo "[6/7] PHP Compatibility & Selection Tests"
bash tests/php_selection.sh

echo
echo "[7/7] Database Compatibility & Selection Tests"
bash tests/database_selection.sh

echo "[SUCCESS] All checks passed."
echo "======================================"
