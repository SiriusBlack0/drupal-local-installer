#!/usr/bin/env bash

# APT simulation and installation. apt-get and sudo are stubs.

set -euo pipefail

cd "$(dirname "$0")/.."

source lib/packages.sh

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
stub_bin="$work_dir/bin"
mkdir -p "$stub_bin"
export APT_CALLS="$work_dir/apt_calls"

pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; exit 1; }

# apt-get prints the simulation in $APT_OUTPUT and exits with $APT_EXIT.
cat > "$stub_bin/apt-get" <<'STUB'
#!/usr/bin/env bash
echo "apt-get $*" >> "$APT_CALLS"
printf '%b' "${APT_OUTPUT:-}"
exit "${APT_EXIT:-0}"
STUB
printf '#!/usr/bin/env bash\nexec "$@"\n' > "$stub_bin/sudo"
chmod +x "$stub_bin/apt-get" "$stub_bin/sudo"
PATH="$stub_bin:$PATH"

# Test 1: A normal simulation passes.

INSTALL_PACKAGES=("postgresql" "php8.5-pgsql")
export APT_OUTPUT='Inst postgresql-18 (18.6 Ubuntu:26.04/resolute [amd64])\nInst postgresql (18 Ubuntu:26.04/resolute [all])\nConf postgresql (18 Ubuntu:26.04/resolute [all])\n'

if output="$(simulate_apt_package_installation)" && [[ "$output" == *"Inst postgresql"* ]]; then
    pass "Simulation without removals passes and is shown"
else
    fail "normal simulation: $output"
fi

# Test 2: A simulation that removes packages is blocked.
# Real case: mysql-server replaces an installed mariadb-server.

INSTALL_PACKAGES=("mysql-server")
export APT_OUTPUT='Remv mariadb-server [1:11.8.6]\nRemv mariadb-server-core [1:11.8.6]\nInst mysql-server-8.4 (8.4.11 Ubuntu:26.04/resolute [amd64])\n'

if output="$(simulate_apt_package_installation)"; then
    fail "Package removal was not blocked"
elif [[ "$output" == *"[BLOCKED] Installing mysql-server would REMOVE: mariadb-server mariadb-server-core"* ]] &&
     [[ "$output" == *"never removes packages"* ]]; then
    pass "Simulation that removes packages is blocked, with the package names"
else
    fail "removal message: $output"
fi

# Test 3: A failed simulation fails.

INSTALL_PACKAGES=("does-not-exist")
export APT_OUTPUT='E: Unable to locate package does-not-exist\n'

if APT_EXIT=100 simulate_apt_package_installation > /dev/null; then
    fail "Failed simulation reported as success"
else
    pass "Failed simulation reported"
fi

# Test 4: The real installation can never remove packages.

INSTALL_PACKAGES=("postgresql")
: > "$APT_CALLS"
export APT_OUTPUT=''

if execute_apt_package_installation > /dev/null &&
   [[ "$(cat "$APT_CALLS")" == "apt-get install -y --no-remove -- postgresql" ]]; then
    pass "Real installation uses --no-remove, and -y (the packages were approved already)"
else
    fail "install command: $(cat "$APT_CALLS")"
fi

# Test 5: Nothing to install: apt-get is not called.

INSTALL_PACKAGES=()
: > "$APT_CALLS"

if simulate_apt_package_installation > /dev/null &&
   execute_apt_package_installation > /dev/null &&
   [[ ! -s "$APT_CALLS" ]]; then
    pass "No packages: apt-get not called"
else
    fail "apt-get called without packages"
fi

# Test 6: apt switches the system's default php (a new PHP version in
# "auto" mode): it is set back.

export ALT_STATE="$work_dir/alternatives"
cat > "$stub_bin/update-alternatives" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    --query) grep "^$2=" "$ALT_STATE" | sed 's/^[^=]*=/Value: /' ;;
    --set) sed -i "s|^$2=.*|$2=$3|" "$ALT_STATE"; echo "set $2 $3" >> "$APT_CALLS" ;;
esac
STUB
# The real apt-get install runs the new PHP's postinst: auto mode moves php.
cat > "$stub_bin/apt-get" <<'STUB'
#!/usr/bin/env bash
echo "apt-get $*" >> "$APT_CALLS"
if [[ "$1" == "install" ]]; then
    sed -i 's|^php=.*|php=/usr/bin/php8.4|; s|^phar=.*|phar=/usr/bin/phar8.4|' "$ALT_STATE"
fi
exit 0
STUB
chmod +x "$stub_bin/update-alternatives" "$stub_bin/apt-get"
printf '%s\n' "php=/usr/bin/php8.3" "phar=/usr/bin/phar8.3" > "$ALT_STATE"
INSTALL_PACKAGES=("php8.4-cli")
: > "$APT_CALLS"

if output="$(execute_apt_package_installation)" &&
   grep -qx "php=/usr/bin/php8.3" "$ALT_STATE" && grep -qx "phar=/usr/bin/phar8.3" "$ALT_STATE" &&
   [[ "$output" == *"[OK] The system's default php stays /usr/bin/php8.3 (apt had switched it to /usr/bin/php8.4)"* ]] &&
   ! grep -q "set phar.phar" "$APT_CALLS"; then
    pass "apt switched the default php: set back to the one before (php and phar)"
else
    fail "alternatives: $output / $(cat "$ALT_STATE")"
fi

printf '%s\n' "php=/usr/bin/php8.4" > "$ALT_STATE"
: > "$APT_CALLS"

if execute_apt_package_installation > /dev/null && ! grep -q "^set " "$APT_CALLS"; then
    pass "Default php unchanged by apt: nothing is set"
else
    fail "alternatives unchanged: $(cat "$APT_CALLS")"
fi

echo "[SUCCESS] Package installation tests passed."
