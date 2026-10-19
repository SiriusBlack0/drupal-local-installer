#!/usr/bin/env bash

# Major upgrade (--upgrade): the upgrade table, the target release and
# the checks that change nothing.

get_upgrades_file() {
    printf '%s\n' "${DRUPAL_UPGRADES_FILE:-$COMPATIBILITY_LIB_DIR/../config/upgrades.conf}"
}

# The line of config/upgrades.conf for upgrades from major $1.
get_upgrade_row() {
    local file

    file="$(get_upgrades_file)"

    if [[ ! -r "$file" ]]; then
        echo "[ERROR] Upgrade table not found: $file" >&2
        return 1
    fi

    grep -Ev '^[[:space:]]*(#|$)' "$file" | awk -F'|' -v major="$1" '
        $1 == major { print; found = 1; exit }
        END { exit !found }
    '
}

# The newest stable release of the new major whose minor is in
# config/compatibility.conf (empty when there is none yet).
get_upgrade_target() {
    local project_path="$1"
    local php_version="$2"
    local to_major="$3"
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
$major = (int) $argv[1];
$known = explode(",", $argv[2]);
$best = "";
foreach ($d["versions"] as $v) {
    if (!preg_match("/^\d+\.\d+\.\d+$/", $v)) { continue; }
    [$vmaj, $vmin] = array_map("intval", explode(".", $v));
    if ($vmaj !== $major || !in_array("$vmaj.$vmin", $known, true)) { continue; }
    if ($best === "" || version_compare($v, $best, ">")) { $best = $v; }
}
echo $best, "\n";
' "$to_major" "$known_minors"
}

# PHP versions supported by both Drupal minors, one per line.
get_common_php_versions() {
    comm -12 <(get_supported_php_versions "$1" | sort) <(get_supported_php_versions "$2" | sort) | sort -V
}

# "name section" for each package composer.json requires (section is
# require or require-dev).
get_composer_sections() {
    # Single quotes: PHP code, not shell code.
    # shellcheck disable=SC2016
    "php${RECORD_PHP_VERSION}" -r '
$c = json_decode(file_get_contents($argv[1]), true) ?: [];
foreach (array_slice($argv, 2) as $p) {
    if (isset($c["require"][$p])) { echo $p, " require\n"; }
    elseif (isset($c["require-dev"][$p])) { echo $p, " require-dev\n"; }
}
' "$RECORD_PROJECT_PATH/composer.json" "$@"
}

# Enabled modules and themes of the list ($1, comma separated) that
# composer.json does not require from drupal.org. One per line.
# Returns 2 when Drush cannot list them.
get_removed_core_extensions_in_use() {
    local list="$1"
    local json

    [[ -n "$list" ]] || return 0

    json="$(run_project_drush "$RECORD_PROJECT_PATH" "$RECORD_PHP_VERSION" \
        pm:list --status=enabled --format=json 2>/dev/null)" || return 2

    # Single quotes: PHP code, not shell code.
    # shellcheck disable=SC2016
    printf '%s' "$json" | "php${RECORD_PHP_VERSION}" -r '
$d = json_decode(stream_get_contents(STDIN), true);
if (!is_array($d)) { exit(2); }
$c = json_decode(file_get_contents($argv[2]), true) ?: [];
$req = ($c["require"] ?? []) + ($c["require-dev"] ?? []);
foreach (explode(",", $argv[1]) as $name) {
    if (isset($d[$name]) && !isset($req["drupal/$name"])) { echo $name, "\n"; }
}
' "$list" "$RECORD_PROJECT_PATH/composer.json"
}

# drupal.org projects that keep Composer from installing the new core
# ("drupal/foo 1.2.0 requires drupal/core ^9 || ^10 -> ..."), one per line.
get_upgrade_blocking_projects() {
    grep -oE 'drupal/[a-z0-9_]+(\[[^]]*\]| [^ ]+)? requires? drupal/core ' <<< "$1" |
        grep -oE '^drupal/[a-z0-9_]+' | grep -vE '^drupal/core(-|$)' | sort -u || true
}

# The checks that need no Composer run. Prints one line per check;
# returns 1 when the upgrade must not go ahead.
run_upgrade_prechecks() {
    local machine_name="$1"
    local current="$2"
    local target="$3"
    local minimum="$4"
    local removed="$5"
    local from_minor
    local target_minor
    local to_major="${target%%.*}"
    local common
    local db_minimum
    local db_installed
    local in_use
    local in_use_status=0
    local name
    local result=0

    from_minor="$(echo "$current" | cut -d. -f1,2)"
    target_minor="$(echo "$target" | cut -d. -f1,2)"

    echo
    echo "Checks for Drupal $current -> $target (they change nothing):"

    if version_at_least "$from_minor" "$minimum"; then
        echo "  [OK]      Drupal $current can be upgraded (upgrades to Drupal $to_major start from $minimum)"
    else
        echo "  [FAILED]  Upgrades to Drupal $to_major start from Drupal $minimum; this site has $current."
        echo "            Update it first: ./install.sh --update $machine_name (choose the newest minor),"
        echo "            then run --upgrade again."
        result=1
    fi

    if get_supported_php_versions "$target_minor" | grep -qxF "$RECORD_PHP_VERSION"; then
        echo "  [OK]      PHP $RECORD_PHP_VERSION is supported by Drupal $target_minor"
    else
        common="$(get_common_php_versions "$from_minor" "$target_minor" | paste -sd' ' -)"
        echo "  [FAILED]  Drupal $target_minor needs PHP $(get_supported_php_versions "$target_minor" | paste -sd' ' -); the project runs PHP $RECORD_PHP_VERSION."
        echo "            Change PHP first, as its own step (if something breaks, you know"
        echo "            which change did it):"

        if [[ -n "$common" ]]; then
            echo "              ./install.sh --php $machine_name ${common##* }   ($common: Drupal $from_minor and $target_minor both run on it)"
        else
            echo "              no PHP version runs both Drupal $from_minor and $target_minor: update Drupal first (--update)"
        fi

        echo "            then run --upgrade again."
        result=1
    fi

    case "$RECORD_DATABASE_ENGINE" in
        mariadb|mysql|postgresql|sqlite)
            db_minimum="$(get_database_minimum_version "$to_major" "$RECORD_DATABASE_ENGINE")" || db_minimum=""
            db_installed="$(get_installed_database_version "$RECORD_DATABASE_ENGINE" 2>/dev/null)" || db_installed=""

            if [[ -z "$db_minimum" || -z "$db_installed" ]]; then
                echo "  [SKIPPED] Database version (${RECORD_DATABASE_ENGINE}): not known"
            elif database_version_meets_minimum "$db_installed" "$db_minimum"; then
                echo "  [OK]      $RECORD_DATABASE_ENGINE $db_installed (Drupal $to_major needs $db_minimum or newer)"
            else
                echo "  [FAILED]  Drupal $to_major needs $RECORD_DATABASE_ENGINE $db_minimum or newer; this system has $db_installed."
                result=1
            fi
            ;;
    esac

    in_use="$(get_removed_core_extensions_in_use "$removed")" || in_use_status=$?

    if [[ "$in_use_status" -ne 0 ]]; then
        echo "  [SKIPPED] Modules removed from core: Drush could not list the enabled modules"
    elif [[ -n "$in_use" ]]; then
        echo "  [FAILED]  Enabled here, but no longer part of Drupal $to_major core:"

        while IFS= read -r name; do
            echo "              - $name: composer require drupal/$name (the drupal.org project that"
            echo "                replaces it), or uninstall it if unused: ./drush pm:uninstall $name"
        done <<< "$in_use"

        result=1
    else
        echo "  [OK]      No enabled module or theme that Drupal $to_major removed from core"
    fi

    return "$result"
}
