#!/usr/bin/env bash
set -euo pipefail

python3 - <<'PY'
from pathlib import Path
import subprocess

section = Path("lib/install_execution.sh").read_text()

cases = [
    ("All packages ready", "true", "true", [], ""),
    ("No packages required", "true", "true", [], ""),
    ("Warnings declined", "false", "false", [], "n\n"),
    ("Packages unavailable", "true", "false", ["php8.5-cli"], "y\n"),
]

for label, repos_ok, packages_ok, packages, user_input in cases:
    package_values = " ".join(f'"{p}"' for p in packages)

    script = f'''
set -e
APT_REPOSITORIES_COMPATIBLE={repos_ok}
PACKAGES_AVAILABLE={packages_ok}
INSTALL_PACKAGES=({package_values})

simulate_apt_package_installation() {{
    echo "MOCK_SIMULATION"
}}

execute_apt_package_installation() {{
    echo "MOCK_INSTALLATION"
}}

''' + section + '\nprintf "EXECUTION_COMPLETED\\n"\n'

    result = subprocess.run(
        ["bash", "-c", script],
        input=user_input,
        text=True,
        capture_output=True,
        timeout=5,
    )

    passed = result.returncode == 0

    if label == "Warnings declined":
        passed = (
            passed
            and "[CANCELLED]" in result.stdout
            and "EXECUTION_COMPLETED" not in result.stdout
        )
    else:
        passed = passed and "EXECUTION_COMPLETED" in result.stdout

    if label == "Packages unavailable":
        passed = passed and "[SKIPPED] Package installation cannot proceed." in result.stdout

    if label == "All packages ready":
        passed = passed and "[READY] Package availability and repository checks passed." in result.stdout

    print(f"[{'PASS' if passed else 'FAIL'}] {label}")

    if not passed:
        print(result.stdout)
        print(result.stderr)
        raise SystemExit(1)

approval_cases = [
    ("Installation approved", "y\ny\n", True, False),
    ("Installation declined", "n\n", False, False),
    ("Actual installation declined", "y\nn\n", False, False),
    ("Simulation failed", "y\n", False, True),
]

for label, user_input, expect_install, simulation_fails in approval_cases:
    simulation_result = "return 1" if simulation_fails else "return 0"

    script = f'''
set -e

APT_REPOSITORIES_COMPATIBLE=true
PACKAGES_AVAILABLE=true
INSTALL_PACKAGES=("php8.5-cli")

simulate_apt_package_installation() {{
    echo "MOCK_SIMULATION"
    {simulation_result}
}}

execute_apt_package_installation() {{
    echo "MOCK_INSTALLATION"
    return 0
}}

''' + section + '\nprintf "EXECUTION_COMPLETED\\n"\n'

    result = subprocess.run(
        ["bash", "-c", script],
        input=user_input,
        text=True,
        capture_output=True,
        timeout=5,
    )

    expect_simulation = label != "Installation declined"

    passed = (
        ("MOCK_INSTALLATION" in result.stdout) == expect_install
        and ("MOCK_SIMULATION" in result.stdout) == expect_simulation
    )

    if simulation_fails:
        passed = (
            passed
            and result.returncode == 1
            and "[ERROR] APT installation simulation failed." in result.stdout
            and "EXECUTION_COMPLETED" not in result.stdout
        )
    else:
        passed = (
            passed
            and result.returncode == 0
            and "EXECUTION_COMPLETED" in result.stdout
        )

    print(f"[{'PASS' if passed else 'FAIL'}] {label}")

    if not passed:
        print(result.stdout)
        print(result.stderr)
        raise SystemExit(1)

# Actual APT installation failure.
script = '''
set -e

APT_REPOSITORIES_COMPATIBLE=true
PACKAGES_AVAILABLE=true
INSTALL_PACKAGES=("php8.5-cli")

simulate_apt_package_installation() {
    echo "MOCK_SIMULATION"
    return 0
}

execute_apt_package_installation() {
    echo "MOCK_INSTALLATION"
    return 1
}

''' + section + '\nprintf "UNEXPECTED_COMPLETION\\n"\n'

result = subprocess.run(
    ["bash", "-c", script],
    input="y\ny\n",
    text=True,
    capture_output=True,
    timeout=5,
)

passed = (
    result.returncode == 1
    and "MOCK_SIMULATION" in result.stdout
    and "MOCK_INSTALLATION" in result.stdout
    and "[ERROR] Package installation failed." in result.stdout
    and "UNEXPECTED_COMPLETION" not in result.stdout
)

print(f"[{'PASS' if passed else 'FAIL'}] Actual installation failure")

if not passed:
    print(result.stdout)
    print(result.stderr)
    raise SystemExit(1)

# EOF handling tests.
eof_cases = [
    ("Warnings confirmation EOF", "false", "false", [], "", "[CANCELLED]"),
    ("Package approval EOF", "true", "true", ["php8.5-cli"], "", "[SKIPPED] Package installation declined."),
    ("Actual installation EOF", "true", "true", ["php8.5-cli"], "y\n", "[SKIPPED] Actual package installation cancelled."),
]

for label, repos_ok, packages_ok, packages, user_input, expected in eof_cases:
    package_values = " ".join(f'"{p}"' for p in packages)

    script = f'''
set -e
APT_REPOSITORIES_COMPATIBLE={repos_ok}
PACKAGES_AVAILABLE={packages_ok}
INSTALL_PACKAGES=({package_values})

simulate_apt_package_installation() {{
    echo "MOCK_SIMULATION"
    return 0
}}

execute_apt_package_installation() {{
    echo "MOCK_INSTALLATION"
    return 0
}}

''' + section + '\nprintf "EXECUTION_COMPLETED\\n"\n'

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
        and "MOCK_INSTALLATION" not in result.stdout
    )

    if label == "Warnings confirmation EOF":
        passed = passed and "EXECUTION_COMPLETED" not in result.stdout
    else:
        passed = passed and "EXECUTION_COMPLETED" in result.stdout

    print(f"[{'PASS' if passed else 'FAIL'}] {label}")

    if not passed:
        print(result.stdout)
        print(result.stderr)
        raise SystemExit(1)

print("\n[SUCCESS] Installation execution baseline tests passed.")
PY
