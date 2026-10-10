#!/usr/bin/env bash
set -euo pipefail

python3 - <<'PY'
from pathlib import Path
import subprocess

source = Path("lib/ui.sh").read_text()

start = source.index("# Database compatibility")
end = source.index("# Database installation state", start)

section = source[start:end]

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

print("\n[SUCCESS] Database selection baseline tests passed.")
PY
