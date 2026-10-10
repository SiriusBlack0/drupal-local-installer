#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
from pathlib import Path
import subprocess

source = Path("lib/ui.sh").read_text()
start = source.index('detect_php_requirements() {')
end = source.index("# Database compatibility", start)

# Exclude the separator immediately before Database compatibility.
section = source[start:end]

helpers = r'''
get_drupal_php_constraint() {
    case "$1" in
        11.4.9) echo ">=8.3.0" ;;
        11.0.11) echo ">=8.3.0" ;;
        99.0.0) echo "" ;;
        *) echo ">=8.1.0" ;;
    esac
}

get_drupal_minor() {
    printf '%s\n' "${1%.*}"
}

has_php_support_policy() {
    [[ "$1" == "11.4" ]]
}

get_supported_php_versions() {
    printf '%s\n' 8.3 8.4 8.5
}

get_compatible_php_versions() {
    printf '%s\n' 8.3 8.5
}

get_php_version_status() {
    case "$1" in
        8.5) echo installed ;;
        *) echo available ;;
    esac
}
'''

cases = [
    ("Supported PHP selection", "11.4.9", "3\n", 0, "8.5"),
    ("Invalid selection retry", "11.4.9", "9\n3\n", 0, "8.5"),
    ("Legacy fallback accepted", "11.0.11", "y\n2\n", 0, "8.5"),
    ("Legacy fallback rejected", "11.0.11", "n\n", 0, None),
    ("Missing PHP constraint", "99.0.0", "", 1, None),
    ("Legacy fallback EOF", "11.0.11", "", 0, None),
    ("PHP selection EOF", "11.4.9", "", 0, None),
]

# Run the existing PHP selection tests.
for label, drupal_version, user_input, expected_code, expected_php in cases:
    script = (
        "set -e\n"
        + helpers
        + f'\nDRUPAL_VERSION="{drupal_version}"\n'
        + section
        + '\nprintf "RESULT:%s:%s\\n" "$PHP_VERSION" "$PHP_STATUS"\n'
    )

    result = subprocess.run(
        ["bash", "-c", script],
        input=user_input,
        text=True,
        capture_output=True,
        timeout=5,
    )

    passed = result.returncode == expected_code

    if expected_php is not None:
        passed = passed and f"RESULT:{expected_php}:" in result.stdout

    if "EOF" in label:
        passed = passed and "Input cancelled." in result.stdout

    print(f"[{'PASS' if passed else 'FAIL'}] {label}")

    if not passed:
        print(result.stdout)
        print(result.stderr)
        raise SystemExit(1)


# Test when no compatible PHP versions are available.
script = (
    "set -e\n"
    + helpers
    + '\nget_supported_php_versions() { return 0; }\n'
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
    and "No compatible PHP-FPM version was found" in result.stdout
)

print(f"[{'PASS' if passed else 'FAIL'}] No compatible PHP versions")

if not passed:
    print(result.stdout)
    print(result.stderr)
    raise SystemExit(1)

print("\n[SUCCESS] PHP selection functional tests passed.")
PY
