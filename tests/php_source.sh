#!/usr/bin/env bash

# ./install.sh --php-source: detection of the PHP package source, the
# keyring package check, and adding packages.sury.org. apt files live in
# a temporary directory; curl, sudo, dpkg, apt-get and apt-cache are
# stubs. The keyring package is a real .deb built here.

set -euo pipefail

cd "$(dirname "$0")/.."

source lib/output.sh
source lib/system.sh
source lib/php.sh
source lib/php_source.sh

work_dir="$(mktemp -d)"
trap 'gpgconf --kill gpg-agent > /dev/null 2>&1 || true; rm -rf "$work_dir"' EXIT

export APT_ETC_DIR="$work_dir/apt"
stub_bin="$work_dir/bin"
export CALLS_FILE="$work_dir/calls"
mkdir -p "$APT_ETC_DIR/sources.list.d" "$stub_bin"
LOG_FILE=""

pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; exit 1; }

get_ubuntu_codename() { echo "resolute"; }
get_available_php_versions() { printf '8.3\n8.4\n8.5\n'; }
require_sudo() { echo "sudo-asked" >> "$CALLS_FILE"; }
get_installed_php_versions() { echo "8.5"; }

# A keyring package laid out like the real one: the key in
# /usr/share/keyrings and a copy in /etc/apt/trusted.gpg.d.
build_deb() {
    local out="$1"
    local name="$2"
    local key="$3"
    local root="$work_dir/build-$name-$RANDOM"

    mkdir -p "$root/DEBIAN" "$root/usr/share/keyrings" "$root/usr/share/doc/$name" "$root/etc/apt/trusted.gpg.d"
    printf 'Package: %s\nVersion: 2024.02.05\nArchitecture: all\nMaintainer: test <t@t>\nDescription: test\n' "$name" > "$root/DEBIAN/control"
    cp "$key" "$root/usr/share/keyrings/debsuryorg-archive-keyring.gpg"
    cp "$key" "$root/etc/apt/trusted.gpg.d/debsuryorg-archive.gpg"
    echo "copyright" > "$root/usr/share/doc/$name/copyright"

    dpkg-deb --build --root-owner-group "$root" "$out" > /dev/null
}

# A real (throw-away) signing key, so its fingerprint can be shown.
export GNUPGHOME="$work_dir/gnupg"
mkdir -m 700 "$GNUPGHOME"
gpg --batch --quiet --passphrase '' --quick-gen-key "Test Key <test@example.invalid>" ed25519 sign never 2> /dev/null
gpg --batch --export > "$work_dir/key.gpg" 2> /dev/null
key_fingerprint="$(gpg --batch --with-colons --list-keys 2> /dev/null | awk -F: '$1 == "fpr" { print $10; exit }')"

echo "not a key" > "$work_dir/not-a-key"
build_deb "$work_dir/good.deb" debsuryorg-archive-keyring "$work_dir/key.gpg"
build_deb "$work_dir/wrong-name.deb" some-other-package "$work_dir/key.gpg"
build_deb "$work_dir/no-key.deb" debsuryorg-archive-keyring "$work_dir/not-a-key"
export KEYRING_DEB="$work_dir/good.deb"
export SURY_KEYRING_FILE="$work_dir/keyrings/php-sury.gpg"
mkdir -p "$work_dir/keyrings"

# curl: the Release file exists unless NO_RELEASE=1; downloads copy
# KEYRING_DEB.
cat > "$stub_bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$CALLS_FILE"
out=""
while [[ "$#" -gt 0 ]]; do
    [[ "$1" == "-o" ]] && { out="$2"; shift; }
    shift
done
if [[ -n "$out" ]]; then cp "$KEYRING_DEB" "$out"; exit 0; fi
[[ "${NO_RELEASE:-0}" == "1" ]] && exit 22
exit 0
STUB

cat > "$stub_bin/sudo" <<'STUB'
#!/usr/bin/env bash
echo "sudo $*" >> "$CALLS_FILE"
[[ "$1" == "-u" ]] && shift 2
# install -o root -g root needs root: drop the owner options in tests.
if [[ "$1" == "install" ]]; then
    shift
    args=()
    while [[ "$#" -gt 0 ]]; do
        case "$1" in -o|-g) shift ;; *) args+=("$1") ;; esac
        shift
    done
    exec install "${args[@]}"
fi
exec "$@"
STUB

cat > "$stub_bin/dpkg" <<'STUB'
#!/usr/bin/env bash
echo "dpkg $*" >> "$CALLS_FILE"
STUB

cat > "$stub_bin/apt-get" <<'STUB'
#!/usr/bin/env bash
echo "apt-get $*" >> "$CALLS_FILE"
exit "${APT_UPDATE_EXIT:-0}"
STUB

cat > "$stub_bin/apt-cache" <<'STUB'
#!/usr/bin/env bash
[[ "${APT_USES_SURY:-1}" == "1" ]] && echo " 500 https://packages.sury.org/php resolute/main amd64 Packages"
exit 0
STUB

chmod +x "$stub_bin"/*
PATH="$stub_bin:$PATH"

source_file="$APT_ETC_DIR/sources.list.d/php-sury.sources"
ppa_file="$APT_ETC_DIR/sources.list.d/ondrej-ubuntu-php-resolute.sources"

# Test 1: Status: none, the old PPA, packages.sury.org.

echo "deb http://archive.ubuntu.com/ubuntu resolute main" > "$APT_ETC_DIR/sources.list"

if [[ "$(get_php_source_status)" == "none" ]]; then
    pass "Ubuntu sources only: none"
else
    fail "none: $(get_php_source_status)"
fi

printf 'Types: deb\nURIs: https://ppa.launchpadcontent.net/ondrej/php/ubuntu/\nSuites: resolute\nComponents: main\n' > "$ppa_file"
echo "# deb https://packages.sury.org/php/ resolute main" > "$APT_ETC_DIR/sources.list.d/commented.list"

if [[ "$(get_php_source_status)" == "ppa" && "$(get_ondrej_ppa_files)" == "$ppa_file" ]]; then
    pass "Old Launchpad PPA detected; commented lines ignored"
else
    fail "ppa: $(get_php_source_status)"
fi

# A PPA file as add-apt-repository writes it on Ubuntu 24.04+: extra
# fields and the key embedded in Signed-By. It has no other repository.
real_ppa="$APT_ETC_DIR/sources.list.d/ondrej-ubuntu-php-noble.sources"
write_real_ppa() {
    cat > "$real_ppa" <<'PPA'
X-Repolib-Name: ondrej/php
Enabled: yes
Types: deb
URIs: https://ppa.launchpadcontent.net/ondrej/php/ubuntu/
Signed-By:
 -----BEGIN PGP PUBLIC KEY BLOCK-----
 .
 mQINBGd7aR8BEADCxnZ1J0lW
 -----END PGP PUBLIC KEY BLOCK-----
Suites: noble
Components: main
PPA
}
write_real_ppa
printf 'Types: deb\nURIs: https://ppa.launchpadcontent.net/ondrej/php/ubuntu/\nSuites: noble\nComponents: main\n\nTypes: deb\nURIs: https://example.org/other/\nSuites: noble\nComponents: main\n' > "$work_dir/mixed.sources"

if [[ -z "$(get_other_repositories_in "$real_ppa")" &&
      "$(get_other_repositories_in "$work_dir/mixed.sources")" == "URIs: https://example.org/other/" ]]; then
    pass "PPA file with embedded key and extra fields counts as PPA only; other repositories are seen"
else
    fail "other repositories: '$(get_other_repositories_in "$real_ppa")'"
fi

rm -f "$real_ppa"

# Test 2: The source file.

if [[ "$(generate_sury_source resolute)" == *"URIs: https://packages.sury.org/php/"*"Suites: resolute"*"Signed-By: $SURY_KEYRING_FILE"* ]] &&
   ! generate_sury_source 'res olute' > /dev/null; then
    pass "deb822 source for the release, signed by its own keyring only"
else
    fail "source: $(generate_sury_source resolute)"
fi

# Test 3: The keyring package is unpacked and checked, never installed.

mkdir -p "$work_dir/k1" "$work_dir/k2" "$work_dir/k3"

if good_output="$(check_sury_keyring_package "$work_dir/good.deb" "$work_dir/k1")" &&
   [[ "$good_output" == *"Signing key(s) of the repository:"*"$key_fingerprint"* ]] &&
   cmp -s "$work_dir/k1/repository-key.gpg" "$work_dir/key.gpg" &&
   ! check_sury_keyring_package "$work_dir/wrong-name.deb" "$work_dir/k2" > /dev/null &&
   output="$(check_sury_keyring_package "$work_dir/no-key.deb" "$work_dir/k3")"; then
    fail "Keyring package without a key accepted: $output"
elif [[ "$output" == *"is not an OpenPGP key"* ]]; then
    pass "Keyring package: key taken out, fingerprint shown; wrong name or no key refused"
else
    fail "keyring check: $output"
fi

# Test 4: "n" changes nothing.

: > "$CALLS_FILE"

if printf 'n\n' | add_sury_php_source > /dev/null; then
    fail "'n' accepted"
elif [[ ! -e "$source_file" && -f "$ppa_file" ]] && ! grep -q "^sudo" "$CALLS_FILE"; then
    pass "Answer 'n': nothing changed, no sudo"
else
    fail "n: $(cat "$CALLS_FILE")"
fi

if NO_RELEASE=1 add_sury_php_source < /dev/null > /dev/null; then
    fail "Release without packages accepted"
elif [[ ! -e "$source_file" ]]; then
    pass "No packages for this Ubuntu release: nothing changed"
else
    fail "no release"
fi

# Test 5: "y": keyring, source, old PPA disabled, apt-get update.

: > "$CALLS_FILE"

if output="$(printf 'y\n' | add_sury_php_source)" &&
   [[ "$output" == *"[OK] PHP package source added. PHP versions now available: 8.3 8.4 8.5"* ]] &&
   grep -q "Suites: resolute" "$source_file" &&
   [[ "$(stat -c '%a' "$source_file")" == "644" ]] &&
   [[ ! -e "$ppa_file" && -f "$ppa_file.disabled" ]] &&
   [[ "$(get_php_source_status)" == "sury" ]] &&
   cmp -s "$SURY_KEYRING_FILE" "$work_dir/key.gpg" &&
   [[ "$(stat -c '%a' "$SURY_KEYRING_FILE")" == "644" ]] &&
   ! grep -q "dpkg -i\|trusted.gpg.d" "$CALLS_FILE" &&
   [[ "$(grep -n "install .*$SURY_KEYRING_FILE" "$CALLS_FILE" | cut -d: -f1)" -lt "$(grep -n '^apt-get update' "$CALLS_FILE" | cut -d: -f1)" ]]; then
    pass "Added: key in its own keyring (not trusted.gpg.d, no dpkg -i), source, old PPA disabled"
else
    fail "add: $output / $(cat "$CALLS_FILE")"
fi

# Test 6a: New repository added earlier, old PPA still active (its file
# could not be disabled then): --php-source offers to disable it.

write_real_ppa
: > "$CALLS_FILE"

if output="$(printf 'y\n' | run_php_source)" &&
   [[ "$output" == *"[WARNING] The old PPA (ppa:ondrej/php) is still active as well"* &&
      "$output" == *"(for Ubuntu noble, but this system is resolute)"* &&
      "$output" == *"[OK] Disabled the old PPA: $real_ppa -> $real_ppa.disabled"* ]] &&
   [[ ! -e "$real_ppa" && -f "$real_ppa.disabled" ]] &&
   grep -q "^apt-get update" "$CALLS_FILE"; then
    pass "Leftover PPA (other release): explained, disabled after 'y', package lists read"
else
    fail "leftover ppa: $output"
fi

rm -f "$real_ppa.disabled"

# Test 6: --php-source again: the key is checked, and replaced (after
# "y") when the repository changed it.

if output="$(run_php_source < /dev/null)" && [[ "$output" == *"[OK] The installed key is current"* ]]; then
    pass "Again: the installed key is current"
else
    fail "current key: $output"
fi

gpg --batch --quiet --passphrase '' --quick-gen-key "New Key <new@example.invalid>" ed25519 sign never 2> /dev/null
gpg --batch --export "new@example.invalid" > "$work_dir/new-key.gpg" 2> /dev/null
build_deb "$work_dir/new.deb" debsuryorg-archive-keyring "$work_dir/new-key.gpg"

if output="$(printf 'y\n' | KEYRING_DEB="$work_dir/new.deb" run_php_source)" &&
   [[ "$output" == *"The repository has a different signing key now"*"[OK] Key replaced"* ]] &&
   cmp -s "$SURY_KEYRING_FILE" "$work_dir/new-key.gpg"; then
    pass "Again: a changed repository key is shown and replaced after 'y'"
else
    fail "key refresh: $output"
fi

# Test 7: apt cannot use the new source: it is removed, the PPA is back.

rm -f "$source_file" "$SURY_KEYRING_FILE"
mv "$ppa_file.disabled" "$ppa_file"

if output="$(printf 'y\n' | APT_USES_SURY=0 APT_UPDATE_EXIT=100 add_sury_php_source)"; then
    fail "Unusable source accepted"
elif [[ "$output" == *"apt could not use the new source; it and its key were removed again"* ]] &&
     [[ ! -e "$source_file" && ! -e "$SURY_KEYRING_FILE" && -f "$ppa_file" && ! -e "$ppa_file.disabled" ]]; then
    pass "Unusable source: source and key removed again, old PPA restored"
else
    fail "rollback: $output"
fi

echo "[SUCCESS] PHP source tests passed."
