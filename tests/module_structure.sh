#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
from pathlib import Path

content = Path("install.sh").read_text()

modules = [
    "lib/drupal.sh",
    "lib/php.sh",
    "lib/database.sh",
    "lib/compatibility.sh",
    "lib/system.sh",
    "lib/registry.sh",
    "lib/packages.sh",
    "lib/ui.sh",
    "lib/preflight.sh",
    "lib/plan.sh",
    "lib/install_execution.sh",
    "lib/readiness.sh",
    "lib/project.sh",
    "lib/workflow.sh",
]

positions = []

for module in modules:
    statement = f'source "$SCRIPT_DIR/{module}"'

    assert Path(module).is_file(), f"Missing module: {module}"
    assert content.count(statement) == 1, f"Invalid source count: {module}"

    positions.append(content.index(statement))

assert positions == sorted(positions), "Incorrect module loading order"

print("[PASS] All modules exist")
print("[PASS] Every module is sourced exactly once")
print("[PASS] Module execution order is correct")
PY
