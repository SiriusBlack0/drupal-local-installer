#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

echo "======================================"
echo "     Drupal Installer Test Suite"
echo "======================================"

echo
echo "[1/2] Bash Syntax"
bash tests/syntax.sh

echo
echo "[2/2] ShellCheck"
shellcheck -S style install.sh lib/*.sh
echo "[OK] ShellCheck passed."

echo
echo "======================================"
echo "[SUCCESS] All checks passed."
echo "======================================"
