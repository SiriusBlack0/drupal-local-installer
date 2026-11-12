#!/usr/bin/env bash
# The constants below are used by lib/ddev/setup.sh.
# shellcheck disable=SC2034

# ==================================================
# The package sources of Docker and DDEV
#
# Both projects publish their own apt repository; Ubuntu's packages are
# older (docker.io) or missing (ddev). As for --php-source: the key goes
# into its own file in /etc/apt/keyrings that the source names with
# Signed-By, so apt trusts it for that repository only; a source that
# apt cannot use is removed again, with its key.
# ==================================================

DOCKER_APT_URL="https://download.docker.com/linux/ubuntu"
DOCKER_KEY_URL="https://download.docker.com/linux/ubuntu/gpg"
# Docker's release key (docs.docker.com: "9DC8 5822 9FC7 DD38 854A E2D8 8D81 803C 0EBF CD88").
DOCKER_KEY_FINGERPRINT="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"
DOCKER_PACKAGES=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)

DDEV_APT_URL="https://packages.ddev.com/public/deb/ubuntu"
DDEV_KEY_URL="https://packages.ddev.com/public/gpg.key"

get_apt_keyrings_dir() {
    printf '%s/keyrings\n' "$(get_apt_etc_dir)"
}

# Source files that already use a repository (pattern: an extended
# regular expression for its URL), not commented out.
find_apt_sources_using() {
    local pattern="$1"
    local file

    while IFS= read -r file; do
        if grep -qE "^[^#]*($pattern)" "$file"; then
            printf '%s\n' "$file"
        fi
    done < <(get_apt_source_files)
}

has_docker_apt_source() {
    [[ -n "$(find_apt_sources_using 'download\.docker\.com/linux/ubuntu')" ]]
}

has_ddev_apt_source() {
    [[ -n "$(find_apt_sources_using 'packages\.ddev\.com|pkg\.ddev\.com|apt\.fury\.io/drud')" ]]
}

# The deb822 source of one repository.
generate_repository_source() {
    local name="$1"
    local url="$2"
    local suite="$3"
    local component="$4"
    local key_file="$5"
    local architecture="${6:-}"

    printf '%s\n' \
        "# Added by drupal-local-installer (--ddev-setup): $name." \
        'Types: deb' \
        "URIs: $url" \
        "Suites: $suite" \
        "Components: $component"
    [[ -n "$architecture" ]] && printf 'Architectures: %s\n' "$architecture"
    printf 'Signed-By: %s\n' "$key_file"
}

# The fingerprints of the OpenPGP keys in file $1, one per line.
get_key_fingerprints() {
    gpg --batch --show-keys --with-colons "$1" 2>/dev/null | awk -F: '$1 == "fpr" { print $10 }'
}

# Downloads key $2 into $3 and checks it: an OpenPGP key, and, when $4 is
# given, the fingerprint that the project publishes. $1: name, for the
# messages.
download_repository_key() {
    local name="$1"
    local url="$2"
    local out="$3"
    local expected="${4:-}"
    local fingerprints

    if ! curl -fsSL --max-time 60 -o "$out" "$url"; then
        echo "[ERROR] The $name key could not be downloaded: $url"
        return 1
    fi

    fingerprints="$(get_key_fingerprints "$out")"

    if [[ -z "$fingerprints" ]]; then
        echo "[ERROR] $url is not an OpenPGP key."
        return 1
    fi

    if [[ -n "$expected" ]] && ! grep -qx "$expected" <<< "$fingerprints"; then
        echo "[ERROR] The $name key is not the one $name publishes:"
        echo "        expected $expected"
        echo "        got      $(paste -sd ' ' - <<< "$fingerprints")"
        return 1
    fi

    echo "[OK] $name key: $(head -n 1 <<< "$fingerprints")"
}

# Installs key file $1 as $2 and source text file $3 as $4 (root, 0644).
# Prints nothing; returns 1 and undoes what it wrote on failure.
install_repository_files() {
    local key_temp="$1"
    local key_file="$2"
    local source_temp="$3"
    local source_file="$4"

    sudo install -d -m 0755 -o root -g root "$(dirname "$key_file")" || return 1
    sudo install -m 0644 -o root -g root "$key_temp" "$key_file" || return 1

    if ! sudo install -m 0644 -o root -g root "$source_temp" "$source_file"; then
        sudo rm -f -- "$key_file"
        return 1
    fi
}
