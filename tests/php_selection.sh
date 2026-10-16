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
calls = "\ndetect_php_requirements\nresolve_compatible_php_versions\nprompt_php_version\n"

# Mocked system: PHP 8.5 installed, 8.4 installable, everything else missing.
helpers = r'''
get_drupal_php_constraint() {
    case "$1" in
        99.0.0) echo "" ;;
        *) echo ">=8.1.0" ;;
    esac
}

get_drupal_minor() {
    printf '%s\n' "${1%.*}"
}

has_php_support_policy() {
    [[ "$1" == "11.4" || "$1" == "10.4" ]]
}

get_supported_drupal_minors() {
    printf '%s\n' 10.4 11.4
}

get_supported_php_versions() {
    case "$1" in
        11.4) printf '%s\n' 8.3 8.4 8.5 ;;
        10.4) printf '%s\n' 8.1 8.2 8.3 8.4 ;;
        *) return 1 ;;
    esac
}

get_php_candidate_versions() {
    printf '%s\n' 8.4 8.5
}

get_php_version_status() {
    case "$1" in
        8.5) echo installed ;;
        8.4) echo available ;;
        *) echo not_available ;;
    esac
}
'''

# Only PHP 8.5 exists on the system (like a fresh Ubuntu 26.04).
only_85 = r'''
get_php_candidate_versions() {
    printf '%s\n' 8.5
}

get_php_version_status() {
    case "$1" in
        8.5) echo installed ;;
        *) echo not_available ;;
    esac
}
'''

# (label, drupal version, extra mocks, input, exit code, expected PHP,
#  text that must appear, text that must not appear)
cases = [
    ("Supported PHP selection", "11.4.9", "", "2\n", 0, "8.5",
     "Drupal 11.4.9 supports PHP: 8.3 8.4 8.5", None),
    ("Invalid selection retry", "11.4.9", "", "9\n2\n", 0, "8.5",
     "Invalid selection. Try again.", None),
    ("Unavailable PHP versions are not offered", "11.4.9", "", "1\n", 0, "8.4",
     "Not available on this system: 8.3", "PHP 8.3 ["),
    ("Unsupported Drupal release rejected", "9.0.0", "", "", 1, None,
     "[UNSUPPORTED] Drupal 9.0 is not supported", "Select PHP version"),
    ("Missing PHP shows required versions", "10.4.1", only_85, "", 1, None,
     "Required PHP version(s): 8.1 8.2 8.3 8.4", "Select PHP version"),
    ("Missing PHP lists what the system has", "10.4.1", only_85, "", 1, None,
     "PHP versions on this system or in its package sources: 8.5", None),
    ("Unsupported release suggests containers", "9.0.0", "", "", 1, None,
     "Best practice: a container-based setup", None),
    ("Missing PHP suggests containers", "10.4.1", only_85, "", 1, None,
     "Best practice: a container-based setup", None),
    ("Supported setup shows no container hint", "11.4.9", "", "2\n", 0, "8.5",
     None, "Best practice"),
    ("Missing PHP constraint", "99.0.0", "", "", 1, None,
     "Could not determine PHP requirements", None),
    ("PHP selection EOF", "11.4.9", "", "", 0, None,
     "Input cancelled.", None),
]

for label, version, extra, user_input, code, php, must, must_not in cases:
    script = (
        "set -e\n"
        + helpers
        + extra
        + f'\nDRUPAL_VERSION="{version}"\n'
        + section
        + calls
        + '\nprintf "RESULT:%s:%s\\n" "$PHP_VERSION" "$PHP_STATUS"\n'
    )

    result = subprocess.run(
        ["bash", "-c", script],
        input=user_input,
        text=True,
        capture_output=True,
        timeout=5,
    )

    passed = result.returncode == code

    if php is not None:
        passed = passed and f"RESULT:{php}:" in result.stdout

    if must is not None:
        passed = passed and must in result.stdout

    if must_not is not None:
        passed = passed and must_not not in result.stdout

    print(f"[{'PASS' if passed else 'FAIL'}] {label}")

    if not passed:
        print(result.stdout)
        print(result.stderr)
        raise SystemExit(1)

print("\n[SUCCESS] PHP selection functional tests passed.")
PY
