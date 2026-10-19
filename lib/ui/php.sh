#!/usr/bin/env bash

# Phase 1: choosing the PHP version.

# --------------------------------------------------

# PHP compatibility

# --------------------------------------------------

detect_php_requirements() {
    echo "Detecting PHP requirements..."


    PHP_CONSTRAINT="$(get_drupal_php_constraint "$DRUPAL_VERSION")"


    if [ -z "$PHP_CONSTRAINT" ]; then

        echo "Could not determine PHP requirements for Drupal $DRUPAL_VERSION."

        exit 1

    fi


    DRUPAL_MINOR="$(get_drupal_minor "$DRUPAL_VERSION")"
}

# Shown when the host system cannot run the requested setup.
print_container_hint() {
    echo
    echo "Best practice: a container-based setup (Docker, for example DDEV)"
    echo "runs each project with its own PHP and database versions,"
    echo "without changing the packages of this system."
}

# PHP versions come from config/compatibility.conf (via
# get_supported_php_versions). All supported versions are listed with
# their status; versions that are not available cannot be selected.
resolve_compatible_php_versions() {
    local version
    local found_versions
    local usable_count=0
    local -a required_versions=()

    if ! has_php_support_policy "$DRUPAL_MINOR"; then
        echo
        echo "[UNSUPPORTED] Drupal $DRUPAL_MINOR is not supported by this installer."
        echo "Supported Drupal releases: $(get_supported_drupal_minors | paste -sd ' ' -)"
        echo "Older releases no longer receive security fixes."
        echo "For a new project, choose the latest release of a supported version."
        print_container_hint
        return 1
    fi

    mapfile -t required_versions < <(get_supported_php_versions "$DRUPAL_MINOR")

    PHP_VERSIONS=("${required_versions[@]}")

    for version in "${required_versions[@]}"; do
        if [ "$(get_php_version_status "$version")" != "not_available" ]; then
            usable_count=$((usable_count + 1))
        fi
    done

    echo
    echo "Drupal $DRUPAL_VERSION supports PHP: ${required_versions[*]}"

    if [ "$usable_count" -eq 0 ]; then
        found_versions="$(get_php_candidate_versions | paste -sd ' ' -)"

        echo
        echo "[BLOCKED] No supported PHP version is installed or available."
        echo "Required PHP version(s): ${required_versions[*]}"
        echo "PHP versions on this system or in its package sources: ${found_versions:-none}"
        echo
        echo "Install one of the required PHP versions first. Other PHP versions"
        echo "come from packages.sury.org: ./install.sh --php-source (asks first)."
        print_container_hint
        return 1
    fi
}

# Called when the chosen Drupal release cannot be installed here.
# The user decides what happens next.
choose_after_blocked() {
    local choice

    while true; do
        echo
        echo "What would you like to do?"
        echo
        echo "1) Choose another Drupal version"
        echo "2) Cancel installation"
        echo

        if ! read -r -p "Select [1-2]: " choice; then
            echo
            echo "Input cancelled."
            exit 0
        fi

        case "$choice" in
            1)
                return 0
                ;;
            2)
                echo "Installation cancelled."
                exit 0
                ;;
            *)
                echo "Invalid selection. Please choose 1 or 2."
                ;;
        esac
    done
}

# Supported PHP versions (from PHP_VERSIONS) that this system can
# actually provide right now: installed or installable via apt.
get_usable_php_versions() {
    local version

    for version in "${PHP_VERSIONS[@]}"; do
        if [ "$(get_php_version_status "$version")" != "not_available" ]; then
            printf '%s\n' "$version"
        fi
    done
}

prompt_php_version() {
    while true; do


        echo

        echo "Compatible PHP versions:"

        echo


        for i in "${!PHP_VERSIONS[@]}"; do

            php_version="${PHP_VERSIONS[$i]}"
            php_status="$(get_php_version_status "$php_version")"

            echo "$((i + 1))) PHP $php_version [$php_status]"

        done


        echo

        if ! read -r -p "Select PHP version: " PHP_CHOICE; then
            echo "Input cancelled."
            exit 0
        fi


        if ! [[ "$PHP_CHOICE" =~ ^[0-9]+$ ]] ||

           (( PHP_CHOICE < 1 ||

              PHP_CHOICE > ${#PHP_VERSIONS[@]} )); then


            echo "Invalid selection. Try again."

            continue


        fi


        PHP_VERSION="${PHP_VERSIONS[$((PHP_CHOICE - 1))]}"
        PHP_STATUS="$(get_php_version_status "$PHP_VERSION")"

        if [ "$PHP_STATUS" = "not_available" ]; then
            echo
            echo "[NOT AVAILABLE] PHP $PHP_VERSION is not installed and not available"
            echo "from the package sources of this system."
            echo "Usable for Drupal $DRUPAL_VERSION on this system: $(get_usable_php_versions | paste -sd ' ' -)"
            echo "Other PHP versions: ./install.sh --php-source"
            continue
        fi

        break

    done


    # --------------------------------------------------
}
