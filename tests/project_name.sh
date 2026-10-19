#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
from pathlib import Path
import subprocess

source = "".join(Path(f"lib/ui/{p}.sh").read_text() for p in ("project", "drupal", "php", "database", "admin", "confirm"))

start = source.index("prompt_project_name() {")
end = source.index("# Drupal version selection", start)

function = source[start:end]

cases = [
    ("My Project", True),
    ("drupal_11", True),
    ("project-123", True),
    ("", False),
    ("-invalid", False),
    ("invalid!", False),
    ("Taken", False),
]

for name, valid in cases:
    script = f'''
set -e
get_project_machine_name() {{
    printf '%s' "$1"
}}
get_project_path() {{
    printf '/var/www/%s' "$1"
}}
get_project_conflict() {{
    if [[ "$1" == "Taken" ]]; then
        echo "Project directory '/var/www/$1' already exists."
        return 0
    fi
    return 1
}}
{function}
prompt_project_name
printf 'RESULT:%s' "$PROJECT_NAME"
'''

    # Invalid inputs are followed by a valid name to test retry behavior.
    user_input = name + "\n" + ("" if valid else "ValidProject\n")

    result = subprocess.run(
        ["bash", "-c", script],
        input=user_input,
        text=True,
        capture_output=True,
        timeout=5,
    )

    expected = name if valid else "ValidProject"

    passed = (
        result.returncode == 0
        and f"RESULT:{expected}" in result.stdout
    )

    if name == "Taken":
        passed = passed and "Choose another project name." in result.stdout

    print(f"[{'PASS' if passed else 'FAIL'}] Input: {name!r}")

    if not passed:
        print(result.stdout)
        print(result.stderr)
        raise SystemExit(1)

print("\n[SUCCESS] Project name functional tests passed.")
script = f'''
set -e
get_project_machine_name() {{
    printf '%s' "$1"
}}
get_project_path() {{
    printf '/var/www/%s' "$1"
}}
get_project_conflict() {{
    if [[ "$1" == "Taken" ]]; then
        echo "Project directory '/var/www/$1' already exists."
        return 0
    fi
    return 1
}}
{function}
prompt_project_name
'''

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

print(f"[{'PASS' if passed else 'FAIL'}] EOF handling")

if not passed:
    raise SystemExit(1)
PY
