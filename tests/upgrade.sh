#!/usr/bin/env bash

# ./install.sh --upgrade NAME. Everything happens in a temporary
# directory: composer, drush, php8.x, sudo, mysqldump, mysql and curl are
# stubs that record their calls.

set -euo pipefail

cd "$(dirname "$0")/.."

source lib/output.sh
source lib/system.sh
source lib/database.sh
source lib/php_fpm.sh
source lib/nginx.sh
source lib/registry.sh
source lib/project.sh
source lib/compatibility.sh
source lib/scan.sh
source lib/remove.sh
source lib/composer.sh
source lib/update.sh
source lib/upgrade.sh

work_dir="$(mktemp -d)"
trap 'chmod -R u+w "$work_dir" 2>/dev/null; rm -rf "$work_dir"' EXIT

export XDG_DATA_HOME="$work_dir/data"
export XDG_STATE_HOME="$work_dir/state"
export COMPOSER_RETRY_DELAY=0
export DRUPAL_PROJECTS_DIR="$work_dir/www"
etc_dir="$work_dir/etc"
stub_bin="$work_dir/bin"
export CALLS_FILE="$work_dir/calls"
export REAL_PHP
REAL_PHP="$(command -v php)"
mkdir -p "$DRUPAL_PROJECTS_DIR" "$etc_dir/sites-available" "$etc_dir/sites-enabled" "$etc_dir/pool.d" "$stub_bin"

pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; exit 1; }

get_nginx_config_path() { printf '%s/sites-available/%s.conf\n' "$etc_dir" "$1"; }
get_nginx_enabled_path() { printf '%s/sites-enabled/%s.conf\n' "$etc_dir" "$1"; }
get_php_fpm_pool_config_path() { printf '%s/pool.d/%s.conf\n' "$etc_dir" "$1"; }
get_backup_base_dir() { printf '%s/backups\n' "$work_dir"; }
get_installed_database_version() { [[ -n "${DB_VERSION:-}" ]] && echo "$DB_VERSION"; }
require_sudo() { echo "sudo-asked" >> "$CALLS_FILE"; }

# php8.x: PHP code runs with the real php; anything else (composer) is
# started directly.
for version in 8.2 8.3; do
    cat > "$stub_bin/php$version" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == "-r" ]] && exec "$REAL_PHP" "$@"
exec "$@"
STUB
done

cat > "$stub_bin/sudo" <<'STUB'
#!/usr/bin/env bash
echo "sudo $*" >> "$CALLS_FILE"
[[ "$1" == "-u" ]] && shift 2
exec "$@"
STUB

cat > "$stub_bin/mysqldump" <<'STUB'
#!/usr/bin/env bash
echo "dump $*" >> "$CALLS_FILE"
echo "CREATE TABLE node;"
STUB

cat > "$stub_bin/mysql" <<'STUB'
#!/usr/bin/env bash
echo "mysql restore: $(cat)" >> "$CALLS_FILE"
STUB

cat > "$stub_bin/curl" <<'STUB'
#!/usr/bin/env bash
printf 'HTTP/1.1 200 OK\r\nX-Generator: Drupal 11 (https://www.drupal.org)\r\n'
STUB

# Composer. The lock file holds "core=<version>" (and "upgrade_status"
# while that is installed); install and update write the core version
# into core/lib/Drupal.php like the real thing would. COMPOSER=<file>
# makes it work on that copy of composer.json, as the real one does.
# BLOCK_CONTRIB=1: drupal/pathauto has no release for Drupal 11, unless
# the lenient plugin is installed and lists it.
# NEW_PLUGIN=1: Drupal 11 brings symfony/runtime, a Composer plugin; the
# install stops at it unless composer.json allows or refuses it
# (NEW_PLUGIN_HIDDEN=1: the trial lock does not show it).
cat > "$stub_bin/composer" <<'STUB'
#!/usr/bin/env bash
dir=""
args=()
for a in "$@"; do
    case "$a" in
        --working-dir=*) dir="${a#--working-dir=}" ;;
        --no-interaction) ;;
        *) args+=("$a") ;;
    esac
done
json="$dir/${COMPOSER:-composer.json}"
lock="${json%.json}.lock"
echo "composer${COMPOSER:+ [$COMPOSER]} ${args[*]}" >> "$CALLS_FILE"
set_version() {
    printf "<?php\nclass Drupal {\n  const VERSION = '%s';\n}\n" "$1" > "$dir/web/core/lib/Drupal.php"
}
# Adds "package:constraint" arguments to require or require-dev.
add_requirements() {
    "$REAL_PHP" -r '
$f = $argv[1]; $section = $argv[2];
$c = json_decode(file_get_contents($f), true);
foreach (array_slice($argv, 3) as $a) { [$p, $v] = explode(":", $a, 2); $c[$section][$p] = $v; }
file_put_contents($f, json_encode($c, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n");
' "$json" "$@"
}
blocked_by_contrib() {
    [[ "${BLOCK_CONTRIB:-0}" == "1" ]] || return 1
    [[ -f "$dir/vendor/lenient" ]] && grep -q "drupal/pathauto" "$dir/lenient-list" 2>/dev/null && return 1
    echo "Your requirements could not be resolved to an installable set of packages."
    echo "  Problem 1"
    echo "    - drupal/pathauto[1.12.0, ..., 1.13.0] require drupal/core ^9.4 || ^10 -> found drupal/core[10.6.19] but it conflicts with your temporary update constraint (drupal/core:11.4.2)."
    echo "    - drupal/core-recommended 11.4.2 requires drupal/core 11.4.2 -> satisfiable by drupal/core[11.4.2]."
    return 0
}
case "${args[0]}" in
    show)
        echo "{\"name\":\"${args[-1]}\",\"versions\":${COMPOSER_VERSIONS:-[]}}"
        ;;
    config)
        if [[ " ${args[*]} " == *" extra.drupal-lenient.allowed-list "* ]]; then
            echo "${args[-1]}" > "$dir/lenient-list"
        fi
        if [[ " ${args[*]} " == *" allow-plugins.symfony/runtime "* ]]; then
            echo "${args[-1]}" > "$dir/runtime-decision"
        fi
        ;;
    require)
        rest=("${args[@]:1}")
        section=require
        no_update=0
        packages=()
        for a in "${rest[@]}"; do
            case "$a" in
                --dev) section=require-dev ;;
                --no-update) no_update=1 ;;
                -*) ;;
                *) packages+=("$a") ;;
            esac
        done
        if [[ "${packages[0]}" == drupal/upgrade_status:* ]]; then
            [[ "${US_ADD_FAILS:-0}" == "1" ]] && { echo "curl error 6: Could not resolve host"; exit 1; }
            add_requirements "$section" "${packages[@]}"
            echo "upgrade_status" >> "$lock"
            mkdir -p "$dir/vendor" && touch "$dir/vendor/upgrade_status"
            exit 0
        fi
        if [[ "${packages[0]}" == mglaman/composer-drupal-lenient* ]]; then
            mkdir -p "$dir/vendor" && touch "$dir/vendor/lenient"
            add_requirements require "mglaman/composer-drupal-lenient:^1.0"
            exit 0
        fi
        add_requirements "$section" "${packages[@]}"
        [[ "$no_update" -eq 1 ]] && echo "./${COMPOSER:-composer.json} has been updated"
        ;;
    update)
        target=""
        for a in "${args[@]}"; do [[ "$a" == drupal/core*:* ]] && target="${a##*:}"; done
        if blocked_by_contrib; then exit 2; fi
        if [[ "${BLOCK_OTHER:-0}" == "1" ]]; then
            echo "Your requirements could not be resolved to an installable set of packages."
            echo "  - Root composer.json requires symfony/console ~6.4 -> found symfony/console[v6.4.0] but it conflicts."
            exit 2
        fi
        # The trial: only the copy of the lock file is written.
        if [[ " ${args[*]} " == *" --no-install "* ]]; then
            [[ " ${args[*]} " == *" --no-scripts "* ]] || { echo "trial without --no-scripts"; exit 9; }
            echo "Lock file operations: 3 installs, 41 updates, 1 removal"
            echo "  - Upgrading drupal/core (10.6.19 => $target)"
            echo "  - Upgrading drupal/core-recommended (10.6.19 => $target)"
            echo "  - Upgrading drupal/pathauto (1.12.0 => 1.13.0)"
            echo "  - Upgrading symfony/console (v6.4.0 => v7.3.4)"
            if [[ "${NEW_PLUGIN:-0}" == "1" && "${NEW_PLUGIN_HIDDEN:-0}" != "1" ]]; then
                echo '{"packages":[{"name":"symfony/runtime","type":"composer-plugin","description":"Enables decoupling PHP applications from global state"},{"name":"drupal/core-composer-scaffold","type":"composer-plugin"}],"packages-dev":[]}' > "$lock"
                "$REAL_PHP" -r '$f=$argv[1]; $c=json_decode(file_get_contents($f),true); $c["config"]["allow-plugins"]=["drupal/*"=>true]; file_put_contents($f, json_encode($c));' "$json"
            fi
            exit 0
        fi
        if [[ "${NEW_PLUGIN:-0}" == "1" && ! -f "$dir/runtime-decision" ]]; then
            echo "  In PluginManager.php line 821:"
            echo "    symfony/runtime contains a Composer plugin which is blocked by your allow-plugins config. You may add it to the lis"
            exit 1
        fi
        grep -q '"\^11' "$json" || { echo "core-recommended still requires Drupal 10"; exit 2; }
        sed -i "s/^core=.*/core=$target/" "$lock"
        [[ "${UPGRADE_FAILS:-0}" == "1" ]] && exit 1
        set_version "$target"
        mkdir -p "$dir/vendor" && echo "drush 13" > "$dir/vendor/drush-version"
        if [[ "${UPGRADE_INTERRUPT:-0}" == "1" ]]; then
            kill -INT "$PPID"
            exit 130
        fi
        ;;
    install)
        set_version "$(grep -oP 'core=\K.*' "$lock")"
        grep -qx upgrade_status "$lock" || rm -f "$dir/vendor/upgrade_status"
        ;;
esac
exit 0
STUB

chmod +x "$stub_bin"/*
PATH="$stub_bin:$PATH"

# The ./drush launcher of a project. Upgrade Status is "in the code
# base" while vendor/upgrade_status exists and enabled while
# .us-enabled exists. US_REPORT: clean, custom or contrib findings.
write_drush_stub() {
    cat > "$1/drush" <<'STUB'
#!/usr/bin/env bash
echo "drush $*" >> "$CALLS_FILE"
root="$(dirname "$0")"
web="$root/web"
case "$1" in
    status)
        [[ "${BOOTSTRAP_FAILS_AFTER:-0}" == "1" ]] && grep -q "'11\." "$web/core/lib/Drupal.php" && exit 1
        echo "Successful"
        ;;
    pm:list)
        if [[ " $* " == *" --status=enabled "* ]]; then
            extra=""
            [[ -n "${ENABLED_EXTRA:-}" ]] && extra=",\"$ENABLED_EXTRA\":{\"status\":\"Enabled\"}"
            printf '{"node":{"status":"Enabled"},"olivero":{"status":"Enabled"}%s}\n' "$extra"
        elif [[ -f "$root/vendor/upgrade_status" ]]; then
            if [[ -f "$root/.us-enabled" ]]; then
                echo '{"node":{"status":"Enabled"},"upgrade_status":{"status":"Enabled"}}'
            else
                echo '{"node":{"status":"Enabled"},"upgrade_status":{"status":"Disabled"}}'
            fi
        else
            echo '{"node":{"status":"Enabled"}}'
        fi
        ;;
    pm:install)
        touch "$root/.us-enabled"
        ;;
    pm:uninstall)
        [[ "${US_UNINSTALL_FAILS:-0}" == "1" ]] && exit 1
        rm -f "$root/.us-enabled"
        ;;
    upgrade_status:analyze)
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo '<checkstyle>'
        case "${US_REPORT:-clean}" in
            custom)
                echo "<file name=\"$web/modules/custom/shop/shop.module\"><error line=\"12\" message=\"Call to deprecated function drupal_set_message().\" severity=\"error\"></error></file>"
                echo "<file name=\"$web/modules/contrib/pathauto/pathauto.module\"><error line=\"3\" message=\"Deprecated hook.\" severity=\"warning\"></error></file>"
                ;;
            twig)
                echo "<file name=\"$web/themes/custom/shop_theme/templates/select.html.twig\"><error line=\"13\" message=\"Since twig/twig 3.12: Twig Filter &quot;spaceless&quot; is deprecated. See https://drupal.org/node/3071078.\" severity=\"error\"></error></file>"
                ;;
            infoyml)
                # Like the real report: paths relative to the Drupal root.
                echo "<file name=\"modules/custom/shop/shop.info.yml\"><error line=\"5\" message=\"Value of core_version_requirement: ^10 is not compatible with the next major version of Drupal core. See https://drupal.org/node/3070687.\" severity=\"error\"></error></file>"
                ;;
            noise)
                # Like a large real project: thousands of "Check manually"
                # findings in contrib, PHPUnit missing in the tests of custom code.
                echo "<file name=\"$web/modules/contrib/search_api/src/Plugin/Foo.php\">"
                for _ in 1 2 3 4 5; do echo "<error line=\"1\" message=\"Class Bar not found.\" severity=\"error\"></error>"; done
                echo "</file>"
                echo "<file name=\"$web/modules/custom/shop/tests/src/Kernel/ShopTest.php\"><error line=\"20\" message=\"Call to an undefined method ShopTest::assertSame().\" severity=\"error\"></error></file>"
                ;;
            contrib)
                echo "<file name=\"$web/modules/contrib/pathauto/pathauto.info.yml\"><error line=\"1\" message=\"Value of core_version_requirement: ^9 || ^10 is not compatible with Drupal 11.\" severity=\"error\"></error></file>"
                ;;
        esac
        echo '</checkstyle>'
        ;;
    updatedb)
        [[ "${UPDB_FAILS:-0}" == "1" ]] && exit 1
        ;;
    php:eval)
        # INCOMPATIBLE=1: a custom module that allows only Drupal 10 stays
        # enabled after the upgrade.
        if [[ "${INCOMPATIBLE:-0}" == "1" ]] && grep -q "'11\." "$web/core/lib/Drupal.php"; then
            echo "module|road_map|modules/custom/road_map"
        fi
        ;;
    core:requirements)
        echo '[{"title":"Cron"}]'
        ;;
    watchdog:show)
        # WATCHDOG_NEW=1: Drupal 11 logs a new error; entry 5 is old.
        if [[ "${WATCHDOG_NEW:-0}" == "1" ]] && grep -q "'11\." "$web/core/lib/Drupal.php"; then
            echo '{"6":{"wid":"6","type":"php","message":"Error: Call to undefined function old_api() in shop_page()"},"5":{"wid":"5","type":"smtp","message":"old SMTP error"}}'
        else
            echo '{"5":{"wid":"5","type":"smtp","message":"old SMTP error"}}'
        fi
        ;;
esac
exit 0
STUB
    chmod +x "$1/drush"
}

make_project() {
    local name="$1"
    local version="${2:-10.6.19}"

    PROJECT_NAME="$name"
    PROJECT_MACHINE_NAME="$name"
    PROJECT_USER="$(id -un)"
    PROJECT_PATH="$DRUPAL_PROJECTS_DIR/$name"
    DRUPAL_VERSION="$version"
    PHP_VERSION="${3:-8.3}"
    DATABASE_ENGINE="mariadb"
    DATABASE_NAME="$name"
    DATABASE_USER="${name}_user"
    SQLITE_DATABASE_PATH="$PROJECT_PATH/private/database.sqlite"
    LOG_FILE=""

    rm -rf "$PROJECT_PATH" "$(record_of "$name")"
    mkdir -p "$PROJECT_PATH/web/core/lib" "$PROJECT_PATH/web/modules/contrib/pathauto" "$PROJECT_PATH/vendor" "$PROJECT_PATH/private"
    printf "<?php\nclass Drupal {\n  const VERSION = '%s';\n}\n" "$version" > "$PROJECT_PATH/web/core/lib/Drupal.php"
    cat > "$PROJECT_PATH/composer.json" <<'JSON'
{
    "require": {
        "drupal/core-recommended": "^10.6",
        "drupal/core-composer-scaffold": "^10.6",
        "drupal/core-project-message": "^10.6",
        "drupal/pathauto": "^1.12",
        "drush/drush": "^12"
    },
    "require-dev": { "drupal/core-dev": "^10.6" },
    "extra": {
        "installer-paths": {
            "web/core": ["type:drupal-core"],
            "web/modules/contrib/{$name}": ["type:drupal-module"]
        }
    }
}
JSON
    echo "core=$version" > "$PROJECT_PATH/composer.lock"
    cp "$PROJECT_PATH/composer.json" "$work_dir/$name.composer.json"
    write_drush_stub "$PROJECT_PATH"
    echo "site" > "$etc_dir/sites-available/$name.conf"
    ln -sf "$etc_dir/sites-available/$name.conf" "$etc_dir/sites-enabled/$name.conf"
    echo "pool" > "$etc_dir/pool.d/$name.conf"
    write_project_record > /dev/null
    : > "$CALLS_FILE"
}

record_of() { printf '%s/drupal-local-installer/projects/%s.conf\n' "$XDG_DATA_HOME" "$1"; }
version_of() { get_drupal_version_in "$DRUPAL_PROJECTS_DIR/$1/web"; }
calls_line() { grep -n -m1 -F -- "$1" "$CALLS_FILE" | cut -d: -f1; }
composer_unchanged() { cmp -s "$DRUPAL_PROJECTS_DIR/$1/composer.json" "$work_dir/$1.composer.json"; }
no_copies_left() { ! ls "$DRUPAL_PROJECTS_DIR/$1"/composer.dli-upgrade.* > /dev/null 2>&1; }

export COMPOSER_VERSIONS='["12.0.0-beta1","11.5.0","11.4.2","11.4.0","11.4.0-rc1","11.3.12","10.6.19","10.6.18","11.x-dev"]'

# Test 1: The table, the target and Composer's reasons.

make_project alpha
UPDATE_CORE_PACKAGE="drupal/core-recommended"
RECORD_PROJECT_PATH="$PROJECT_PATH"
RECORD_PHP_VERSION="8.3"

if [[ "$(get_upgrade_row 10)" == "10|11|10.3|^13|^4.3|action,book,forum,statistics,tour,tracker" &&
      "$(get_upgrade_target "$PROJECT_PATH" 8.3 11)" == "11.4.2" &&
      -z "$(get_upgrade_target "$PROJECT_PATH" 8.3 12)" ]] &&
   ! get_upgrade_row 9 > /dev/null; then
    pass "Upgrade table read; target: newest stable release of a known minor (no beta, no unknown minor)"
else
    fail "table/target: '$(get_upgrade_target "$PROJECT_PATH" 8.3 11)'"
fi

sample='  Problem 1
    - drupal/pathauto[1.12.0, ..., 1.13.0] require drupal/core ^9.4 || ^10 -> found drupal/core[10.6.19]
    - drupal/token 1.15.0 requires drupal/core ^9.2 || ^10 -> found drupal/core[10.6.19]
    - drupal/core-recommended 11.4.2 requires drupal/core 11.4.2 -> satisfiable by drupal/core[11.4.2].'

if [[ "$(get_upgrade_blocking_projects "$sample" | paste -sd' ')" == "drupal/pathauto drupal/token" &&
      -z "$(get_upgrade_blocking_projects "nothing here")" ]]; then
    pass "drupal.org projects that block the new core are found in Composer's message (core itself is not)"
else
    fail "blockers: $(get_upgrade_blocking_projects "$sample")"
fi

# Test 2: Dry run: checks, Composer trial on a copy, plan; nothing changed.

if output="$(printf '3\n' | REMOVE_DRY_RUN=1 run_upgrade_project alpha)" &&
   [[ "$output" == *"Checks for Drupal 10.6.19 -> 11.4.2 (they change nothing):"* &&
      "$output" == *"[OK]      Drupal 10.6.19 can be upgraded (upgrades to Drupal 11 start from 10.3)"* &&
      "$output" == *"[OK]      PHP 8.3 is supported by Drupal 11.4"* &&
      "$output" == *"[OK]      No enabled module or theme that Drupal 11 removed from core"* &&
      "$output" == *"[SKIPPED] Upgrade Status scan (your choice)"* &&
      "$output" == *"Trying the upgrade with Composer (on a copy of composer.json) ... OK"* &&
      "$output" == *"Drupal core:   10.6.19 -> 11.4.2 (major upgrade)"* &&
      "$output" == *"composer.json: drupal/core-recommended ^11.4, drupal/core-composer-scaffold ^11.4, drupal/core-project-message ^11.4, drush/drush ^13, drupal/core-dev ^11.4"* &&
      "$output" == *"Packages:      41 updated, 3 new, 1 removed"* &&
      "$output" == *"Contrib:       new releases for Drupal 11 (1):"* &&
      "$output" == *"pathauto 1.12.0 -> 1.13.0"* && "$output" != *"core 10.6.19 -> 11.4.2"* &&
      "$output" == *"[DRY RUN] Nothing was changed."* ]] &&
   composer_unchanged alpha && no_copies_left alpha && [[ "$(version_of alpha)" == "10.6.19" ]] &&
   grep -q "composer \[composer.dli-upgrade.json\] require --no-update drupal/core-recommended:^11.4" "$CALLS_FILE" &&
   grep -q "composer \[composer.dli-upgrade.json\] update drupal/\* drush/drush --with drupal/core-recommended:11.4.2 .* --with drupal/core-dev:11.4.2 --with-all-dependencies --no-install --no-scripts" "$CALLS_FILE" &&
   ! grep -q "sudo-asked\|drush state:set" "$CALLS_FILE"; then
    pass "--dry-run: checks, Composer trial on a copy (real composer.json untouched, copy removed), plan"
else
    fail "dry run: $output / $(cat "$CALLS_FILE")"
fi

# Test 3: What blocks before Composer runs.

make_project beta 10.2.5

if output="$(run_upgrade_project beta < /dev/null)"; then
    fail "Drupal 10.2 accepted"
elif [[ "$output" == *"[FAILED]  Upgrades to Drupal 11 start from Drupal 10.3; this site has 10.2.5."* &&
        "$output" == *"./install.sh --update beta"* && "$output" == *"Nothing was changed."* ]] &&
     ! grep -q "composer.*require\|composer.*update" "$CALLS_FILE"; then
    pass "Drupal 10.2: update to a newer minor first; nothing changed"
else
    fail "old minor: $output"
fi

make_project gamma 10.6.19 8.2

if output="$(run_upgrade_project gamma < /dev/null)"; then
    fail "PHP 8.2 accepted for Drupal 11"
elif [[ "$output" == *"[FAILED]  Drupal 11.4 needs PHP 8.3 8.4 8.5; the project runs PHP 8.2."* &&
        "$output" == *"Change PHP first, as its own step"* &&
        "$output" == *"./install.sh --php gamma 8.4   (8.3 8.4: Drupal 10.6 and 11.4 both run on it)"* ]] &&
     ! grep -q "composer.*update" "$CALLS_FILE"; then
    pass "PHP the new major does not support: --php first, with a version both releases run on"
else
    fail "php: $output"
fi

make_project delta

if output="$(ENABLED_EXTRA=book run_upgrade_project delta < /dev/null)"; then
    fail "Enabled Book module accepted"
elif [[ "$output" == *"[FAILED]  Enabled here, but no longer part of Drupal 11 core:"* &&
        "$output" == *"- book: composer require drupal/book"* &&
        "$output" == *"./drush pm:uninstall book"* ]]; then
    pass "Module removed from core (Book) without its drupal.org project: blocked, both ways out shown"
else
    fail "removed module: $output"
fi

# Single quotes: PHP code, not shell code.
# shellcheck disable=SC2016
"$REAL_PHP" -r '$f=$argv[1]; $c=json_decode(file_get_contents($f),true); $c["require"]["drupal/book"]="^2.0"; file_put_contents($f, json_encode($c));' "$PROJECT_PATH/composer.json"

if output="$(printf '3\n' | ENABLED_EXTRA=book REMOVE_DRY_RUN=1 run_upgrade_project delta)" &&
   [[ "$output" == *"[OK]      No enabled module or theme that Drupal 11 removed from core"* ]]; then
    pass "Book required from drupal.org: accepted"
else
    fail "book contrib: $output"
fi

if output="$(DB_VERSION=10.5.9 run_upgrade_project alpha < /dev/null)"; then
    fail "Old MariaDB accepted"
elif [[ "$output" == *"[FAILED]  Drupal 11 needs mariadb 10.6 or newer; this system has 10.5.9."* ]]; then
    pass "Database too old for the new major: blocked"
else
    fail "database: $output"
fi

# Test 4: Upgrade Status, for this scan only: added, scanned, removed;
# composer.json, composer.lock and the code as before.

make_project epsilon

if output="$(printf '1\n' | US_REPORT=custom REMOVE_DRY_RUN=1 run_upgrade_project epsilon)" &&
   [[ "$output" == *"Upgrade Status (drupal.org/project/upgrade_status) scans the enabled modules"* &&
      "$output" == *"1) For this scan only: add it, scan, then remove it again"* &&
      "$output" == *"[WARNING] Upgrade Status, custom code: 1 error(s), 0 warning(s) for Drupal 11:"* &&
      "$output" == *"custom: shop: 1 error(s), 0 warning(s)"* &&
      "$output" == *"[INFO]    Upgrade Status, contrib: 1 finding(s) in 1 project(s)."* &&
      "$output" == *"              pathauto: 1"* &&
      "$output" == *"web/modules/custom/shop/shop.module:12 ERROR: Call to deprecated function drupal_set_message()."* &&
      "$output" == *"[OK] Upgrade Status removed again; the project is as before the scan"* &&
      "$output" == *"Upgrade Status: custom code: 1 error(s), 0 warning(s); contrib: 1 project(s) with findings"* &&
      "$output" == *"[DRY RUN] Nothing was changed."* ]] &&
   composer_unchanged epsilon && grep -qx "core=10.6.19" "$PROJECT_PATH/composer.lock" &&
   [[ ! -e "$PROJECT_PATH/vendor/upgrade_status" && ! -e "$PROJECT_PATH/.us-enabled" ]] &&
   grep -q "composer require --dev drupal/upgrade_status:^4.3" "$CALLS_FILE" &&
   [[ "$(calls_line 'drush pm:install upgrade_status')" -lt "$(calls_line 'drush upgrade_status:analyze --all --ignore-uninstalled --format=checkstyle')" &&
      "$(calls_line 'drush upgrade_status:analyze')" -lt "$(calls_line 'drush pm:uninstall upgrade_status')" &&
      "$(calls_line 'drush pm:uninstall upgrade_status')" -lt "$(calls_line 'composer install')" ]]; then
    pass "Upgrade Status for this scan only: explained, findings per project, removed again (files as before)"
else
    fail "upgrade status temporary: $output / $(cat "$CALLS_FILE")"
fi

: > "$CALLS_FILE"

if output="$(printf '2\n' | REMOVE_DRY_RUN=1 run_upgrade_project epsilon)" &&
   [[ "$output" == *"[OK]      Upgrade Status: nothing found in the enabled modules and themes"* &&
      "$output" == *"[NOTE] Upgrade Status stays installed (your choice)"* &&
      "$output" == *"[DRY RUN] Nothing else was changed (Upgrade Status stays installed, as you chose)."* ]] &&
   grep -q '"drupal/upgrade_status": "^4.3"' "$PROJECT_PATH/composer.json" && [[ -e "$PROJECT_PATH/.us-enabled" ]] &&
   ! grep -q "pm:uninstall" "$CALLS_FILE"; then
    pass "Upgrade Status kept: stays in composer.json and enabled, as chosen"
else
    fail "upgrade status keep: $output"
fi

: > "$CALLS_FILE"

if output="$(REMOVE_DRY_RUN=1 run_upgrade_project epsilon < /dev/null)" &&
   [[ "$output" == *"Upgrade Status is installed and enabled: scanning with it."* &&
      "$output" != *"Select [1-3]"* ]] && grep -q "drush upgrade_status:analyze" "$CALLS_FILE"; then
    pass "Upgrade Status already enabled: used without asking"
else
    fail "upgrade status enabled: $output"
fi

make_project zeta

if output="$(printf '1\n' | US_UNINSTALL_FAILS=1 REMOVE_DRY_RUN=1 run_upgrade_project zeta)"; then
    fail "Failed removal of Upgrade Status ignored"
elif [[ "$output" == *"[ERROR] Upgrade Status could not be removed again. Remove it by hand:"* &&
        "$output" == *"./drush pm:uninstall upgrade_status"* &&
        "$output" == *"The upgrade stops here"* ]]; then
    pass "Upgrade Status that cannot be removed again: exact commands shown, the upgrade stops"
else
    fail "upgrade status removal failure: $output"
fi

make_project eta

if output="$(printf '1\n' | US_ADD_FAILS=1 REMOVE_DRY_RUN=1 run_upgrade_project eta)" &&
   [[ "$output" == *"[SKIPPED] Upgrade Status could not be added (see above)."* &&
      "$output" == *"[DRY RUN] Nothing was changed."* ]] && composer_unchanged eta; then
    pass "Upgrade Status cannot be added (network): skipped, the other checks go on"
else
    fail "upgrade status add failure: $output"
fi

mkdir -p "$PROJECT_PATH/web/modules/custom/shop"
printf 'name: Shop\ntype: module\ncore_version_requirement: ^10\n' > "$PROJECT_PATH/web/modules/custom/shop/shop.info.yml"

if output="$(printf '1\n' | US_REPORT=infoyml REMOVE_DRY_RUN=1 run_upgrade_project eta)" &&
   [[ "$output" == *"custom: shop: 1 error(s), 0 warning(s)"* &&
      "$output" == *".info.yml files that allow only the current major: allow Drupal 11 too"* &&
      "$output" == *"sed -i 's/^core_version_requirement:.*/core_version_requirement: ^10 || ^11/' web/modules/custom/shop/shop.info.yml"* ]]; then
    pass "core_version_requirement ^10 in custom code: the exact one-line fix is shown"
else
    fail "info.yml fix: $output"
fi

make_project tau

if output="$(printf '1\ntau\n' | US_REPORT=twig run_upgrade_project tau)" &&
   [[ "$output" == *"[WARNING] Upgrade Status, custom code: 0 error(s), 1 warning(s) for Drupal 11:"* &&
      "$output" == *"Twig deprecations (warnings): they still work with Twig 3"* &&
      "$output" == *"[DONE] tau: Drupal 10.6.19 -> 11.4.2"* &&
      "$output" == *"[OK] No new errors in the Drupal log (older ones are not counted)"* ]]; then
    pass "Twig deprecations in custom code: warnings, no question; upgraded"
else
    fail "twig warnings: $output"
fi

# Findings only in contrib and in tests/ of custom code: counted, not
# errors; no question; the upgrade goes on.

make_project upsilon

if output="$(printf '1\nupsilon\n' | US_REPORT=noise run_upgrade_project upsilon)" &&
   [[ "$output" == *"[OK]      Upgrade Status, custom code: nothing to fix for Drupal 11"* &&
      "$output" == *"[INFO]    Upgrade Status: 1 finding(s) in tests/ folders of custom code."* &&
      "$output" == *"[INFO]    Upgrade Status, contrib: 5 finding(s) in 1 project(s)."* &&
      "$output" == *"              search_api: 5"* &&
      "$output" == *"Upgrade Status: custom code: 0 error(s), 0 warning(s); contrib: 1 project(s) with findings; tests/: 1 finding(s)"* &&
      "$output" != *"Upgrade anyway?"* && "$output" != *"WARNING] Upgrade Status"* &&
      "$output" == *"[DONE] upsilon: Drupal 10.6.19 -> 11.4.2"* ]]; then
    pass "Contrib findings and tests/ of custom code: counted as information, no question"
else
    fail "upgrade status noise: $output"
fi

# Test 5: drupal.org projects without a Drupal 11 release: the developer
# decides (stop, or the lenient plugin).

make_project theta

if output="$(printf '3\n' | BLOCK_CONTRIB=1 REMOVE_DRY_RUN=1 run_upgrade_project theta)"; then
    fail "Blocking contrib accepted in the dry run"
elif [[ "$output" == *"[BLOCKED] Composer cannot install Drupal 11.4.2: these drupal.org projects"* &&
        "$output" == *"- drupal/pathauto   (https://www.drupal.org/project/pathauto)"* &&
        "$output" == *"1) Stop here; nothing is changed."* &&
        "$output" == *"2) Install them anyway with the \"lenient\" Composer plugin"* &&
        "$output" == *"(Dry run: a real run asks here.)"* ]] &&
     composer_unchanged theta && no_copies_left theta; then
    pass "Blocking drupal.org project: named with its page; both choices explained (dry run asks nothing)"
else
    fail "contrib dry run: $output"
fi

if output="$(printf '3\n1\n' | BLOCK_CONTRIB=1 run_upgrade_project theta)"; then
    fail "Stop choice went on"
elif [[ "$output" == *"Upgrade stopped; nothing was changed."* ]] && composer_unchanged theta &&
     ! grep -q "sudo-asked" "$CALLS_FILE"; then
    pass "Choice 1 (stop): nothing changed, no sudo"
else
    fail "contrib stop: $output"
fi

: > "$CALLS_FILE"

if output="$(printf '3\n2\ntheta\n' | BLOCK_CONTRIB=1 run_upgrade_project theta)" &&
   [[ "$output" == *"Lenient:       drupal/pathauto (their drupal/core requirement is ignored;"* &&
      "$output" == *"[DONE] theta: Drupal 10.6.19 -> 11.4.2"* &&
      "$output" == *"drupal/pathauto run without a release for Drupal 11 (lenient)"* ]] &&
   [[ "$(version_of theta)" == "11.4.2" ]] &&
   grep -q "composer config --no-plugins allow-plugins.mglaman/composer-drupal-lenient true" "$CALLS_FILE" &&
   grep -q '\["drupal/pathauto"\]' "$PROJECT_PATH/lenient-list" &&
   [[ "$(read_project_field "$(record_of theta)" lenient_packages)" == "drupal/pathauto" ]] &&
   [[ "$(calls_line 'dump ')" -lt "$(calls_line 'composer require mglaman/composer-drupal-lenient')" ]]; then
    pass "Choice 2 (lenient): plugin and list added after the backup; upgraded; noted in the registry"
else
    fail "contrib lenient: $output / $(cat "$CALLS_FILE")"
fi

make_project iota

if output="$(printf '3\n' | BLOCK_OTHER=1 run_upgrade_project iota)"; then
    fail "Other Composer problem accepted"
elif [[ "$output" == *"[BLOCKED] Composer cannot install Drupal 11.4.2 with the current composer.json:"* &&
        "$output" == *"symfony/console ~6.4"* && "$output" == *"Nothing was changed."* ]] && composer_unchanged iota; then
    pass "Other Composer problem: Composer's reason shown, nothing changed"
else
    fail "other blocker: $output"
fi

# Test 6: The upgrade.

make_project kappa

if output="$(printf '3\nkappa\n' | run_upgrade_project kappa)" &&
   [[ "$output" == *"[DONE] kappa: Drupal 10.6.19 -> 11.4.2"* &&
      "$output" == *"  ./install.sh --restore kappa $work_dir/backups/kappa-upgrade-"* &&
      "$output" == *"Check it yourself (the installer only opened the front page):"* &&
      "$output" == *"./drush config:export"* ]] &&
   [[ "$(version_of kappa)" == "11.4.2" ]] &&
   [[ "$(read_project_field "$(record_of kappa)" drupal_version)" == "11.4.2" ]] &&
   [[ "$(read_project_field "$(record_of kappa)" upgraded_from)" == *" 10.6.19" ]] &&
   grep -q '"drupal/core-recommended": "^11.4"' "$PROJECT_PATH/composer.json" &&
   grep -q '"drush/drush": "^13"' "$PROJECT_PATH/composer.json" &&
   grep -q '"drupal/core-dev": "^11.4"' "$PROJECT_PATH/composer.json" &&
   [[ ! -e "$PROJECT_PATH/.drupal-local-installer/update-snapshot" ]] && no_copies_left kappa; then
    pass "Upgrade: Drupal 11.4.2 running, new requirements in composer.json, registry notes the old version"
else
    fail "upgrade: $output / $(cat "$CALLS_FILE")"
fi

backup="$(find "$work_dir/backups" -maxdepth 1 -name 'kappa-upgrade-*' -type d | head -n 1)"
last_update="$(grep -n 'composer update' "$CALLS_FILE" | tail -n 1 | cut -d: -f1)"

if [[ -n "$backup" && "$(stat -c '%a' "$backup")" == "700" ]] &&
   grep -q '"drupal/core-recommended": "^10.6"' "$backup/composer.json" &&
   [[ "$(calls_line sudo-asked)" -lt "$(calls_line 'dump ')" &&
      "$(calls_line 'dump ')" -lt "$(calls_line 'drush state:set system.maintenance_mode 1')" &&
      "$(calls_line 'drush state:set system.maintenance_mode 1')" -lt "$(calls_line 'composer require --no-update drupal/core-recommended:^11.4')" &&
      "$(calls_line 'composer require --no-update drupal/core-recommended:^11.4')" -lt "$last_update" &&
      "$last_update" -lt "$(calls_line 'drush updatedb --yes')" &&
      "$(calls_line 'drush updatedb --yes')" -lt "$(calls_line 'drush state:set system.maintenance_mode 0')" ]] &&
   ! sed -n "${last_update},\$p" "$CALLS_FILE" | grep -q "^sudo "; then
    pass "Order: sudo, backup (kappa-upgrade-*), maintenance, composer.json, composer update, updatedb; no sudo after Composer"
else
    fail "order: $(cat "$CALLS_FILE")"
fi

make_project rho
git -C "$PROJECT_PATH" init -q
git -C "$PROJECT_PATH" add -A
git -C "$PROJECT_PATH" -c user.email=t@t -c user.name=t commit -q -m init
mkdir -p "$PROJECT_PATH/recipes/core_recipe"
touch "$PROJECT_PATH/recipes/core_recipe/recipe.yml"

if output="$(printf '3\nrho\n' | WATCHDOG_NEW=1 run_upgrade_project rho)" &&
   [[ "$output" == *"[DONE WITH PROBLEMS] rho: Drupal 10.6.19 -> 11.4.2"* &&
      "$output" == *"  - new errors in the Drupal log"* &&
      "$output" == *"Changed in git ("* &&
      "$output" == *" M composer.json"* && "$output" == *" M web/core/lib/Drupal.php"* &&
      "$output" == *"recipes/ is written by Composer (like vendor/)"* &&
      "$output" == *"git add -A && git commit -m \"Drupal core 11.4.2 (upgrade from 10.6.19)\""* &&
      "$output" == *"[WARNING] Drupal logged new errors during the upgrade:"* &&
      "$output" == *"php: Error: Call to undefined function old_api() in shop_page()"* &&
      "$output" != *"old SMTP error"* ]]; then
    pass "Project in git: every changed file and the commit shown; recipes/ explained; only new log errors"
else
    fail "git hint: $output"
fi

# Test 7: Failures restore code, composer.json and database.

make_project lambda

if output="$(printf '3\nlambda\n' | UPDB_FAILS=1 run_upgrade_project lambda)"; then
    fail "Failed updatedb reported as success"
elif [[ "$output" == *"Restoring the project as it was before the upgrade..."* &&
        "$output" == *"[OK] Database restored"* &&
        "$output" == *"[OK] The project is back to its previous version."* ]] &&
     [[ "$(version_of lambda)" == "10.6.19" ]] && composer_unchanged lambda &&
     grep -qx "core=10.6.19" "$PROJECT_PATH/composer.lock" &&
     grep -q "mysql restore: CREATE TABLE node;" "$CALLS_FILE" &&
     [[ "$(read_project_field "$(record_of lambda)" drupal_version)" == "10.6.19" ]]; then
    pass "updatedb failure: code, composer.json and database restored; registry unchanged"
else
    fail "updb failure: $output / $(cat "$CALLS_FILE")"
fi

: > "$CALLS_FILE"

if output="$(printf '3\nlambda\n' | UPGRADE_FAILS=1 run_upgrade_project lambda)"; then
    fail "Failed composer update reported as success"
elif [[ "$(version_of lambda)" == "10.6.19" && "$output" == *"[OK] The project is back to its previous version."* ]] &&
     composer_unchanged lambda && ! grep -q "mysql restore" "$CALLS_FILE"; then
    pass "Composer failure: code and composer.json restored, database untouched"
else
    fail "composer failure: $output"
fi

if output="$(printf '3\nlambda\n' | BOOTSTRAP_FAILS_AFTER=1 run_upgrade_project lambda)"; then
    fail "Broken upgraded site reported as success"
elif [[ "$(version_of lambda)" == "10.6.19" && "$output" == *"Drush cannot bootstrap the updated site"* ]] &&
     composer_unchanged lambda; then
    pass "Upgraded site that does not bootstrap: restored"
else
    fail "verify failure: $output"
fi

exit_code=0
output="$(printf '3\nlambda\n' | UPGRADE_INTERRUPT=1 run_upgrade_project lambda)" || exit_code=$?

if [[ "$exit_code" -eq 130 && "$output" == *"[INTERRUPTED] Stopping the upgrade and restoring the project..."* &&
      "$output" == *"[OK] The project is back to its previous version."* ]] &&
   [[ "$(version_of lambda)" == "10.6.19" ]] && composer_unchanged lambda; then
    pass "Ctrl+C during the upgrade: restored, exit code 130"
else
    fail "interrupt: $exit_code / $output"
fi

# Test 8: Confirmations.

make_project mu

if output="$(printf '1\nn\n' | US_REPORT=custom run_upgrade_project mu)"; then
    fail "Custom code errors ignored without asking"
elif [[ "$output" == *"Upgrade cancelled; nothing was changed."* ]] &&
     composer_unchanged mu && ! grep -q "sudo-asked" "$CALLS_FILE"; then
    pass "Errors in custom code: the developer decides; 'n' changes nothing"
else
    fail "custom confirm: $output"
fi

if output="$(printf '3\nmuu\n' | run_upgrade_project mu)"; then
    fail "Wrong name accepted"
elif [[ "$output" == *"Name does not match. Upgrade cancelled; nothing was changed."* ]] &&
     ! grep -q "sudo-asked" "$CALLS_FILE" && composer_unchanged mu; then
    pass "Wrong confirmation cancels before sudo"
else
    fail "wrong name: $output"
fi

if output="$(printf '1\ny\nmu\n' | US_REPORT=custom run_upgrade_project mu)" &&
   [[ "$output" == *"[DONE] mu: Drupal 10.6.19 -> 11.4.2"* && "$(version_of mu)" == "11.4.2" ]]; then
    pass "Errors in custom code: 'y' goes on (the developer's decision)"
else
    fail "custom confirm yes: $output"
fi

# An enabled module that Drupal 11 considers incompatible: named, and
# the upgrade ends with DONE WITH PROBLEMS.

make_project psi

if output="$(printf '3\npsi\n' | INCOMPATIBLE=1 run_upgrade_project psi)" &&
   [[ "$output" == *"[WARNING] Enabled, but not compatible with Drupal 11.4.2 (their pages will"* &&
      "$output" == *"            - module road_map (modules/custom/road_map)"* &&
      "$output" == *"Upgrade Status listed what to change in custom code"* &&
      "$output" == *"[DONE WITH PROBLEMS] psi: Drupal 10.6.19 -> 11.4.2"* &&
      "$output" == *"  - module road_map is not compatible with Drupal 11.4.2"* &&
      "$output" == *"The upgrade is installed, but check these before you work on the site."* ]] &&
   [[ "$(version_of psi)" == "11.4.2" ]]; then
    pass "Incompatible module after the upgrade: named; DONE WITH PROBLEMS"
else
    fail "incompatible module: $output"
fi

# Test 9: A Composer plugin that composer.json does not mention yet: the
# developer decides before anything changes.

make_project xi

if output="$(printf '3\n' | NEW_PLUGIN=1 REMOVE_DRY_RUN=1 run_upgrade_project xi)" &&
   [[ "$output" == *"[PLUGINS] Drupal 11 brings Composer plugins that composer.json does not"* &&
      "$output" == *"- symfony/runtime: Enables decoupling PHP applications from global state"* &&
      "$output" != *"- drupal/core-composer-scaffold:"* &&
      "$output" == *"1) Allow them (allow-plugins: true)"* &&
      "$output" == *"Plugins:       symfony/runtime (you decide in the real run)"* &&
      "$output" == *"[DRY RUN] Nothing was changed."* ]] && composer_unchanged xi && no_copies_left xi; then
    pass "New Composer plugin: found in the trial (drupal/* already allowed is not asked), explained"
else
    fail "plugin dry run: $output"
fi

if output="$(printf '3\n3\n' | NEW_PLUGIN=1 run_upgrade_project xi)"; then
    fail "Plugin stop choice went on"
elif [[ "$output" == *"Upgrade stopped; nothing was changed."* ]] && composer_unchanged xi &&
     ! grep -q "sudo-asked" "$CALLS_FILE"; then
    pass "New plugin, choice 3 (stop): nothing changed"
else
    fail "plugin stop: $output"
fi

if output="$(printf '3\n1\nxi\n' | NEW_PLUGIN=1 run_upgrade_project xi)" &&
   [[ "$output" == *"Plugins:       symfony/runtime (allowed in composer.json)"* &&
      "$output" == *"[DONE] xi: Drupal 10.6.19 -> 11.4.2"* ]] &&
   [[ "$(cat "$PROJECT_PATH/runtime-decision")" == "true" ]] &&
   grep -q "composer config --no-plugins allow-plugins.symfony/runtime true" "$CALLS_FILE"; then
    pass "New plugin, choice 1: allowed in composer.json, then upgraded"
else
    fail "plugin allow: $output / $(cat "$CALLS_FILE")"
fi

make_project omicron

if output="$(printf '3\n2\nomicron\n' | NEW_PLUGIN=1 run_upgrade_project omicron)" &&
   [[ "$output" == *"(installed, plugin part switched off)"* && "$output" == *"[DONE] omicron"* ]] &&
   [[ "$(cat "$PROJECT_PATH/runtime-decision")" == "false" ]]; then
    pass "New plugin, choice 2: installed with the plugin part switched off"
else
    fail "plugin off: $output"
fi

make_project pi
LOG_FILE="$work_dir/pi.log"
: > "$LOG_FILE"

if output="$(printf '3\npi\n' | NEW_PLUGIN=1 NEW_PLUGIN_HIDDEN=1 run_upgrade_project pi)"; then
    fail "Blocked plugin reported as success"
elif [[ "$output" == *"[INFO] Composer stopped at the plugin symfony/runtime: composer.json neither allows"* &&
        "$output" == *"[OK] The project is back to its previous version."* ]] && composer_unchanged pi; then
    pass "Plugin seen only during the install: explained in plain words, project restored"
else
    fail "plugin hidden: $output"
fi

LOG_FILE=""

# Test 10: Nothing to upgrade to yet.

make_project nu 11.4.2

if output="$(run_upgrade_project nu < /dev/null)" &&
   [[ "$output" == *"There is no stable Drupal 12 release that config/compatibility.conf"* ]] &&
   ! grep -q "composer.*require\|composer.*update" "$CALLS_FILE"; then
    pass "Drupal 11 with only a Drupal 12 beta out: nothing to do"
else
    fail "no target: $output"
fi

echo "[SUCCESS] Upgrade tests passed."
