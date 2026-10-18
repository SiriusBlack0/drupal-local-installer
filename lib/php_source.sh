#!/usr/bin/env bash

# ==================================================
# Optional package source for other PHP versions (--php-source)
#
# Ubuntu ships one PHP version per release (22.04: 8.1, 24.04: 8.3,
# 26.04: 8.5). Other versions come from Ondřej Surý's repository,
# https://packages.sury.org/php/ (the Debian PHP maintainer). His
# Launchpad PPA (ppa:ondrej/php) is being replaced by it; Ubuntu 26.04
# is only served there.
#
# Nothing is added without an explicit "y". Only the repository's key is
# installed, in its own keyring that the source names with Signed-By, so
# apt trusts it for this repository only. (The keyring package itself
# also puts the key in /etc/apt/trusted.gpg.d, where apt would trust it
# for every package source, so it is not installed.) The source is
# removed again if apt cannot use it.
# ==================================================

SURY_PHP_URL="https://packages.sury.org/php/"
SURY_KEYRING_URL="https://packages.sury.org/debsuryorg-archive-keyring.deb"
SURY_KEYRING_PACKAGE="debsuryorg-archive-keyring"
# Where the key is inside the keyring package.
SURY_KEYRING_PATH="/usr/share/keyrings/debsuryorg-archive-keyring.gpg"

# Where the installer puts it (SURY_KEYRING_FILE: tests only).
get_sury_keyring_file() {
    printf '%s\n' "${SURY_KEYRING_FILE:-/usr/share/keyrings/debsuryorg-php-drupal-local-installer.gpg}"
}

get_apt_etc_dir() {
    printf '%s\n' "${APT_ETC_DIR:-/etc/apt}"
}

get_sury_source_path() {
    printf '%s/sources.list.d/php-sury.sources\n' "$(get_apt_etc_dir)"
}

# All apt source files (classic one-line and deb822 format).
get_apt_source_files() {
    local dir
    local file

    dir="$(get_apt_etc_dir)"
    [[ -f "$dir/sources.list" ]] && printf '%s\n' "$dir/sources.list"

    for file in "$dir"/sources.list.d/*.list "$dir"/sources.list.d/*.sources; do
        [[ -f "$file" ]] && printf '%s\n' "$file"
    done

    return 0
}

# Files that use Ondřej's old Launchpad PPA (not commented out).
get_ondrej_ppa_files() {
    local file

    while IFS= read -r file; do
        if grep -qE '^[^#]*ppa\.launchpad(content)?\.net/ondrej/php' "$file"; then
            printf '%s\n' "$file"
        fi
    done < <(get_apt_source_files)
}

# Prints: sury, ppa (the old Launchpad PPA only) or none.
get_php_source_status() {
    local file

    while IFS= read -r file; do
        if grep -qE '^[^#]*packages\.sury\.org/php' "$file"; then
            echo "sury"
            return 0
        fi
    done < <(get_apt_source_files)

    if [[ -n "$(get_ondrej_ppa_files)" ]]; then
        echo "ppa"
    else
        echo "none"
    fi
}

generate_sury_source() {
    local codename="$1"

    [[ "$codename" =~ ^[a-z]+$ ]] || return 1

    printf '%s\n' \
        '# Added by drupal-local-installer (--php-source).' \
        '# Other PHP versions, maintained by Ondřej Surý.' \
        'Types: deb' \
        "URIs: $SURY_PHP_URL" \
        "Suites: $codename" \
        'Components: main' \
        "Signed-By: $(get_sury_keyring_file)"
}

# The repository has packages for this Ubuntu release.
sury_has_release() {
    local codename="$1"

    curl -fsI --max-time 15 "${SURY_PHP_URL}dists/${codename}/Release" > /dev/null 2>&1
}

# Unpacks the keyring package (it is never installed) and checks that it
# is what it claims to be and holds an OpenPGP key. Prints the key
# fingerprints. The key ends up in <work_dir>/repository-key.gpg.
check_sury_keyring_package() {
    local deb="$1"
    local work_dir="$2"
    local name
    local fingerprints

    name="$(dpkg-deb -f "$deb" Package 2>/dev/null)" || return 1

    if [[ "$name" != "$SURY_KEYRING_PACKAGE" ]]; then
        echo "[ERROR] The downloaded file is not $SURY_KEYRING_PACKAGE (it is '$name')."
        return 1
    fi

    if ! dpkg-deb -x "$deb" "$work_dir/extract" ||
       [[ ! -f "$work_dir/extract$SURY_KEYRING_PATH" || -L "$work_dir/extract$SURY_KEYRING_PATH" ]]; then
        echo "[ERROR] The keyring package does not contain $SURY_KEYRING_PATH"
        return 1
    fi

    fingerprints="$(gpg --show-keys --with-colons "$work_dir/extract$SURY_KEYRING_PATH" 2>/dev/null |
        awk -F: '$1 == "fpr" { print "  " $10 }' | sort -u || true)"

    if [[ -z "$fingerprints" ]]; then
        echo "[ERROR] $SURY_KEYRING_PATH in the package is not an OpenPGP key."
        return 1
    fi

    cp -- "$work_dir/extract$SURY_KEYRING_PATH" "$work_dir/repository-key.gpg"
    echo "Signing key(s) of the repository:"
    printf '%s\n' "$fingerprints"
}

DISABLED_PPA_FILES=()

# Renames the old PPA files so apt ignores them (".disabled" is ignored
# silently by apt). Only files that contain nothing but the PPA; a PPA
# line in another file is shown for manual editing.
# Repositories in a source file other than the ondrej/php PPA. deb822
# files (.sources) are judged by their URIs: lines; fields such as
# X-Repolib-Name and a key embedded in Signed-By do not count.
get_other_repositories_in() {
    local file="$1"

    if [[ "$file" == *.sources ]]; then
        grep -E '^URIs:' "$file" | grep -v 'ondrej/php' || true
    else
        grep -vE '^[[:space:]]*(#|$)' "$file" | grep -v 'ondrej/php' || true
    fi
}

disable_ondrej_ppa_files() {
    local file
    local others

    while IFS= read -r file; do
        others="$(get_other_repositories_in "$file")"

        if [[ "$file" == */sources.list || -n "$others" ]]; then
            echo "[INFO] $file has other entries too; remove its ondrej/php line by hand."
            continue
        fi

        if sudo mv -- "$file" "$file.disabled"; then
            DISABLED_PPA_FILES+=("$file")
            echo "[OK] Disabled the old PPA: $file -> $file.disabled"
        fi
    done < <(get_ondrej_ppa_files)
}

restore_ondrej_ppa_files() {
    local file

    for file in "${DISABLED_PPA_FILES[@]}"; do
        sudo mv -- "$file.disabled" "$file" && echo "[OK] Old PPA enabled again: $file"
    done

    DISABLED_PPA_FILES=()
}

# Adds packages.sury.org for this Ubuntu release. Needs sudo; asks
# first. Returns 0 when the source works afterwards.
add_sury_php_source() {
    local codename
    local work_dir
    local answer
    local source_path
    local update_status
    local keyring_file
    local keyring_added=0

    source_path="$(get_sury_source_path)"
    keyring_file="$(get_sury_keyring_file)"

    if ! codename="$(get_ubuntu_codename)"; then
        echo "[ERROR] Could not read the Ubuntu release name."
        return 1
    fi

    if ! command -v curl > /dev/null || ! command -v gpg > /dev/null; then
        echo "[ERROR] curl and gpg are needed: sudo apt-get install curl gnupg"
        return 1
    fi

    echo "Checking $SURY_PHP_URL for Ubuntu $codename..."

    if ! sury_has_release "$codename"; then
        echo "[NOT AVAILABLE] The repository has no packages for Ubuntu $codename (or it cannot be reached)."
        return 1
    fi

    work_dir="$(mktemp -d)"

    if ! curl -fsSL --max-time 60 -o "$work_dir/keyring.deb" "$SURY_KEYRING_URL" ||
       ! check_sury_keyring_package "$work_dir/keyring.deb" "$work_dir"; then
        echo "[ERROR] The repository keyring could not be downloaded or checked. Nothing was changed."
        rm -rf "$work_dir"
        return 1
    fi

    echo
    echo "What will change:"
    echo "  1. The repository's signing key is saved as"
    echo "     $keyring_file"
    echo "     apt trusts it ONLY for this repository (Signed-By). The official"
    echo "     keyring package is not installed: it would also copy the key to"
    echo "     /etc/apt/trusted.gpg.d, where apt trusts a key for EVERY source."
    echo "  2. A new package source:"
    echo "     $source_path"
    generate_sury_source "$codename" | sed 's/^/       /'

    if [[ -n "$(get_ondrej_ppa_files)" ]]; then
        echo "  3. The old PPA file(s) are renamed to .disabled (kept, not deleted):"
        get_ondrej_ppa_files | sed 's/^/       /'
        echo "  4. apt-get update reads the package lists."
    else
        echo "  3. apt-get update reads the package lists."
    fi

    echo
    echo "What does NOT change: no package is installed or removed now. PHP"
    echo "versions are installed later, by --php or a new project, after you"
    echo "confirm them."
    echo
    echo "Good to know: this repository also has newer builds of the PHP"
    echo "packages you already have; \"apt upgrade\" will take them from there."
    echo "If apt cannot use the new source, everything above is undone."
    echo

    if ! read -r -p "Add this package source? [y/N]: " answer || [[ ! "$answer" =~ ^[Yy]$ ]]; then
        echo "Nothing was changed."
        rm -rf "$work_dir"
        return 1
    fi

    if [[ ! -f "$keyring_file" ]] || ! cmp -s "$work_dir/repository-key.gpg" "$keyring_file"; then
        if ! sudo install -m 0644 -o root -g root "$work_dir/repository-key.gpg" "$keyring_file"; then
            echo "[ERROR] Could not write $keyring_file. Nothing was changed."
            rm -rf "$work_dir"
            return 1
        fi

        keyring_added=1
    fi

    generate_sury_source "$codename" > "$work_dir/php-sury.sources"

    if ! sudo install -m 0644 -o root -g root "$work_dir/php-sury.sources" "$source_path"; then
        echo "[ERROR] Could not write $source_path"
        [[ "$keyring_added" -eq 1 ]] && sudo rm -f -- "$keyring_file"
        rm -rf "$work_dir"
        return 1
    fi

    rm -rf "$work_dir"

    # The old PPA would only add errors to "apt-get update" from now on.
    DISABLED_PPA_FILES=()
    disable_ondrej_ppa_files

    update_status=0
    run_logged "Reading the package lists (apt-get update)" sudo apt-get update || update_status=$?

    if ! apt-cache policy 2>/dev/null | grep -qF "packages.sury.org/php"; then
        sudo rm -f -- "$source_path"
        [[ "$keyring_added" -eq 1 ]] && sudo rm -f -- "$keyring_file"
        restore_ondrej_ppa_files
        echo "[ERROR] apt could not use the new source; it and its key were removed again."
        return 1
    fi

    if [[ "$update_status" -ne 0 ]]; then
        echo "[WARNING] apt-get update reported errors for another package source (see above)."
    fi

    echo "[OK] PHP package source added. PHP versions now available: $(get_available_php_versions | paste -sd ' ' -)"
    echo "Next: ./install.sh --php <project> <version> --dry-run"
    echo "      (or ./install.sh, which now offers these versions for new projects)"
}

# For a source added by the installer: fetches the repository key again
# and replaces the installed one when the repository changed it.
refresh_sury_key() {
    local work_dir
    local keyring_file
    local answer

    keyring_file="$(get_sury_keyring_file)"
    work_dir="$(mktemp -d)"

    echo "Checking the repository's signing key..."

    if ! curl -fsSL --max-time 60 -o "$work_dir/keyring.deb" "$SURY_KEYRING_URL" ||
       ! check_sury_keyring_package "$work_dir/keyring.deb" "$work_dir" > "$work_dir/fingerprints"; then
        echo "[ERROR] The repository keyring could not be downloaded or checked."
        rm -rf "$work_dir"
        return 1
    fi

    if cmp -s "$work_dir/repository-key.gpg" "$keyring_file"; then
        echo "[OK] The installed key is current: $keyring_file"
        rm -rf "$work_dir"
        return 0
    fi

    echo "The repository has a different signing key now:"
    tail -n +2 "$work_dir/fingerprints"

    if ! read -r -p "Replace $keyring_file with it? [y/N]: " answer || [[ ! "$answer" =~ ^[Yy]$ ]]; then
        echo "Nothing was changed."
        rm -rf "$work_dir"
        return 1
    fi

    if ! require_sudo || ! sudo install -m 0644 -o root -g root "$work_dir/repository-key.gpg" "$keyring_file"; then
        rm -rf "$work_dir"
        return 1
    fi

    rm -rf "$work_dir"
    echo "[OK] Key replaced: $keyring_file"
}

# Both the new repository and the old PPA active: apt sees the same PHP
# packages twice, and the PPA may even be for another Ubuntu release.
disable_leftover_ppa() {
    local file
    local suite
    local codename
    local answer

    codename="$(get_ubuntu_codename 2>/dev/null)" || codename=""

    echo
    echo "[WARNING] The old PPA (ppa:ondrej/php) is still active as well:"

    while IFS= read -r file; do
        suite="$(sed -nE 's/^Suites:[[:space:]]*([a-z]+).*/\1/p' "$file" | head -n 1)"
        [[ -n "$suite" ]] || suite="$(grep -oE 'ondrej/php/ubuntu/?[[:space:]]+[a-z]+' "$file" | awk '{print $2}' | head -n 1)"

        if [[ -n "$suite" && -n "$codename" && "$suite" != "$codename" ]]; then
            echo "  $file (for Ubuntu $suite, but this system is $codename)"
        else
            echo "  $file"
        fi
    done < <(get_ondrej_ppa_files)

    echo "  apt then sees the same PHP packages in two places and may take them"
    echo "  from the PPA, which is being retired (and may be built for another"
    echo "  Ubuntu release). Disabling it renames the file to .disabled; nothing"
    echo "  is deleted and no package changes."
    echo

    if ! read -r -p "Disable the old PPA? [y/N]: " answer || [[ ! "$answer" =~ ^[Yy]$ ]]; then
        echo "The PPA stays active. Disable it by hand before installing PHP packages."
        return 0
    fi

    require_sudo || return 1
    DISABLED_PPA_FILES=()
    disable_ondrej_ppa_files

    if [[ "${#DISABLED_PPA_FILES[@]}" -gt 0 ]]; then
        run_logged "Reading the package lists (apt-get update)" sudo apt-get update ||
            echo "[WARNING] apt-get update reported errors (see above)."
    fi
}

# ./install.sh --php-source
run_php_source() {
    local status

    status="$(get_php_source_status)"

    echo
    echo "======================================"
    echo "  PHP package source"
    echo "======================================"
    echo
    echo "Ubuntu has one PHP version per release (22.04: 8.1, 24.04: 8.3,"
    echo "26.04: 8.5). Other versions come from Ondřej Surý, who maintains PHP"
    echo "in Debian: $SURY_PHP_URL"
    echo "It replaces his Launchpad PPA (ppa:ondrej/php); Ubuntu 26.04 is"
    echo "served only by the new repository."
    echo
    echo "PHP versions installed:              $(get_installed_php_versions | paste -sd ' ' -)"
    echo "PHP versions in the package sources: $(get_available_php_versions | paste -sd ' ' -)"
    echo

    case "$status" in
        sury)
            echo "[OK] $SURY_PHP_URL is already a package source."

            if [[ -n "$(get_ondrej_ppa_files)" ]]; then
                disable_leftover_ppa || return 1
            fi

            if [[ -f "$(get_sury_source_path)" ]]; then
                refresh_sury_key
                return
            fi

            return 0
            ;;
        ppa)
            echo "[OLD SOURCE] This system still uses the Launchpad PPA (ppa:ondrej/php):"
            get_ondrej_ppa_files | sed 's/^/  /'
            echo "  Its label now says \"Use https://packages.sury.org/php/ instead\", so"
            echo "  \"apt-get update\" may report an error, and it receives no new"
            echo "  releases for Ubuntu 26.04 at all. Switching adds the new repository"
            echo "  and disables the PPA file (renamed to .disabled, not deleted)."
            echo
            ;;
        none)
            echo "Only the PHP versions of Ubuntu itself are available."
            echo
            ;;
    esac

    require_sudo || return 1
    add_sury_php_source
}
