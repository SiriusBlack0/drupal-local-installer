#!/usr/bin/env bash

# Checks before and after a PHP change: Composer platform, custom code,
# trial run, PHPCompatibility, PHP settings, Drupal log.

# Prints the failed requirements, one per line; returns 1 if any.
check_platform_requirements() {
    local project_path="$1"
    local new="$2"
    local json

    json="$(run_project_composer "$project_path" "$new" \
        check-platform-reqs --format=json 2>/dev/null)" || true

    # Single quotes: PHP code, not shell code.
    # shellcheck disable=SC2016
    printf '%s' "$json" | "php${new}" -r '
$rows = json_decode(stream_get_contents(STDIN), true);
if (!is_array($rows)) { echo "Composer did not answer (check-platform-reqs)\n"; exit(2); }
$bad = 0;
foreach ($rows as $r) {
    if (($r["status"] ?? "") === "success") { continue; }
    $bad = 1;
    $f = $r["failed_requirement"] ?? null;
    echo $r["name"], " ", $r["version"], ": ", $r["status"],
        $f ? " (" . $f["source"] . " requires " . $f["target"] . " " . $f["constraint"] . ")" : "", "\n";
}
exit($bad);
'
}

# config.platform.php in composer.json makes Composer resolve packages
# for that PHP version, whatever PHP runs.
get_composer_platform_php() {
    # Single quotes: PHP code, not shell code.
    # shellcheck disable=SC2016
    "php${2}" -r '
$c = json_decode(file_get_contents($argv[1]), true);
echo $c["config"]["platform"]["php"] ?? "";
' "$1/composer.json" 2>/dev/null
}

# PHP settings in the FPM php.ini that differ between the versions.
report_php_setting_differences() {
    local old="$1"
    local new="$2"
    local etc
    local key
    local old_value
    local new_value
    local found=0

    etc="$(get_php_etc_dir)"
    [[ -f "$etc/$old/fpm/php.ini" && -f "$etc/$new/fpm/php.ini" ]] || return 0

    for key in memory_limit max_execution_time upload_max_filesize post_max_size max_input_vars; do
        old_value="$("php${old}" -n -c "$etc/$old/fpm/php.ini" -r "echo ini_get('$key');" 2>/dev/null)" || continue
        new_value="$("php${new}" -n -c "$etc/$new/fpm/php.ini" -r "echo ini_get('$key');" 2>/dev/null)" || continue

        if [[ "$old_value" != "$new_value" ]]; then
            if [[ "$found" -eq 0 ]]; then
                echo "[INFO] Settings in $etc/$new/fpm/php.ini that differ from PHP $old:"
                found=1
            fi
            echo "         $key: $old_value (PHP $old) -> $new_value (PHP $new)"
        fi
    done
}

# ---------------------------------------------------
# Compatibility checks with the new PHP (run before anything changes;
# also in --dry-run)
# ---------------------------------------------------

PHP_COMPAT_CODE_DIRS=()
# Summary of the PHPCompatibility findings for the plan ("" = none).
PHP_COMPAT_FINDINGS=""

# Folders with the project's own code: web/modules/custom, ...
find_custom_code_dirs() {
    local web_root="$1"
    local sub

    PHP_COMPAT_CODE_DIRS=()

    for sub in modules/custom themes/custom profiles/custom; do
        [[ -d "$web_root/$sub" ]] && PHP_COMPAT_CODE_DIRS+=("$web_root/$sub")
    done

    return 0
}

# PHP files of the custom code (Drupal also uses .module, .inc, ...).
list_custom_php_files() {
    [[ "${#PHP_COMPAT_CODE_DIRS[@]}" -gt 0 ]] || return 0

    find "${PHP_COMPAT_CODE_DIRS[@]}" \( -path '*/vendor' -o -path '*/node_modules' \) -prune -o \
        -type f \( -name '*.php' -o -name '*.module' -o -name '*.inc' -o -name '*.install' \
        -o -name '*.theme' -o -name '*.profile' -o -name '*.engine' \) -print 2>/dev/null | sort
}

# "php -l" with the new PHP on every custom PHP file. Prints the files
# with errors; returns 1 if there are any.
lint_custom_code() {
    local new="$1"
    local file
    local message
    local failed=0

    while IFS= read -r file; do
        [[ -n "$file" ]] || continue

        if ! message="$("php${new}" -d display_errors=1 -l "$file" 2>&1)"; then
            failed=1
            printf '%s: %s\n' "${file#"$RECORD_PROJECT_PATH/"}" \
                "$(grep -m 1 -iE 'error' <<< "$message" | sed -E 's/ in .* on line ([0-9]+)/ (line \1)/')"
        fi
    done < <(list_custom_php_files)

    return "$failed"
}

# Drush started with the project's vendor/bin/drush and the given PHP
# first in PATH (never the ./drush launcher, which has its own PHP).
run_drush_with_php() {
    local project_path="$1"
    local php_version="$2"
    shift 2
    local shim
    local status=0

    [[ -x "$project_path/vendor/bin/drush" ]] || return 127
    command -v "php${php_version}" > /dev/null || return 127

    shim="$(mktemp -d)"
    chmod 755 "$shim"
    ln -s "$(command -v "php${php_version}")" "$shim/php"
    (cd "$project_path" && run_as_project_user "$PROJECT_USER" \
        env PATH="$shim:$PATH" "$project_path/vendor/bin/drush" "$@") || status=$?
    rm -rf "$shim"
    return "$status"
}

# Where the PHPCompatibility checker lives: outside every project, so no
# project's composer.json is changed by it.
get_phpcompat_dir() {
    printf '%s\n' "${PHPCOMPAT_TOOL_DIR:-$(dirname "$(get_registry_directory)")/tools/phpcompatibility}"
}

is_phpcompat_installed() {
    [[ -x "$(get_phpcompat_dir)/vendor/bin/phpcs" ]]
}

# Installs PHPCompatibility (with PHP_CodeSniffer) in its own folder,
# after asking. Version 10 is needed for PHP 8.x rules; it is still a
# pre-release, so its results are advice, not a verdict.
offer_phpcompat_install() {
    local php_version="$1"
    local dir
    local answer

    dir="$(get_phpcompat_dir)"

    echo
    echo "  The PHPCompatibility checker scans the custom code for functions and"
    echo "  syntax that the new PHP removed or changed. It is installed once, in"
    echo "  $dir"
    echo "  (outside your projects; no composer.json of a project changes)."

    if ! read -r -p "  Install it now? [y/N]: " answer || [[ ! "$answer" =~ ^[Yy]$ ]]; then
        return 1
    fi

    run_as_project_user "$PROJECT_USER" mkdir -p "$dir" || return 1

    printf '%s\n' \
        '{' \
        '    "name": "drupal-local-installer/phpcompat-tool",' \
        '    "description": "PHP compatibility checker used by drupal-local-installer (--php).",' \
        '    "require": {' \
        '        "phpcompatibility/php-compatibility": "^10.0@alpha",' \
        '        "squizlabs/php_codesniffer": "^3.13.3 || ^4.0",' \
        '        "dealerdirect/phpcodesniffer-composer-installer": "^1.0"' \
        '    },' \
        '    "minimum-stability": "alpha",' \
        '    "prefer-stable": true,' \
        '    "config": { "allow-plugins": { "dealerdirect/phpcodesniffer-composer-installer": true } }' \
        '}' | run_as_project_user "$PROJECT_USER" tee "$dir/composer.json" > /dev/null || return 1

    run_logged_retrying_network "  Installing PHPCompatibility" - \
        run_as_project_user "$PROJECT_USER" "php${php_version}" "$(get_composer_path)" \
        --working-dir="$dir" --no-interaction update
}

# Runs PHPCompatibility on the custom code. Prints a summary line, then
# up to 8 findings. Returns 0: nothing found, 1: errors, 2: warnings
# only, 3: could not run.
run_phpcompat_scan() {
    local new="$1"
    local php_version="$2"
    local json

    json="$(run_as_project_user "$PROJECT_USER" "php${php_version}" "$(get_phpcompat_dir)/vendor/bin/phpcs" \
        -q --report=json --standard=PHPCompatibility --runtime-set testVersion "$new" \
        --extensions=php,module,inc,install,theme,profile,engine \
        --ignore='*/vendor/*,*/node_modules/*' "${PHP_COMPAT_CODE_DIRS[@]}" 2>/dev/null)" || true

    # Single quotes: PHP code, not shell code.
    # shellcheck disable=SC2016
    printf '%s' "$json" | "php${php_version}" -r '
$d = json_decode(stream_get_contents(STDIN), true);
if (!is_array($d) || !isset($d["totals"])) { exit(3); }
$e = (int) $d["totals"]["errors"]; $w = (int) $d["totals"]["warnings"];
echo $e, " error(s), ", $w, " warning(s)\n";
$n = 0;
foreach ($d["files"] as $file => $info) {
    foreach ($info["messages"] as $m) {
        if ($n++ >= 8) { break 2; }
        echo str_replace($argv[1] . "/", "", $file), ":", $m["line"], " ", $m["type"], ": ", $m["message"], "\n";
    }
}
exit($e > 0 ? 1 : ($w > 0 ? 2 : 0));
' "$RECORD_PROJECT_PATH"
}

# All checks that need the new PHP installed. Prints one line per check.
# Returns 0: all fine, 1: the change must not go ahead, 2: findings the
# user should confirm (PHPCompatibility errors).
run_php_compat_checks() {
    local new="$1"
    local web_root="$2"
    local current="$3"
    local machine_name="$4"
    local failures
    local file_count
    local scan
    local scan_status
    local tool_php="$PHP_CHANGE_OLD"
    local result=0

    # The checker runs with the current PHP, or the new one when the
    # current one is gone.
    is_php_cli_installed "$tool_php" || tool_php="$new"

    PHP_COMPAT_FINDINGS=""
    find_custom_code_dirs "$web_root"
    file_count="$(list_custom_php_files | grep -c . || true)"

    echo
    echo "Compatibility checks with PHP $new (they change nothing):"
    echo "  [OK]      Drupal $current supports PHP $new (compatibility table)"

    if failures="$(check_platform_requirements "$RECORD_PROJECT_PATH" "$new")"; then
        echo "  [OK]      Composer: the installed packages accept PHP $new (check-platform-reqs)"
    else
        echo "  [FAILED]  Composer: the installed packages do not accept PHP $new:"
        printf '%s\n' "$failures" | sed 's/^/              /'
        echo "            Update them first (for example ./install.sh --update $machine_name)."
        result=1
    fi

    if [[ "$file_count" -eq 0 ]]; then
        echo "  [OK]      No custom modules, themes or profiles: no own code to check"
    elif failures="$(lint_custom_code "$new")"; then
        echo "  [OK]      Syntax of the custom code with PHP $new: $file_count file(s) (php -l)"
    else
        echo "  [FAILED]  Syntax errors in the custom code with PHP $new:"
        printf '%s\n' "$failures" | head -n 10 | sed 's/^/              /'
        result=1
    fi

    if [[ "$(run_drush_with_php "$RECORD_PROJECT_PATH" "$new" status --field=bootstrap 2>/dev/null)" == *"Successful"* ]]; then
        echo "  [OK]      Trial run: Drush bootstraps the site with PHP $new (every enabled module is loaded)"
    else
        echo "  [FAILED]  Trial run: Drush cannot bootstrap the site with PHP $new."
        echo "            To see why: cd $RECORD_PROJECT_PATH && php$new vendor/bin/drush status"
        result=1
    fi

    if [[ "$file_count" -gt 0 ]]; then
        if ! is_phpcompat_installed && ! offer_phpcompat_install "$tool_php"; then
            echo "  [SKIPPED] PHPCompatibility scan of the custom code (checker not installed)"
        else
            scan_status=0
            scan="$(run_phpcompat_scan "$new" "$tool_php")" || scan_status=$?

            case "$scan_status" in
                0) echo "  [OK]      PHPCompatibility: nothing found in the custom code" ;;
                1|2)
                    PHP_COMPAT_FINDINGS="$(head -n 1 <<< "$scan")"
                    echo "  [WARNING] PHPCompatibility: $PHP_COMPAT_FINDINGS in the custom code:"
                    tail -n +2 <<< "$scan" | sed 's/^/              /'
                    echo "            (A pre-release checker: read the findings, they are advice.)"
                    if [[ "$scan_status" -eq 1 && "$result" -eq 0 ]]; then
                        result=2
                    fi
                    ;;
                *) echo "  [SKIPPED] PHPCompatibility could not run (see $(get_phpcompat_dir))" ;;
            esac
        fi
    fi

    return "$result"
}

# The highest watchdog id of an error before the change, so that errors
# logged with the new PHP can be told apart. Empty without dblog.
get_last_watchdog_error_id() {
    local php_version="$1"
    local json

    json="$(run_drush_with_php "$RECORD_PROJECT_PATH" "$php_version" \
        watchdog:show --severity=Error --count=1 --format=json 2>/dev/null)" || return 0

    # Single quotes: PHP code, not shell code.
    # shellcheck disable=SC2016
    printf '%s' "$json" | "php${php_version}" -r '
$d = json_decode(stream_get_contents(STDIN), true);
if (!is_array($d)) { exit(1); }
$max = 0;
foreach ($d as $k => $row) { $max = max($max, (int) ($row["wid"] ?? $k)); }
echo $max, "\n";
' 2>/dev/null || true
}

# Errors Drupal logged since the change (first 5), as a warning.
report_new_watchdog_errors() {
    local since="$1"
    local json
    local found

    [[ -n "$since" ]] || return 0

    json="$(run_drush_with_php "$RECORD_PROJECT_PATH" "$PHP_CHANGE_NEW" \
        watchdog:show --severity=Error --count=50 --format=json 2>/dev/null)" || return 0

    # Single quotes: PHP code, not shell code.
    # shellcheck disable=SC2016
    found="$(printf '%s' "$json" | "php${PHP_CHANGE_NEW}" -r '
$d = json_decode(stream_get_contents(STDIN), true) ?: [];
$n = 0;
foreach ($d as $k => $row) {
    if ((int) ($row["wid"] ?? $k) <= (int) $argv[1]) { continue; }
    if ($n++ >= 5) { break; }
    echo strip_tags((string) ($row["type"] ?? "")), ": ", mb_substr(strip_tags((string) ($row["message"] ?? "")), 0, 160), "\n";
}
' "$since" 2>/dev/null)" || return 0

    if [[ -n "$found" ]]; then
        echo "[WARNING] Drupal logged new errors with PHP $PHP_CHANGE_NEW:"
        printf '%s\n' "$found" | sed 's/^/            - /'
        echo "          Details: ./drush watchdog:show --severity=Error"
    else
        echo "[OK] No new errors in the Drupal log"
    fi
}

# What only a person can check: the installer opens the front page only.
print_manual_php_checks() {
    local machine_name="$1"

    echo "Check it yourself (the installer only opened the front page):"
    echo "  - log in, open the pages your custom and contrib modules provide, submit a form"
    echo "  - ./drush cron, then ./drush watchdog:show --severity=Error"
    echo "  - back to PHP $PHP_CHANGE_OLD if something breaks: ./install.sh --php $machine_name $PHP_CHANGE_OLD"
}
