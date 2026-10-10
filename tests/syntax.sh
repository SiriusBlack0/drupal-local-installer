#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

echo "Checking Bash syntax..."

for file in install.sh lib/*.sh; do
    if bash -n "$file"; then
        echo "[OK] $file"
    else
        echo "[ERROR] $file"
        exit 1
    fi
done

echo
echo "[SUCCESS] All Bash syntax checks passed."
