#!/usr/bin/env bash
set -euo pipefail

python3 - <<'PY'
from pathlib import Path
import subprocess

source = "".join(Path(f"lib/ui/{p}.sh").read_text() for p in ("project", "drupal", "php", "database", "admin", "confirm"))
start = source.index("# Final configuration summary")
section = source[start:]
calls = "\nconfirm_installation\n"

cases = [
    ("Yes confirmation", "mariadb", "y\n", True),
    ("Uppercase Yes", "mariadb", "Y\n", True),
    ("Enter confirmation", "mariadb", "\n", True),
    ("No confirmation", "mariadb", "n\n", False),
    ("Uppercase No", "mariadb", "N\n", False),
    ("Invalid selection retry", "mariadb", "invalid\ny\n", True),
    ("SQLite summary", "sqlite", "y\n", True),
]

for label, engine, user_input, should_continue in cases:
    variables = f'''
PROJECT_NAME="Test Project"
PROJECT_MACHINE_NAME="test_project"
DRUPAL_VERSION="11.4.9"
PHP_VERSION="8.5"
PHP_STATUS="installed"
DATABASE_ENGINE="{engine}"
DATABASE_VERSION="11.8.6"
DATABASE_STATUS="installed"
DATABASE_NAME="test_project"
DATABASE_USER="test_project_user"
SQLITE_DATABASE_PATH="sites/default/files/.ht.sqlite"
'''

    script = (
        "set -e\n"
        + variables
        + section
        + calls
        + '\nprintf "INSTALLATION_CONFIRMED\\n"\n'
    )

    result = subprocess.run(
        ["bash", "-c", script],
        input=user_input,
        text=True,
        capture_output=True,
        timeout=5,
    )

    if should_continue:
        passed = (
            result.returncode == 0
            and "INSTALLATION_CONFIRMED" in result.stdout
        )
    else:
        passed = (
            result.returncode == 0
            and "Installation cancelled." in result.stdout
            and "INSTALLATION_CONFIRMED" not in result.stdout
        )

    if label == "Invalid selection retry":
        passed = passed and "Please enter y or n." in result.stdout

    if label == "SQLite summary":
        passed = (
            passed
            and "DB File:  sites/default/files/.ht.sqlite" in result.stdout
            and "DB User:" not in result.stdout
        )

    print(f"[{'PASS' if passed else 'FAIL'}] {label}")

    if not passed:
        print(result.stdout)
        print(result.stderr)
        raise SystemExit(1)

# EOF handling test.
script = '''
set -e

PROJECT_NAME="Test Project"
PROJECT_MACHINE_NAME="test_project"
DRUPAL_VERSION="11.4.9"
PHP_VERSION="8.5"
PHP_STATUS="installed"
DATABASE_ENGINE="mariadb"
DATABASE_VERSION="11.8.6"
DATABASE_STATUS="installed"
DATABASE_NAME="test_project"
DATABASE_USER="test_project_user"
SQLITE_DATABASE_PATH="sites/default/files/.ht.sqlite"
''' + section + calls + '\nprintf "UNEXPECTED_INSTALLATION\\n"\n'

result = subprocess.run(
    ["bash", "-c", script],
    input="",
    text=True,
    capture_output=True,
    timeout=5,
)

passed = (
    result.returncode == 0
    and "Input cancelled." in result.stdout
    and "UNEXPECTED_INSTALLATION" not in result.stdout
)

print(f"[{'PASS' if passed else 'FAIL'}] Final confirmation EOF")

if not passed:
    print(result.stdout)
    print(result.stderr)
    raise SystemExit(1)

print("\n[SUCCESS] Final confirmation baseline tests passed.")
PY
