#!/usr/bin/env bash
set -euo pipefail

python3 - <<'PY'
from pathlib import Path
import subprocess

source = Path("lib/ui.sh").read_text()

start = source.index("# Database name")
end = source.index("# Final configuration summary", start)
section = source[start:end]

helpers = r'''
get_project_database_name() {
    echo "test_project"
}

get_project_database_user() {
    echo "test_project_user"
}

is_valid_database_name() {
    [[ "$1" =~ ^[a-zA-Z0-9_]+$ ]]
}

is_valid_database_user() {
    [[ "$1" =~ ^[a-zA-Z0-9_]+$ ]]
}

is_valid_database_password() {
    [[ "$1" =~ ^[a-zA-Z0-9_@#%+=.-]+$ ]]
}
'''

cases = [
    (
        "SQLite configuration",
        "sqlite",
        "",
        "RESULT::::sites/default/files/.ht.sqlite",
    ),
    (
        "Suggested database credentials",
        "mariadb",
        "1\n1\nPassword123\nPassword123\n",
        "RESULT:test_project:test_project_user:Password123:",
    ),
    (
        "Custom database credentials",
        "mysql",
        "2\ncustom_db\n2\ncustom_user\nPass@123\nPass@123\n",
        "RESULT:custom_db:custom_user:Pass@123:",
    ),
    (
        "Invalid database name retry",
        "mariadb",
        "2\ninvalid-name\n2\nvalid_name\n1\nPass123\nPass123\n",
        "RESULT:valid_name:test_project_user:Pass123:",
    ),
    (
        "Password mismatch retry",
        "mariadb",
        "1\n1\nPass123\nWrong123\nPass456\nPass456\n",
        "RESULT:test_project:test_project_user:Pass456:",
    ),
]

for label, engine, user_input, expected in cases:
    script = (
        "set -e\n"
        + helpers
        + f'\nPROJECT_NAME="Test Project"\nDATABASE_ENGINE="{engine}"\n'
        + section
        + '\nprintf "RESULT:%s:%s:%s:%s\\n" '
          '"$DATABASE_NAME" "$DATABASE_USER" "$DATABASE_PASSWORD" '
          '"${SQLITE_DATABASE_PATH:-}"\n'
    )

    result = subprocess.run(
        ["bash", "-c", script],
        input=user_input,
        text=True,
        capture_output=True,
        timeout=5,
    )

    passed = (
        result.returncode == 0
        and expected in result.stdout
    )

    print(f"[{'PASS' if passed else 'FAIL'}] {label}")

    if not passed:
        print(result.stdout)
        print(result.stderr)
        raise SystemExit(1)

# EOF handling tests.
eof_cases = [
    ("Database name menu EOF", "mariadb", ""),
    ("Custom database name EOF", "mariadb", "2\n"),
    ("Database user menu EOF", "mariadb", "1\n"),
    ("Custom database user EOF", "mariadb", "1\n2\n"),
    ("Database password EOF", "mariadb", "1\n1\n"),
    ("Database password confirmation EOF", "mariadb", "1\n1\nPass123\n"),
]

for label, engine, user_input in eof_cases:
    script = (
        "set -e\n"
        + helpers
        + f'\nPROJECT_NAME="Test Project"\nDATABASE_ENGINE="{engine}"\n'
        + section
        + '\nprintf "UNEXPECTED_COMPLETION\\n"\n'
    )

    result = subprocess.run(
        ["bash", "-c", script],
        input=user_input,
        text=True,
        capture_output=True,
        timeout=5,
    )

    passed = (
        result.returncode == 0
        and "Input cancelled." in result.stdout
        and "UNEXPECTED_COMPLETION" not in result.stdout
    )

    print(f"[{'PASS' if passed else 'FAIL'}] {label}")

    if not passed:
        print(result.stdout)
        print(result.stderr)
        raise SystemExit(1)

print("\n[SUCCESS] Database configuration baseline tests passed.")
PY
