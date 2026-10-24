#!/usr/bin/env bash

# Update targets, security status and compatibility (--check-updates).

# Prints the core package the project requires (drupal/core-recommended
# or drupal/core), then the companion packages it also requires.
get_core_packages() {
    local project_path="$1"
    local php_version="$2"

    # Single quotes: PHP code, not shell code.
    # shellcheck disable=SC2016
    "php${php_version}" -r '
$c = json_decode(file_get_contents($argv[1]), true);
if (!is_array($c)) { exit(1); }
$req = ($c["require"] ?? []) + ($c["require-dev"] ?? []);
if (isset($req["drupal/core-recommended"])) { echo "drupal/core-recommended\n"; }
elseif (isset($req["drupal/core"])) { echo "drupal/core\n"; }
else { exit(2); }
foreach (array_slice($argv, 2) as $p) { if (isset($req[$p])) { echo $p, "\n"; } }
' "$project_path/composer.json" "${CORE_COMPANION_PACKAGES[@]}"
}

# composer.lock written for another composer.json: composer.json was
# changed without "composer update" (for example "composer require
# 'drupal/gin:^5' --no-update" before an upgrade). "composer install"
# still installs exactly what the lock file lists; only "composer update"
# brings the change. $1 is a folder with both files. Returns 0 when they
# do not match. composer validate reads only the files: no network.
is_composer_lock_outdated() {
    local dir="$1"
    local output

    output="$(run_project_composer "$dir" "$RECORD_PHP_VERSION" \
        validate --no-check-publish --no-check-all 2>&1)" || true

    grep -qi 'lock file is not up to date' <<< "$output"
}

# Can the composer files in $1 be installed with the project's PHP?
# "composer install --dry-run" on a copy in an empty temporary folder:
# it checks what the real install checks (PHP and extensions, plugins,
# conflicts) and installs nothing. Prints Composer's reason when it
# fails. Returns 0: installable, 1: not, 2: could not check.
check_composer_files_installable() {
    local dir="$1"
    local temp
    local output
    local status=0

    temp="$(run_as_project_user "$PROJECT_USER" mktemp -d)" || return 2

    if ! run_as_project_user "$PROJECT_USER" cp -- "$dir/composer.json" "$dir/composer.lock" "$temp/"; then
        run_as_project_user "$PROJECT_USER" rm -rf -- "$temp"
        return 2
    fi

    output="$(run_project_composer "$temp" "$RECORD_PHP_VERSION" \
        install --dry-run --no-scripts 2>&1)" || status=$?
    run_as_project_user "$PROJECT_USER" rm -rf -- "$temp"
    log_line "composer install --dry-run of $dir:"$'\n'"$output"

    [[ "$status" -eq 0 ]] && return 0

    if composer_output_is_network_error "$output"; then
        return 2
    fi

    printf '%s\n' "$output" | grep -v '^[[:space:]]*$' | tail -n 8
    return 1
}

# Composer's message for a download or connection problem.
composer_output_is_network_error() {
    grep -qiE 'curl error|could not resolve host|failed to open stream|connection (timed out|refused)|network' <<< "$1"
}

# Prints "patch_target|minor_target|major_target" (each may be empty)
# from the versions Composer reports for the core package. Minor and major
# targets are limited to the minors in config/compatibility.conf, so a
# release the installer knows nothing about yet is never offered. The
# major target is the newest release of the next major (--upgrade).
get_update_targets() {
    local project_path="$1"
    local php_version="$2"
    local current="$3"
    local json
    local known_minors

    known_minors="$(get_supported_drupal_minors | paste -sd, -)"
    json="$(run_project_composer "$project_path" "$php_version" \
        show --all --format=json "$UPDATE_CORE_PACKAGE" 2>/dev/null)" || return 1

    # Single quotes: PHP code, not shell code.
    # shellcheck disable=SC2016
    printf '%s' "$json" | "php${php_version}" -r '
$d = json_decode(stream_get_contents(STDIN), true);
if (!is_array($d) || !isset($d["versions"])) { exit(1); }
$cur = $argv[1];
$known = explode(",", $argv[2]);
[$maj, $min] = array_map("intval", explode(".", $cur));
$patch = ""; $minor = ""; $major = "";
foreach ($d["versions"] as $v) {
    if (!preg_match("/^\d+\.\d+\.\d+$/", $v) || version_compare($v, $cur, "<=")) { continue; }
    [$vmaj, $vmin] = array_map("intval", explode(".", $v));
    if ($vmaj === $maj + 1 && in_array("$vmaj.$vmin", $known, true) &&
        ($major === "" || version_compare($v, $major, ">"))) { $major = $v; }
    if ($vmaj !== $maj) { continue; }
    if ($vmin === $min) { if ($patch === "" || version_compare($v, $patch, ">")) { $patch = $v; } }
    elseif ($vmin > $min && in_array("$vmaj.$vmin", $known, true) &&
            ($minor === "" || version_compare($v, $minor, ">"))) { $minor = $v; }
}
echo $patch, "|", $minor, "|", $major, "\n";
' "$current" "$known_minors"
}

# has_core_security_advisory, asked once more after a short wait when it
# could not check (an unstable connection).
check_core_security() {
    local status=0

    has_core_security_advisory "$@" || status=$?

    if [[ "$status" -eq 2 ]]; then
        sleep "${COMPOSER_RETRY_DELAY:-10}"
        status=0
        has_core_security_advisory "$@" || status=$?
    fi

    return "$status"
}

# Asks "composer audit" whether the installed Drupal core has a
# published security advisory (drupal.org security announcements).
# Returns 0: it has one, 1: none known, 2: could not check (network?).
has_core_security_advisory() {
    local project_path="$1"
    local php_version="$2"
    local json

    # composer audit exits non-zero when it finds advisories.
    json="$(run_project_composer "$project_path" "$php_version" \
        audit --locked --format=json 2>/dev/null)" || true

    [[ -n "$json" ]] || return 2

    # Single quotes: PHP code, not shell code.
    # shellcheck disable=SC2016
    printf '%s' "$json" | "php${php_version}" -r '
$d = json_decode(stream_get_contents(STDIN), true);
if (!is_array($d) || !array_key_exists("advisories", $d)) { exit(2); }
exit(empty($d["advisories"]["drupal/core"]) ? 1 : 0);
'
}

# Checks the target release against config/compatibility.conf.
check_target_compatibility() {
    local target="$1"
    local php_version="$2"
    local engine="$3"
    local minor
    local major="${target%%.*}"
    local minimum
    local installed

    minor="$(echo "$target" | cut -d. -f1,2)"

    if ! get_compatibility_row "$minor" > /dev/null; then
        echo "[BLOCKED] Drupal $minor is not in config/compatibility.conf yet."
        echo "          Add its requirements from drupal.org first."
        return 1
    fi

    if ! get_supported_php_versions "$minor" | grep -qxF "$php_version"; then
        echo "[BLOCKED] Drupal $minor does not support PHP $php_version."
        echo "          Supported: $(get_supported_php_versions "$minor" | tr '\n' ' ')"
        echo "          Change the project's PHP first: ./install.sh --php <project> <version>"
        return 1
    fi

    case "$engine" in
        mariadb|mysql|postgresql|sqlite)
            minimum="$(get_database_minimum_version "$major" "$engine")" || return 0
            installed="$(get_installed_database_version "$engine" 2>/dev/null)" || installed=""

            if [[ -n "$installed" ]] && ! database_version_meets_minimum "$installed" "$minimum"; then
                echo "[BLOCKED] Drupal $major needs $engine $minimum or newer; this system has $installed."
                return 1
            fi
            ;;
    esac
}

# ---------------------------------------------------
# --check-updates
# ---------------------------------------------------

run_check_updates() {
    local record
    local name
    local path
    local php
    local current
    local web_root
    local targets
    local patch
    local minor
    local major
    local security
    local security_status
    local found=0
    local vulnerable=()
    local upgradable=()

    echo
    echo "Checking for Drupal core updates (this asks Packagist, it may take a while)..."
    echo

    printf '%-20s %-9s %-11s %-9s %-9s %s\n' "PROJECT" "CURRENT" "PATCH" "MINOR" "MAJOR" "SECURITY (INSTALLED VERSION)"

    for record in "$(get_registry_directory)"/*.conf; do
        [[ -f "$record" ]] || continue
        found=1

        name="$(read_project_field "$record" machine_name)"
        path="$(read_project_field "$record" project_path)"
        php="$(read_project_field "$record" php_version)"
        web_root="$(read_project_field "$record" web_root)"
        [[ -n "$web_root" ]] || web_root="$path/web"

        if [[ ! -f "$path/composer.json" || ! -f "$path/composer.lock" ]]; then
            printf '%-20s %s\n' "$name" "skipped: not a Composer project"
            continue
        fi

        if [[ -z "$php" ]] || ! command -v "php${php}" > /dev/null; then
            printf '%-20s %s\n' "$name" "skipped: PHP ${php:-version unknown} not available"
            continue
        fi

        current="$(get_drupal_version_in "$web_root" 2>/dev/null)" || current=""

        if [[ "$current" =~ ^([0-9]+)\. ]] && [[ "${BASH_REMATCH[1]}" -lt 10 ]]; then
            printf '%-20s %-9s %s\n' "$name" "$current" "end of life: not updated by the installer"
            continue
        fi

        if [[ ! "$current" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
           ! UPDATE_CORE_PACKAGE="$(get_core_packages "$path" "$php")" ||
           [[ -z "$UPDATE_CORE_PACKAGE" ]]; then
            printf '%-20s %s\n' "$name" "skipped: Drupal core version or package not found"
            continue
        fi

        # The first line is the core package; the rest are companions.
        UPDATE_CORE_PACKAGE="${UPDATE_CORE_PACKAGE%%$'\n'*}"

        if ! targets="$(get_update_targets "$path" "$php" "$current")" &&
           ! { sleep "${COMPOSER_RETRY_DELAY:-10}"; targets="$(get_update_targets "$path" "$php" "$current")"; }; then
            printf '%-20s %-9s %s\n' "$name" "$current" "could not ask Packagist (network?)"
            continue
        fi

        IFS='|' read -r patch minor major <<< "$targets"
        [[ -n "$major" ]] && upgradable+=("$name")

        security_status=0
        check_core_security "$path" "$php" || security_status=$?

        case "$security_status" in
            0)
                security="VULNERABLE - update now"
                vulnerable+=("$name")
                ;;
            1) security="no known issues" ;;
            *) security="not checked (composer audit failed)" ;;
        esac

        printf '%-20s %-9s %-11s %-9s %-9s %s\n' "$name" "$current" \
            "${patch:-up to date}" "${minor:--}" "${major:--}" "$security"
    done

    if [[ "$found" -eq 0 ]]; then
        echo "No projects registered. Use --scan to register existing ones."
        return 0
    fi

    echo
    echo "PATCH: newest bug fix and security release of the same minor (recommended)."
    echo "MINOR: newest minor release this installer knows."
    echo "MAJOR: newest release of the next major this installer knows (--upgrade)."
    echo "SECURITY: whether the version installed now has a published Drupal core"
    echo "          security advisory (checked with \"composer audit\")."

    if [[ "${#vulnerable[@]}" -gt 0 ]]; then
        echo
        echo "[ACTION] Installed versions with a security advisory. Update them:"
        printf '  ./install.sh --update %s\n' "${vulnerable[@]}"
    fi

    if [[ "${#upgradable[@]}" -gt 0 ]]; then
        echo
        echo "Next major available for: ${upgradable[*]}"
        echo "  It is a bigger step: check first with ./install.sh --upgrade <project> --dry-run"
    fi

    echo
    echo "Update one with: ./install.sh --update <project> (--dry-run to preview)"
}
