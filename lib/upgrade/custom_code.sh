#!/usr/bin/env bash

# ==================================================
# Custom code that allows only the current major (--upgrade)
#
# A custom module, theme or profile whose .info.yml says
# "core_version_requirement: ^10" is not loaded by Drupal 11, even when
# its code would work. Allowing the new major too ("^10 || ^11") changes
# nothing on the current major. The installer finds these lines with the
# project's own composer/semver, shows the change and makes it after "y",
# only in files that git has no other changes in. Contrib is never
# changed: it gets a release from drupal.org.
# ==================================================

# Set when the lines were shown, so the Upgrade Status report does not
# show the same fix again.
UPGRADE_INFO_YML_SHOWN=0

# Does version $1 satisfy constraint $2? With the project's own
# composer/semver (vendor/autoload.php); returns 2 when it cannot tell.
project_semver_satisfies() {
    [[ -f "$RECORD_PROJECT_PATH/vendor/autoload.php" ]] || return 2

    # Single quotes: PHP code, not shell code.
    # shellcheck disable=SC2016
    (cd "$RECORD_PROJECT_PATH" && "php${RECORD_PHP_VERSION}" -r '
require "vendor/autoload.php";
try {
    exit(\Composer\Semver\Semver::satisfies($argv[1], $argv[2]) ? 0 : 1);
} catch (\Throwable $e) {
    exit(2);
}
' "$1" "$2" 2>/dev/null)
}

# Custom .info.yml files whose core_version_requirement does not allow
# release $1: "file<TAB>value<TAB>type" lines, files relative to the
# project. Needs the project's vendor/autoload.php (composer/semver).
find_info_yml_blocking() {
    local target="$1"
    local -a dirs=()
    local -a files=()

    [[ -f "$RECORD_PROJECT_PATH/vendor/autoload.php" ]] || return 0
    mapfile -t dirs < <(get_custom_code_dirs)
    [[ "${#dirs[@]}" -gt 0 ]] || return 0

    mapfile -t files < <(cd "$RECORD_PROJECT_PATH" &&
        find "${dirs[@]}" -name '*.info.yml' -type f \
            -not -path '*/node_modules/*' -not -path '*/tests/*' 2>/dev/null | LC_ALL=C sort)
    [[ "${#files[@]}" -gt 0 ]] || return 0

    # Single quotes: PHP code, not shell code.
    # shellcheck disable=SC2016
    (cd "$RECORD_PROJECT_PATH" && "php${RECORD_PHP_VERSION}" -r '
require "vendor/autoload.php";
$target = $argv[1];
foreach (array_slice($argv, 2) as $file) {
    $text = (string) @file_get_contents($file);
    if (!preg_match("/^core_version_requirement:[ \t]*(.+?)[ \t]*$/m", $text, $m)) { continue; }
    $value = trim($m[1], " \t\"\x27");
    $type = preg_match("/^type:[ \t]*[\"\x27]?([a-z_]+)/m", $text, $t) ? $t[1] : "module";
    try {
        $ok = \Composer\Semver\Semver::satisfies($target, $value);
    } catch (\Throwable $e) {
        continue;
    }
    if (!$ok) { echo $file, "\t", $value, "\t", $type, "\n"; }
}
' "$target" "${files[@]}" 2>/dev/null)
}

# The site's default and admin theme: "default admin" (empty when Drush
# cannot tell).
get_site_themes() {
    local json

    json="$(run_project_drush "$RECORD_PROJECT_PATH" "$RECORD_PHP_VERSION" \
        config:get system.theme --format=json 2>/dev/null)" || return 0

    # Single quotes: PHP code, not shell code.
    # shellcheck disable=SC2016
    printf '%s' "$json" | "php${RECORD_PHP_VERSION}" -r '
$d = json_decode(stream_get_contents(STDIN), true);
if (!is_array($d)) { exit(0); }
if (isset($d["system.theme"]) && is_array($d["system.theme"])) { $d = $d["system.theme"]; }
echo (string) ($d["default"] ?? ""), " ", (string) ($d["admin"] ?? ""), "\n";
' 2>/dev/null || true
}

# Writes "core_version_requirement: $2" in .info.yml $1 (relative to the
# project), as the project user; the rest of the file stays as it is.
set_info_yml_requirement() {
    local file="$1"
    local value="$2"

    [[ "$file" != /* && "$file" != *..* && "$file" == *.info.yml ]] || return 1
    [[ -f "$RECORD_PROJECT_PATH/$file" && ! -L "$RECORD_PROJECT_PATH/$file" ]] || return 1

    # Single quotes: PHP code, not shell code.
    # shellcheck disable=SC2016
    run_as_project_user "$PROJECT_USER" "php${RECORD_PHP_VERSION}" -r '
$text = file_get_contents($argv[1]);
$new = preg_replace("/^core_version_requirement:.*$/m", "core_version_requirement: " . $argv[2], $text, 1, $count);
if ($count !== 1 || file_put_contents($argv[1], $new) === false) { exit(1); }
' "$RECORD_PROJECT_PATH/$file" "$value"
}

# The whole step: shown in the dry run; in the real run changed after
# "y". $1: the new major; $2: the target release.
offer_info_yml_fixes() {
    local to_major="$1"
    local target="$2"
    local found
    local file
    local value
    local type
    local name
    local default_theme=""
    local admin_theme=""
    local themes
    local dirty=""
    local answer
    local -a files=()
    local -a warnings=()

    UPGRADE_INFO_YML_SHOWN=0
    found="$(find_info_yml_blocking "$target")"
    [[ -n "$found" ]] || return 0

    # Read by print_info_yml_fixes (upgrade_status.sh).
    # shellcheck disable=SC2034
    UPGRADE_INFO_YML_SHOWN=1
    themes="$(get_site_themes)"
    read -r default_theme admin_theme <<< "$themes"

    echo
    echo "Custom code that allows only the current major (core_version_requirement);"
    echo "Drupal $to_major would not load it:"

    while IFS=$'\t' read -r file value type; do
        files+=("$file")
        name="$(basename "$file" .info.yml)"
        echo "  $file: $value  ->  $value || ^$to_major"

        if [[ "$type" == "theme" && -n "$name" ]]; then
            if [[ "$name" == "$default_theme" ]]; then
                warnings+=("$name is the site's default theme")
            elif [[ "$name" == "$admin_theme" ]]; then
                warnings+=("$name is the site's admin theme")
            fi
        fi
    done <<< "$found"

    echo "This changes nothing on Drupal $(cut -d. -f1 <<< "$UPDATE_PREVIOUS_VERSION"); whether the code itself works on"
    echo "Drupal $to_major is what Upgrade Status and the checks after the upgrade look at."

    for value in "${warnings[@]}"; do
        echo "[WARNING] $value: if its templates or code do not work on Drupal $to_major,"
        echo "          every page fails after the upgrade. Check it first (Upgrade Status,"
        echo "          Twig deprecations), or switch to a core theme for the upgrade."
    done

    if [[ "$REMOVE_DRY_RUN" -eq 1 ]]; then
        echo "[DRY RUN] Not changed; the real run offers it."
        return 0
    fi

    if [[ -d "$RECORD_PROJECT_PATH/.git" ]]; then
        dirty="$(run_as_project_user "$PROJECT_USER" git -C "$RECORD_PROJECT_PATH" status --porcelain -- "${files[@]}" 2>/dev/null)"
    fi

    if [[ ! -d "$RECORD_PROJECT_PATH/.git" || -n "$dirty" ]]; then
        if [[ -n "$dirty" ]]; then
            echo "[INFO] Not changed by the installer: these files have changes that are not"
            echo "       committed. Commit them first, or change the lines yourself."
        else
            echo "[INFO] Not changed by the installer: the project is not in git, so the change"
            echo "       could not be shown and undone with git. Change the lines yourself."
        fi
        return 0
    fi

    if ! read -r -p "Change these lines now (git shows and can undo them)? [y/N]: " answer; then
        echo
        answer="n"
    fi

    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        echo "Not changed."
        return 0
    fi

    while IFS=$'\t' read -r file value _; do
        if set_info_yml_requirement "$file" "$value || ^$to_major"; then
            echo "[OK] $file"
        else
            echo "[WARNING] Could not change $file"
        fi
    done <<< "$found"

    echo "     (in the commit line at the end; git diff shows them)"
}
