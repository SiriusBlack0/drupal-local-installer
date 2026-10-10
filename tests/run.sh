#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

echo "======================================"
echo "     Drupal Installer Test Suite"
echo "======================================"

echo
echo "[1/4] Bash Syntax"
bash tests/syntax.sh

echo
echo "[2/4] Module Structure"
bash tests/module_structure.sh

echo
echo "[3/4] ShellCheck"
shellcheck -S style -x install.sh
echo "[OK] ShellCheck passed."

echo
echo "[4/4] Project Name Functional Tests"
bash tests/project_name.sh

echo
echo "======================================"
echo "[SUCCESS] All checks passed."
echo "======================================"
