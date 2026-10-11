#!/usr/bin/env bash
set -e

python3 - <<'PY'
from pathlib import Path
import subprocess

source = Path("lib/preflight.sh").read_text()

marker = 'if [ "$DATABASE_ENGINE" != "sqlite" ]; then'
database_block = source[source.rfind(marker):]

script = '''
set -e

DATABASE_ENGINE="mariadb"
DATABASE_NEEDS_INSTALL="yes"

INSTALL_SERVICES_TO_START=()
INSTALL_SERVICES_AFTER_INSTALL=()

add_service_to_start() {
    INSTALL_SERVICES_TO_START+=("$1")
}

add_service_after_install() {
    INSTALL_SERVICES_AFTER_INSTALL+=("$1")
}

is_database_service_running() {
    return 1
}

''' + database_block + '''

printf 'AFTER_INSTALL:%s\\n' "${INSTALL_SERVICES_AFTER_INSTALL[*]}"
printf 'TO_START:%s\\n' "${INSTALL_SERVICES_TO_START[*]}"
'''

result = subprocess.run(
    ["bash", "-c", script],
    text=True,
    capture_output=True,
    timeout=5,
)

passed = (
    result.returncode == 0
    and "AFTER_INSTALL:mariadb" in result.stdout
    and "TO_START:" in result.stdout
    and "TO_START:mariadb" not in result.stdout
)

print(f"[{'PASS' if passed else 'FAIL'}] Missing MariaDB service plan")

if not passed:
    print(result.stdout)
    print(result.stderr)
    raise SystemExit(1)

# MariaDB installed but stopped.
script = '''
set -e

DATABASE_ENGINE="mariadb"
DATABASE_NEEDS_INSTALL="no"

INSTALL_SERVICES_TO_START=()
INSTALL_SERVICES_AFTER_INSTALL=()

add_service_to_start() {
    INSTALL_SERVICES_TO_START+=("$1")
}

add_service_after_install() {
    INSTALL_SERVICES_AFTER_INSTALL+=("$1")
}

is_database_service_running() {
    return 1
}

''' + database_block + '''

printf 'AFTER_INSTALL:%s\\n' "${INSTALL_SERVICES_AFTER_INSTALL[*]}"
printf 'TO_START:%s\\n' "${INSTALL_SERVICES_TO_START[*]}"
'''

result = subprocess.run(
    ["bash", "-c", script],
    text=True,
    capture_output=True,
    timeout=5,
)

passed = (
    result.returncode == 0
    and "TO_START:mariadb" in result.stdout
    and "AFTER_INSTALL:mariadb" not in result.stdout
)

print(f"[{'PASS' if passed else 'FAIL'}] Stopped MariaDB service plan")

if not passed:
    print(result.stdout)
    print(result.stderr)
    raise SystemExit(1)

# MariaDB already running.
script = '''
set -e

DATABASE_ENGINE="mariadb"
DATABASE_NEEDS_INSTALL="no"

INSTALL_SERVICES_TO_START=()
INSTALL_SERVICES_AFTER_INSTALL=()

add_service_to_start() {
    INSTALL_SERVICES_TO_START+=("$1")
}

add_service_after_install() {
    INSTALL_SERVICES_AFTER_INSTALL+=("$1")
}

is_database_service_running() {
    return 0
}

''' + database_block + '''

printf 'AFTER_INSTALL:%s\\n' "${INSTALL_SERVICES_AFTER_INSTALL[*]}"
printf 'TO_START:%s\\n' "${INSTALL_SERVICES_TO_START[*]}"
'''

result = subprocess.run(
    ["bash", "-c", script],
    text=True,
    capture_output=True,
    timeout=5,
)

passed = (
    result.returncode == 0
    and "AFTER_INSTALL:" in result.stdout
    and "TO_START:" in result.stdout
    and "AFTER_INSTALL:mariadb" not in result.stdout
    and "TO_START:mariadb" not in result.stdout
)

print(f"[{'PASS' if passed else 'FAIL'}] Running MariaDB service plan")

if not passed:
    print(result.stdout)
    print(result.stderr)
    raise SystemExit(1)

# SQLite requires no database service.
script = '''
set -e

DATABASE_ENGINE="sqlite"
DATABASE_NEEDS_INSTALL="no"

INSTALL_SERVICES_TO_START=()
INSTALL_SERVICES_AFTER_INSTALL=()

add_service_to_start() {
    INSTALL_SERVICES_TO_START+=("$1")
}

add_service_after_install() {
    INSTALL_SERVICES_AFTER_INSTALL+=("$1")
}

is_database_service_running() {
    echo "UNEXPECTED_DATABASE_CHECK"
    return 0
}

''' + database_block + '''

printf 'AFTER_INSTALL:%s\\n' "${INSTALL_SERVICES_AFTER_INSTALL[*]}"
printf 'TO_START:%s\\n' "${INSTALL_SERVICES_TO_START[*]}"
'''

result = subprocess.run(
    ["bash", "-c", script],
    text=True,
    capture_output=True,
    timeout=5,
)

passed = (
    result.returncode == 0
    and "AFTER_INSTALL:" in result.stdout
    and "TO_START:" in result.stdout
    and "UNEXPECTED_DATABASE_CHECK" not in result.stdout
    and "AFTER_INSTALL:sqlite" not in result.stdout
    and "TO_START:sqlite" not in result.stdout
)

print(f"[{'PASS' if passed else 'FAIL'}] SQLite service plan")

if not passed:
    print(result.stdout)
    print(result.stderr)
    raise SystemExit(1)

PY
