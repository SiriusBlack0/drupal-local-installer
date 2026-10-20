#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
from pathlib import Path

content = Path("install.sh").read_text()

modules = [
    "lib/output.sh",
    "lib/checklist.sh",
    "lib/drupal.sh",
    "lib/php.sh",
    "lib/php_fpm.sh",
    "lib/nginx.sh",
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
    "lib/site.sh",
    "lib/composer.sh",
    "lib/git.sh",
    "lib/scan.sh",
    "lib/remove.sh",
    "lib/update.sh",
    "lib/upgrade.sh",
    "lib/php_source.sh",
    "lib/php_change.sh",
    "lib/completion.sh",
    "lib/workflow.sh",
]

positions = []

for module in modules:
    statement = f'source "$SCRIPT_DIR/{module}"'

    assert Path(module).is_file(), f"Missing module: {module}"
    assert content.count(statement) == 1, f"Invalid source count: {module}"

    positions.append(content.index(statement))

assert positions == sorted(positions), "Incorrect module loading order"

# Loaders: lib/<name>.sh loads lib/<name>/*.sh, each once, in a fixed order.
loaders = {
    "database": ["common", "mysql", "postgresql", "sqlite"],
    "system": ["checks", "services", "apt"],
    "ui": ["project", "drupal", "php", "database", "admin", "git", "confirm"],
    "update": ["check", "backup", "snapshot", "advisories", "update"],
    "upgrade": ["checks", "upgrade_status", "composer", "upgrade"],
    "php_change": ["pool", "launchers", "checks", "php_change"],
}

loaded = set(modules)

for name, parts in loaders.items():
    text = Path(f"lib/{name}.sh").read_text()
    order = []

    for part in parts:
        statement = f'source "$(dirname "${{BASH_SOURCE[0]}}")/{name}/{part}.sh"'
        assert text.count(statement) == 1, f"lib/{name}.sh: {part}.sh not loaded once"
        order.append(text.index(statement))
        loaded.add(f"lib/{name}/{part}.sh")

    assert order == sorted(order), f"lib/{name}.sh: incorrect loading order"
    assert sorted(p.stem for p in Path(f"lib/{name}").glob("*.sh")) == sorted(parts), f"lib/{name}/: unexpected files"

every = {str(p) for p in Path("lib").rglob("*.sh")}
assert every == loaded, f"Not loaded: {sorted(every - loaded)}"

print("[PASS] All modules exist")
print("[PASS] Every module is sourced exactly once")
print("[PASS] Module execution order is correct")
print("[PASS] Folder modules: every file loaded once, in order")
PY
