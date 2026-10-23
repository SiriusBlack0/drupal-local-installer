#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
from pathlib import Path
import subprocess

source = "".join(Path(f"lib/ui/{p}.sh").read_text() for p in ("project", "drupal", "php", "database", "admin", "confirm"))

start = source.index("read_drupal_input() {")
end = source.index("# PHP compatibility", start)

functions = source[start:end]

mock_helpers = '''
get_drupal_versions() {
    case "$1" in
        11) printf '%s\\n' 11.4.9 11.4.8 11.0.11 ;;
        10) printf '%s\\n' 10.6.2 10.0.0 ;;
    esac
}

get_drupal_minor_versions() {
    case "$1" in
        11) printf '%s\\n' 11.4 11.0 ;;
        10) printf '%s\\n' 10.6 10.0 ;;
    esac
}

drupal_version_exists() {
    case "$1" in
        11.4.9|11.4.8|11.0.11|10.6.2|10.0.0)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}
'''

cases = [
    ("Latest stable", "1\n", "11.4.9"),
    ("Major/minor/patch", "2\n1\n1\n1\n", "11.4.9"),
    ("Older patch (second in the list)", "2\n1\n1\n2\n", "11.4.8"),
    ("Patch number past the list", "2\n1\n1\n3\n1\n", "11.4.9"),
    ("Exact version", "3\n11.0.11\n", "11.0.11"),
    ("Invalid menu", "9\n1\n", "11.4.9"),
    ("Invalid exact format", "3\nbanana\n11.0.11\n", "11.0.11"),
    ("Nonexistent version", "3\n99.0.0\n11.0.11\n", "11.0.11"),
]

for label, user_input, expected in cases:
    script = (
        "set -e\n"
        + mock_helpers
        + "\n"
        + functions
        + "\nprompt_drupal_version\n"
        + 'printf "RESULT:%s\\n" "$DRUPAL_VERSION"\n'
    )

    try:
        result = subprocess.run(
            ["bash", "-c", script],
            input=user_input,
            text=True,
            capture_output=True,
            timeout=5,
        )
    except subprocess.TimeoutExpired:
        print(f"[FAIL] {label}: timed out")
        raise SystemExit(1)

    passed = (
        result.returncode == 0
        and f"RESULT:{expected}\n" in result.stdout
    )

    # The patch list shows each version once: "1) 11.4.9 (latest)".
    if label.startswith(("Major/minor/patch", "Older patch", "Patch number")):
        passed = (
            passed
            and "1) 11.4.9 (latest)\n" in result.stdout
            and "2) 11.4.8\n" in result.stdout
            and "Latest (" not in result.stdout
        )

    if label == "Patch number past the list":
        passed = passed and "Invalid selection. Try again." in result.stdout

    print(f"[{'PASS' if passed else 'FAIL'}] {label}")

    if not passed:
        print(result.stdout[-2000:])
        print(result.stderr[-2000:])
        raise SystemExit(1)

eof_cases = [
    ("Main menu EOF", ""),
    ("Major selection EOF", "2\n"),
    ("Minor selection EOF", "2\n1\n"),
    ("Patch selection EOF", "2\n1\n1\n"),
    ("Exact version EOF", "3\n"),
]

for label, user_input in eof_cases:
    script = (
        "set -e\n"
        + mock_helpers
        + "\n"
        + functions
        + "\nprompt_drupal_version\n"
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
    )

    print(f"[{'PASS' if passed else 'FAIL'}] {label}")

    if not passed:
        print(result.stdout)
        print(result.stderr)
        raise SystemExit(1)
print("\n[SUCCESS] Drupal version selection tests passed.")
PY
