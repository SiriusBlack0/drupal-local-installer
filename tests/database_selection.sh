#!/usr/bin/env bash
set -euo pipefail

python3 - <<'PY'
from pathlib import Path
import subprocess

source = Path("lib/ui.sh").read_text()

start = source.index("# Database compatibility")
end = source.index("# Database installation state", start)

section = source[start:end]
calls = "\ndetect_compatible_databases\nprompt_database_selection\n"

helpers = r'''
get_compatible_database_options() {
    printf '%s\n' \
        'mariadb|11.8.6|installed' \
        'mysql|8.4|available'
}
'''

cases = [
    ("MariaDB selection", "1\n", "mariadb:11.8.6:installed"),
    ("MySQL selection", "2\n", "mysql:8.4:available"),
    ("Invalid selection retry", "9\n1\n", "mariadb:11.8.6:installed"),
    ("Non-numeric selection retry", "abc\n2\n", "mysql:8.4:available"),
]

for label, user_input, expected in cases:
    script = (
        "set -e\n"
        + helpers
        + '\nDRUPAL_VERSION="11.4.9"\n'
        + section
        + calls
        + '\nprintf "RESULT:%s:%s:%s\\n" '
          '"$DATABASE_ENGINE" "$DATABASE_VERSION" "$DATABASE_STATUS"\n'
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
        and f"RESULT:{expected}" in result.stdout
    )

    print(f"[{'PASS' if passed else 'FAIL'}] {label}")

    if not passed:
        print(result.stdout)
        print(result.stderr)
        raise SystemExit(1)

# Test EOF during database selection.
script = (
    "set -e\n"
    + helpers
    + '\nDRUPAL_VERSION="11.4.9"\n'
    + section
    + calls
)

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
)

print(f"[{'PASS' if passed else 'FAIL'}] Database selection EOF")

if not passed:
    print(result.stdout)
    print(result.stderr)
    raise SystemExit(1)


# Test when no compatible databases are found.
script = (
    "set -e\n"
    + helpers
    + '\nget_compatible_database_options() { return 0; }\n'
    + '\nDRUPAL_VERSION="11.4.9"\n'
    + section
    + calls
)

result = subprocess.run(
    ["bash", "-c", script],
    input="",
    text=True,
    capture_output=True,
    timeout=5,
)

passed = (
    result.returncode == 1
    and "No compatible database options were found." in result.stdout
)

print(f"[{'PASS' if passed else 'FAIL'}] No compatible databases")

if not passed:
    print(result.stdout)
    print(result.stderr)
    raise SystemExit(1)

# MySQL conflicts with the installed MariaDB: shown in the list,
# refused with an explanation and the DDEV alternative, asked again.
conflict_helpers = r'''
get_compatible_database_options() {
    printf '%s\n' \
        'mariadb|11.8.6|installed' \
        'mysql|8.4.11|conflict' \
        'postgresql|18|available'
}
get_conflicting_database_engine() {
    case "$1" in mariadb) echo mysql ;; mysql) echo mariadb ;; *) return 1 ;; esac
}
'''

script = (
    "set -e\n"
    + conflict_helpers
    + '\nDRUPAL_VERSION="11.4.9"\n'
    + section
    + calls
    + '\nprintf "RESULT:%s:%s:%s\\n" '
      '"$DATABASE_ENGINE" "$DATABASE_VERSION" "$DATABASE_STATUS"\n'
)

result = subprocess.run(
    ["bash", "-c", script],
    input="2\n1\n",
    text=True,
    capture_output=True,
    timeout=5,
)

checks = {
    "listed as conflict": "2) mysql 8.4.11 [conflicts with installed mariadb]" in result.stdout,
    "refused": "[NOT POSSIBLE] mysql cannot be installed next to the installed mariadb." in result.stdout,
    "explains why": "/var/lib/mysql" in result.stdout and "break every project" in result.stdout,
    "offers the installed engine": "Use mariadb for this project." in result.stdout,
    "offers DDEV with the version": "ddev config --database=mysql:8.4" in result.stdout,
    "asked again, MariaDB chosen": "RESULT:mariadb:11.8.6:installed" in result.stdout,
}

passed = result.returncode == 0 and all(checks.values())
print(f"[{'PASS' if passed else 'FAIL'}] Conflicting database refused with explanation and DDEV alternative")

if not passed:
    print({k: v for k, v in checks.items() if not v})
    print(result.stdout)
    print(result.stderr)
    raise SystemExit(1)

# Too old for Drupal 11 (Ubuntu 22.04): listed with the reason, refused
# with alternatives, asked again.
old_helpers = r'''
get_compatible_database_options() {
    printf '%s\n' \
        'mysql|8.0.46|installed' \
        'postgresql|14|too_old' \
        'sqlite|3.37.2|too_old'
}
get_conflicting_database_engine() { return 1; }
get_database_minimum_version() {
    case "$1:$2" in
        11:postgresql) echo 16 ;; 11:sqlite) echo 3.45 ;; 11:mysql) echo 8.0 ;;
        10:postgresql) echo 12 ;; 10:sqlite) echo 3.26 ;; 10:mysql) echo 5.7.8 ;;
        *) return 1 ;;
    esac
}
database_version_meets_minimum() {
    [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n 1)" == "$2" ]]
}
print_container_hint() { echo "CONTAINER HINT"; }
'''

def run_old(user_input, options=None):
    helpers = old_helpers
    if options is not None:
        helpers += "\nget_compatible_database_options() { printf '%s\\n' " + options + "; }\n"
    script = (
        "set -e\n" + helpers + '\nDRUPAL_VERSION="11.4.10"\n' + section + calls
        + '\nprintf "RESULT:%s:%s:%s\\n" "$DATABASE_ENGINE" "$DATABASE_VERSION" "$DATABASE_STATUS"\n'
    )
    return subprocess.run(["bash", "-c", script], input=user_input, text=True,
                          capture_output=True, timeout=5)

result = run_old("2\n3\n1\n")
checks = {
    "postgres listed": "2) postgresql 14 [too old: Drupal 11 needs 16+]" in result.stdout,
    "sqlite listed": "3) sqlite 3.37.2 [too old: Drupal 11 needs 3.45+]" in result.stdout,
    "postgres refused": "[TOO OLD] This system provides postgresql 14; Drupal 11 needs 16 or newer." in result.stdout,
    "postgres repo hint": "postgresql.org/download/linux/ubuntu" in result.stdout,
    "ddev for postgres": "ddev config --database=postgres:16" in result.stdout,
    "older drupal": "Choose Drupal 10 instead: it supports postgresql 12 and newer." in result.stdout,
    "sqlite explained": "SQLite is part of the system" in result.stdout,
    "sqlite older drupal": "it supports sqlite 3.26 and newer." in result.stdout,
    "asked again": "RESULT:mysql:8.0.46:installed" in result.stdout,
}
passed = result.returncode == 0 and all(checks.values())
print(f"[{'PASS' if passed else 'FAIL'}] Too old databases listed and refused with alternatives")
if not passed:
    print({k: v for k, v in checks.items() if not v})
    print(result.stdout, result.stderr)
    raise SystemExit(1)

# Nothing usable at all: explained, container hint, exit 1.
result = run_old("", "'postgresql|14|too_old' 'sqlite|3.37.2|too_old'")
passed = (result.returncode == 1
          and "No database on this system can be used for Drupal 11." in result.stdout
          and "postgresql 14: too_old" in result.stdout
          and "CONTAINER HINT" in result.stdout)
print(f"[{'PASS' if passed else 'FAIL'}] No usable database: explained, with container hint")
if not passed:
    print(result.stdout, result.stderr)
    raise SystemExit(1)

print("\n[SUCCESS] Database selection baseline tests passed.")
PY
