#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

echo "======================================"
echo "     Drupal Installer Test Suite"
echo "======================================"

echo
echo "[1/6] Bash Syntax"
bash tests/syntax.sh

echo
echo "[2/6] Module Structure"
bash tests/module_structure.sh

echo
echo "[3/6] ShellCheck"
shellcheck -S style -x install.sh
echo "[OK] ShellCheck passed."

echo
echo "[4/6] Project Name Functional Tests"
bash tests/project_name.sh

echo
echo
echo "[5/6] Drupal Version Selection Tests"
bash tests/drupal_version_selection.sh

echo "======================================"
echo
echo "[6/6] PHP Compatibility & Selection Tests"
bash tests/php_selection.sh

echo "[SUCCESS] All checks passed."
echo "======================================"
