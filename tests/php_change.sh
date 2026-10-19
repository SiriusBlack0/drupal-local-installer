#!/usr/bin/env bash

# ./install.sh --php NAME VERSION. Everything happens in a temporary
# directory: sudo, apt-get, dpkg-query, nginx, php-fpm, systemctl,
# composer, curl and the PHP binaries are stubs that record their calls.

set -euo pipefail

cd "$(dirname "$0")/.."

source lib/output.sh
source lib/system.sh
source lib/database.sh
source lib/php.sh
source lib/php_fpm.sh
source lib/nginx.sh
source lib/registry.sh
source lib/packages.sh
source lib/preflight.sh
source lib/project.sh
source lib/compatibility.sh
source lib/scan.sh
source lib/remove.sh
source lib/composer.sh
source lib/update.sh
source lib/php_source.sh
source lib/php_change.sh

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

export XDG_DATA_HOME="$work_dir/data"
export XDG_STATE_HOME="$work_dir/state"
export DRUPAL_PROJECTS_DIR="$work_dir/www"
export NGINX_SITES_AVAILABLE_DIR="$work_dir/nginx/sites-available"
export NGINX_SITES_ENABLED_DIR="$work_dir/nginx/sites-enabled"
export PHP_ETC_DIR="$work_dir/php"
export APT_ETC_DIR="$work_dir/apt"
export NGINX_IPV6=0
export STATE_DIR="$work_dir/state"
stub_bin="$work_dir/bin"
export CALLS_FILE="$work_dir/calls"
export REAL_PHP
REAL_PHP="$(command -v php)"
mkdir -p "$DRUPAL_PROJECTS_DIR" "$NGINX_SITES_AVAILABLE_DIR" "$NGINX_SITES_ENABLED_DIR" \
    "$PHP_ETC_DIR/8.2/fpm/pool.d" "$PHP_ETC_DIR/8.3/fpm/pool.d" "$PHP_ETC_DIR/8.4/fpm/pool.d" "$PHP_ETC_DIR/8.5/fpm/pool.d" "$APT_ETC_DIR/sources.list.d" \
    "$STATE_DIR" "$stub_bin"

pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; exit 1; }

# /etc paths, the backup folder and the system state point into the
# temporary directory.
get_nginx_config_path() { printf '%s/%s.conf\n' "$NGINX_SITES_AVAILABLE_DIR" "$1"; }
get_nginx_enabled_path() { printf '%s/%s.conf\n' "$NGINX_SITES_ENABLED_DIR" "$1"; }
get_php_fpm_pool_config_path() { printf '%s/%s/fpm/pool.d/%s.conf\n' "$PHP_ETC_DIR" "$2" "$1"; }
get_backup_base_dir() { printf '%s/backups\n' "$work_dir"; }
has_systemd() { return 0; }
require_sudo() { echo "sudo-asked" >> "$CALLS_FILE"; }
wait_for_socket() { [[ "${SOCKET_FAILS:-0}" != "1" ]]; }
is_php_fpm_installed() { [[ -e "$STATE_DIR/php$1" ]]; }
is_php_cli_installed() { [[ -e "$STATE_DIR/php$1" ]]; }
check_php_extensions() { return 0; }
is_apt_package_available() { [[ " ${APT_AVAILABLE:-} " == *" $1 "* ]]; }
get_php_version_status() {
    if [[ -e "$STATE_DIR/php$1" ]]; then echo installed
    elif [[ " ${APT_AVAILABLE:-} " == *" php$1-fpm "* ]]; then echo available
    else echo not_available; fi
}

# PHP binaries: PHP code runs with the real php; anything else
# (composer) is started directly.
for version in 8.2 8.3 8.4 8.5; do
    cat > "$stub_bin/php$version" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == -* ]] && exec "$REAL_PHP" "$@"
exec "$@"
STUB
    cat > "$stub_bin/php-fpm$version" <<'STUB'
#!/usr/bin/env bash
echo "$(basename "$0") $*" >> "$CALLS_FILE"
STUB
done

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

cat > "$stub_bin/nginx" <<'STUB'
#!/usr/bin/env bash
echo "nginx $*" >> "$CALLS_FILE"
[[ "${NGINX_T_FAILS:-0}" == "1" ]] && exit 1
exit 0
STUB

# SYSTEMCTL_INTERRUPT=<file>: Ctrl+C arrives once, while Nginx reloads.
cat > "$stub_bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >> "$CALLS_FILE"
if [[ -n "${SYSTEMCTL_INTERRUPT:-}" && "$*" == "reload-or-restart nginx" && ! -e "$SYSTEMCTL_INTERRUPT" ]]; then
    touch "$SYSTEMCTL_INTERRUPT"
    kill -INT "$PPID"
fi
exit 0
STUB

cat > "$stub_bin/curl" <<'STUB'
#!/usr/bin/env bash
[[ "${CURL_FAILS:-0}" == "1" ]] && exit 7
printf 'HTTP/1.1 200 OK\r\nX-Generator: Drupal 11 (https://www.drupal.org)\r\n'
STUB

# apt-get: the simulation lists the packages; the installation marks
# PHP 8.4 as installed.
cat > "$stub_bin/apt-get" <<'STUB'
#!/usr/bin/env bash
echo "apt-get $*" >> "$CALLS_FILE"
if [[ "$1" == "--simulate" ]]; then
    shift 2
    for p in "$@"; do [[ "$p" == "--" ]] || echo "Inst $p (1.0 Ubuntu)"; done
    exit 0
fi
touch "$STATE_DIR/php8.4"
STUB

# dpkg-query: the packages of PHP 8.3 (and of 8.4 once installed).
cat > "$stub_bin/dpkg-query" <<'STUB'
#!/usr/bin/env bash
pattern="${*: -1}"
case "$pattern" in
    'php8.3-*')
        for p in php8.3-cli php8.3-fpm php8.3-common php8.3-gd php8.3-xml php8.3-mysql php8.3-redis php8.3-dev; do
            echo "$p ii "
        done
        ;;
    php8.4-*)
        [[ -e "$STATE_DIR/php8.4" ]] && echo "install ok installed"
        ;;
esac
exit 0
STUB

# Composer: check-platform-reqs passes, or fails with PLATFORM_FAILS=1.
cat > "$stub_bin/composer" <<'STUB'
#!/usr/bin/env bash
args=" $* "
echo "composer${args}" | sed "s| --working-dir=[^ ]*||" >> "$CALLS_FILE"
if [[ "$args" == *" check-platform-reqs "* ]]; then
    if [[ "${PLATFORM_FAILS:-0}" == "1" ]]; then
        echo '[{"name":"php","version":"8.4.1","status":"failed","failed_requirement":{"source":"old/package","type":"requires","target":"php","constraint":"<8.4"},"provider":null}]'
        exit 1
    fi
    echo '[{"name":"php","version":"8.4.1","status":"success","failed_requirement":null,"provider":null}]'
fi
STUB

chmod +x "$stub_bin"/*
PATH="$stub_bin:$PATH"
touch "$STATE_DIR/php8.3"

# vendor/bin/drush: answers "Successful" unless it runs with the PHP in
# DRUSH_FAILS_WITH. The "php" it would start is the first one in PATH.
write_vendor_drush() {
    mkdir -p "$1/vendor/bin"
    cat > "$1/vendor/bin/drush" <<'STUB'
#!/usr/bin/env bash
php_used="$(basename "$(readlink -f "$(command -v php)")")"
echo "drush($php_used) $*" >> "$CALLS_FILE"
[[ -n "${DRUSH_FAILS_WITH:-}" && "$php_used" == "php${DRUSH_FAILS_WITH}" ]] && exit 1
# DRUSH_FAILS_AFTER_SWITCH=<php>: fails only through the ./drush launcher
# (which sets DRUSH_OPTIONS_URI), i.e. after the change, not in the trial.
[[ -n "${DRUSH_FAILS_AFTER_SWITCH:-}" && -n "${DRUSH_OPTIONS_URI:-}" && "$php_used" == "php${DRUSH_FAILS_AFTER_SWITCH}" ]] && exit 1
if [[ "$1" == "watchdog:show" ]]; then
    if [[ "${WATCHDOG_NEW:-0}" == "1" && "$php_used" != "php8.3" ]]; then
        echo '{"6":{"wid":"6","type":"php","message":"Deprecated function: old_call() in custom_module_page()"},"5":{"wid":"5","type":"php","message":"old error"}}'
    else
        echo '{"5":{"wid":"5","type":"php","message":"old error"}}'
    fi
    exit 0
fi
[[ "$1" == "status" ]] && echo "Successful"
[[ "$1" == "--version" ]] && echo "Drush Commandline Tool 13.6.0"
exit 0
STUB
    chmod +x "$1/vendor/bin/drush"
}

make_drupal_codebase() {
    local path="$1"

    mkdir -p "$path/web/core/lib"
    printf "<?php\nclass Drupal {\n  const VERSION = '11.3.10';\n}\n" > "$path/web/core/lib/Drupal.php"
    echo '{"require":{"drupal/core-recommended":"^11.3"}}' > "$path/composer.json"
    echo '{}' > "$path/composer.lock"
    write_vendor_drush "$path"
}

# A project made by the installer, with PHP 8.3.
make_installer_project() {
    local name="$1"
    local old="${2:-8.3}"

    PROJECT_NAME="$name"
    PROJECT_MACHINE_NAME="$name"
    PROJECT_USER="$(id -un)"
    PROJECT_PATH="$DRUPAL_PROJECTS_DIR/$name"
    DRUPAL_VERSION="11.3.10"
    PHP_VERSION="$old"
    DATABASE_ENGINE="mariadb"
    DATABASE_NAME="$name"
    DATABASE_USER="${name}_user"
    LOG_FILE=""
    declare -gA REGISTRY_VALUES=()

    rm -rf "$PROJECT_PATH" "$(record_of "$name")" "$PHP_ETC_DIR"/8.4/fpm/pool.d/"$name".conf
    make_drupal_codebase "$PROJECT_PATH"
    generate_nginx_config "$name" "$PROJECT_PATH" "$old" > "$NGINX_SITES_AVAILABLE_DIR/$name.conf"
    ln -sfn "$NGINX_SITES_AVAILABLE_DIR/$name.conf" "$NGINX_SITES_ENABLED_DIR/$name.conf"
    generate_php_fpm_pool_config "$name" "$old" "$PROJECT_USER" > "$PHP_ETC_DIR/$old/fpm/pool.d/$name.conf"
    create_project_launchers "$PROJECT_PATH" "$old" "$PROJECT_USER" > /dev/null
    create_start_script "$PROJECT_PATH" "$old" mariadb "$name" "$PROJECT_USER" > /dev/null
    write_project_record > /dev/null
    cp "$NGINX_SITES_AVAILABLE_DIR/$name.conf" "$work_dir/$name.nginx.orig"
    : > "$CALLS_FILE"
}

record_of() { printf '%s/drupal-local-installer/projects/%s.conf\n' "$XDG_DATA_HOME" "$1"; }
field() { read_project_field "$(record_of "$1")" "$2"; }
calls_line() { grep -n -m1 -F -- "$1" "$CALLS_FILE" | cut -d: -f1; }
site_of() { printf '%s/%s.conf\n' "$NGINX_SITES_AVAILABLE_DIR" "$1"; }

echo "; default pool" > "$PHP_ETC_DIR/8.3/fpm/pool.d/www.conf"
echo "; default pool" > "$PHP_ETC_DIR/8.4/fpm/pool.d/www.conf"
echo "; default pool" > "$PHP_ETC_DIR/8.5/fpm/pool.d/www.conf"
echo "; default pool" > "$PHP_ETC_DIR/8.2/fpm/pool.d/www.conf"
export APT_AVAILABLE="php8.4-fpm php8.4-cli php8.4-gd php8.4-xml php8.4-mysql php8.4-common"

# Test 1: --dry-run shows the plan and changes nothing.

make_installer_project alpha

if output="$(REMOVE_DRY_RUN=1 run_change_php alpha 8.4 < /dev/null)" &&
   [[ "$output" == *"PHP:          8.3 -> 8.4 (Drupal 11.3.10 supports it)"* &&
      "$output" == *"install php8.4-fpm php8.4-cli"*"php8.4-gd"* &&
      "$output" == *"[WARNING] Not available for PHP 8.4: php8.4-redis"* &&
      "$output" != *"php8.4-dev"* &&
      "$output" == *"Checks:       run right after PHP 8.4 is installed"* &&
      "$output" == *"Check it yourself (the installer only opened the front page):"* &&
      "$output" == *"fastcgi_pass unix:/run/php/php8.3-fpm-alpha.sock -> unix:/run/php/php8.4-fpm-alpha.sock (1 line(s))"* &&
      "$output" == *"Launchers:    ./drush, ./composer and ./start are rewritten for PHP 8.4"* &&
      "$output" == *"[DRY RUN] Nothing was changed."* ]] &&
   cmp -s "$(site_of alpha)" "$work_dir/alpha.nginx.orig" &&
   [[ ! -e "$PHP_ETC_DIR/8.4/fpm/pool.d/alpha.conf" ]] &&
   ! grep -q "sudo-asked\|apt-get install" "$CALLS_FILE"; then
    pass "--dry-run: packages (copied extensions too), pool, Nginx line, launchers; nothing changed"
else
    fail "dry run: $output / $(cat "$CALLS_FILE")"
fi

# Test 2: Refusals before anything changes.

if output="$(run_change_php alpha 8.2 < /dev/null)"; then
    fail "Unsupported PHP accepted"
elif [[ "$output" == *"Drupal 11.3 does not support PHP 8.2"* ]]; then
    pass "PHP version the Drupal release does not support is refused"
else
    fail "unsupported: $output"
fi

if output="$(run_change_php alpha 8.3 < /dev/null)" && [[ "$output" == *"already uses PHP 8.3"* ]]; then
    pass "Same PHP version: nothing to do"
else
    fail "same version: $output"
fi

touch "$STATE_DIR/php8.4"
: > "$CALLS_FILE"

if output="$(PLATFORM_FAILS=1 run_change_php alpha 8.4 < /dev/null)"; then
    fail "Package that refuses PHP 8.4 accepted"
elif [[ "$output" == *"[FAILED]  Composer: the installed packages do not accept PHP 8.4"* &&
        "$output" == *"[BLOCKED] The checks above show that the site would not work with PHP 8.4."* &&
        "$output" == *"php 8.4.1: failed (old/package requires php <8.4)"* ]] &&
     ! grep -q "sudo-asked" "$CALLS_FILE"; then
    pass "Composer check-platform-reqs failure: shown, stopped before sudo"
else
    fail "platform: $output"
fi

if output="$(printf 'alphaa\n' | run_change_php alpha 8.4)"; then
    fail "Wrong name accepted"
elif [[ "$output" == *"Name does not match"* ]] && ! grep -q "sudo-asked" "$CALLS_FILE"; then
    pass "Wrong confirmation cancels before sudo"
else
    fail "wrong name: $output"
fi

# Test 3: Successful change (PHP 8.4 already installed).

: > "$CALLS_FILE"

if output="$(printf 'alpha\n' | run_change_php alpha 8.4)" &&
   [[ "$output" == *"[DONE] alpha: PHP 8.3 -> 8.4"* ]]; then
    pass "Change reported as done"
else
    fail "change: $output / $(cat "$CALLS_FILE")"
fi

pool84="$PHP_ETC_DIR/8.4/fpm/pool.d/alpha.conf"

if [[ -f "$pool84" ]] && grep -qx "listen = /run/php/php8.4-fpm-alpha.sock" "$pool84" &&
   grep -qx "user = $(id -un)" "$pool84" &&
   grep -q "fastcgi_pass unix:/run/php/php8.4-fpm-alpha.sock;" "$(site_of alpha)" &&
   ! grep -q "php8.3" "$(site_of alpha)" &&
   [[ "$(diff "$work_dir/alpha.nginx.orig" "$(site_of alpha)" | grep -c '^[<>]')" -eq 2 ]] &&
   [[ ! -e "$PHP_ETC_DIR/8.3/fpm/pool.d/alpha.conf" ]]; then
    pass "New pool for PHP 8.4, only the fastcgi_pass line changed, old pool removed"
else
    fail "files: $(diff "$work_dir/alpha.nginx.orig" "$(site_of alpha)") / $(ls "$PHP_ETC_DIR"/*/fpm/pool.d)"
fi

if [[ "$(readlink "$DRUPAL_PROJECTS_DIR/alpha/.drupal-local-installer/bin/php")" == "$stub_bin/php8.4" ]] &&
   grep -q "php8.4" "$DRUPAL_PROJECTS_DIR/alpha/drush" &&
   grep -q "$stub_bin/php8.4 " "$DRUPAL_PROJECTS_DIR/alpha/composer" &&
   grep -q "^fpm_service=php8.4-fpm$" "$DRUPAL_PROJECTS_DIR/alpha/start" &&
   grep -q "drush(php8.4) status --field=bootstrap" "$CALLS_FILE"; then
    pass "Launchers and ./start use PHP 8.4; Drush checked with PHP 8.4"
else
    fail "launchers: $(cat "$DRUPAL_PROJECTS_DIR/alpha/drush") / $(cat "$CALLS_FILE")"
fi

if [[ "$(field alpha php_version)" == "8.4" &&
      "$(field alpha php_fpm_pool)" == "$pool84" &&
      "$(field alpha php_fpm_socket)" == "/run/php/php8.4-fpm-alpha.sock" &&
      "$(stat -c '%a' "$(record_of alpha)")" == "600" ]]; then
    pass "Registry: PHP version, pool and socket updated (file stays private)"
else
    fail "registry: $(cat "$(record_of alpha)")"
fi

if [[ "$(calls_line sudo-asked)" -lt "$(calls_line 'php-fpm8.4 -t')" &&
      "$(calls_line 'php-fpm8.4 -t')" -lt "$(calls_line 'reload-or-restart php8.4-fpm')" &&
      "$(calls_line 'reload-or-restart php8.4-fpm')" -lt "$(calls_line 'nginx -t')" &&
      "$(calls_line 'nginx -t')" -lt "$(calls_line 'reload-or-restart nginx')" &&
      "$(calls_line 'reload-or-restart nginx')" -lt "$(calls_line 'php-fpm8.3 -t')" &&
      "$(calls_line 'php-fpm8.3 -t')" -lt "$(calls_line 'reload-or-restart php8.3-fpm')" ]] &&
   ! grep -qE "systemctl (restart|stop)" "$CALLS_FILE"; then
    pass "Order: sudo, new pool tested and reloaded, Nginx tested and reloaded, old pool; never a restart"
else
    fail "order: $(cat "$CALLS_FILE")"
fi

backup="$(find "$work_dir/backups" -maxdepth 1 -name 'alpha-php-*' -type d | head -n 1)"

if [[ -n "$backup" && "$(stat -c '%a' "$backup")" == "700" ]] &&
   cmp -s "$backup/nginx-site.conf" "$work_dir/alpha.nginx.orig" && [[ -f "$backup/drush" ]]; then
    pass "Copies of the old Nginx site and launchers kept, private"
else
    fail "backup: $(ls -la "$backup" 2>&1)"
fi

# Test 4: Failures restore everything.

check_restored() {
    cmp -s "$(site_of "$1")" "$work_dir/$1.nginx.orig" &&
    [[ -f "$PHP_ETC_DIR/8.3/fpm/pool.d/$1.conf" && ! -e "$PHP_ETC_DIR/8.4/fpm/pool.d/$1.conf" ]] &&
    [[ "$(field "$1" php_version)" == "8.3" ]] &&
    [[ "$(readlink "$DRUPAL_PROJECTS_DIR/$1/.drupal-local-installer/bin/php")" == "$stub_bin/php8.3" ]] &&
    grep -q "^fpm_service=php8.3-fpm$" "$DRUPAL_PROJECTS_DIR/$1/start"
}

make_installer_project beta

if output="$(printf 'beta\n' | DRUSH_FAILS_AFTER_SWITCH=8.4 run_change_php beta 8.4)"; then
    fail "Site that fails with PHP 8.4 reported as changed"
elif [[ "$output" == *"Drush cannot bootstrap the site with PHP 8.4"* &&
        "$output" == *"[OK] The project runs with PHP 8.3 again"* ]] && check_restored beta; then
    pass "Drush fails with PHP 8.4: Nginx, pool, launchers and registry restored"
else
    fail "drush failure: $output"
fi

make_installer_project gamma

if output="$(printf 'gamma\n' | CURL_FAILS=1 run_change_php gamma 8.4)"; then
    fail "Site without HTTP answer reported as changed"
elif [[ "$output" == *"does not answer as a Drupal site with PHP 8.4"* ]] && check_restored gamma; then
    pass "No HTTP answer with PHP 8.4: everything restored"
else
    fail "http failure: $output"
fi

make_installer_project delta

if output="$(printf 'delta\n' | NGINX_T_FAILS=1 run_change_php delta 8.4)"; then
    fail "Failed nginx -t accepted"
elif check_restored delta && ! grep -q "reload-or-restart nginx" "$CALLS_FILE"; then
    pass "nginx -t fails: Nginx is not reloaded, everything restored"
else
    fail "nginx failure: $output / $(cat "$CALLS_FILE")"
fi

# Test 5: PHP 8.4 not installed yet: packages first, then Composer, and
# sudo again because Composer clears it.

rm -f "$STATE_DIR/php8.4"
make_installer_project epsilon

if output="$(printf 'epsilon\n' | run_change_php epsilon 8.4)" &&
   [[ "$output" == *"[DONE] epsilon: PHP 8.3 -> 8.4"* &&
      "$output" == *"Composer cleared sudo's cached password"* ]] &&
   grep -q "apt-get install --no-remove -- php8.4-fpm php8.4-cli" "$CALLS_FILE" &&
   [[ "$(grep -c sudo-asked "$CALLS_FILE")" -eq 2 ]] &&
   [[ "$(calls_line 'apt-get install')" -lt "$(calls_line 'check-platform-reqs')" ]] &&
   [[ "$(calls_line 'check-platform-reqs')" -lt "$(grep -n sudo-asked "$CALLS_FILE" | tail -n 1 | cut -d: -f1)" ]]; then
    pass "Missing PHP: installed first (no removals), Composer check, sudo asked again"
else
    fail "install path: $output / $(cat "$CALLS_FILE")"
fi

# Test 6: PHP not available anywhere: points to --php-source.

rm -f "$STATE_DIR/php8.3"

if output="$(REMOVE_DRY_RUN=1 run_change_php epsilon 8.3 < /dev/null)"; then
    fail "Unavailable PHP accepted"
elif [[ "$output" == *"PHP 8.3 is not installed and not in this system's package sources"* &&
        "$output" == *"./install.sh --php-source"* ]]; then
    pass "Unavailable PHP: points to --php-source"
else
    fail "unavailable: $output"
fi

touch "$STATE_DIR/php8.3"

# Test 6b: Packages needed while the old PPA is still active: refused.

rm -f "$STATE_DIR/php8.4"
echo "deb https://ppa.launchpadcontent.net/ondrej/php/ubuntu noble main" > "$APT_ETC_DIR/sources.list.d/ondrej.list"

make_installer_project zeta

if output="$(REMOVE_DRY_RUN=1 run_change_php zeta 8.4 < /dev/null)"; then
    fail "Packages from the old PPA accepted"
elif [[ "$output" == *"[BLOCKED] The old PPA (ppa:ondrej/php) is still an active package source"* &&
        "$output" == *"./install.sh --php-source"* ]]; then
    pass "Old PPA still active: package installation refused, --php-source suggested"
else
    fail "ppa block: $output"
fi

rm -f "$APT_ETC_DIR/sources.list.d/ondrej.list"

# Test 7: Adopted project: only its fastcgi_pass changes, its old pool
# (user, settings) is copied and kept.

adopted="$DRUPAL_PROJECTS_DIR/crm"
make_drupal_codebase "$adopted"
cat > "$NGINX_SITES_AVAILABLE_DIR/crm" <<EOF
server {
    listen 80;
    server_name crm.local;
    root $adopted/web;
    location ~ \.php\$ {
        include fastcgi_params;
        fastcgi_pass unix:/var/run/php/php-fpm-crm.sock;
    }
    # custom: kept as it is
    client_max_body_size 200m;
}
EOF
ln -sfn "$NGINX_SITES_AVAILABLE_DIR/crm" "$NGINX_SITES_ENABLED_DIR/crm"
cat > "$PHP_ETC_DIR/8.3/fpm/pool.d/crm.conf" <<EOF
[crm]
user = $(id -un)
group = www-data
listen = /var/run/php/php-fpm-crm.sock
php_admin_value[memory_limit] = 512M
env[APP_ENV] = local
EOF
cp "$NGINX_SITES_AVAILABLE_DIR/crm" "$work_dir/crm.nginx.orig"
cp "$PHP_ETC_DIR/8.3/fpm/pool.d/crm.conf" "$work_dir/crm.pool.orig"
detect_project "$adopted" > /dev/null 2>&1 || true
REGISTRY_VALUES[database_engine]="mariadb"
REGISTRY_VALUES[database_name]="crm"
PROJECT_MACHINE_NAME="crm"
write_project_record > /dev/null
declare -gA REGISTRY_VALUES=()
touch "$STATE_DIR/php8.4"
: > "$CALLS_FILE"

if output="$(printf 'crm\n' | run_change_php crm 8.4)" &&
   [[ "$output" == *"[ADOPTED] The installer did not create this project"* &&
      "$output" == *"Old pool:     kept ($PHP_ETC_DIR/8.3/fpm/pool.d/crm.conf)"* &&
      "$output" == *"[DONE] crm: PHP 8.3 -> 8.4"* ]] &&
   [[ "$(diff "$work_dir/crm.nginx.orig" "$NGINX_SITES_AVAILABLE_DIR/crm" | grep -c '^[<>]')" -eq 2 ]] &&
   grep -q "        fastcgi_pass unix:/run/php/php8.4-fpm-crm.sock;" "$NGINX_SITES_AVAILABLE_DIR/crm" &&
   cmp -s "$PHP_ETC_DIR/8.3/fpm/pool.d/crm.conf" "$work_dir/crm.pool.orig" &&
   grep -qx "php_admin_value\[memory_limit\] = 512M" "$PHP_ETC_DIR/8.4/fpm/pool.d/crm.conf" &&
   grep -qx "env\[APP_ENV\] = local" "$PHP_ETC_DIR/8.4/fpm/pool.d/crm.conf" &&
   grep -q "drush(php8.4) status --field=bootstrap" "$CALLS_FILE" &&
   [[ "$(field crm php_version)" == "8.4" && "$(field crm managed_by)" == "adopted" ]]; then
    pass "Adopted: only fastcgi_pass changed, pool settings copied, old pool untouched"
else
    fail "adopted: $output / $(diff "$work_dir/crm.nginx.orig" "$NGINX_SITES_AVAILABLE_DIR/crm")"
fi

if [[ "$(head -n 1 "$PHP_ETC_DIR/8.4/fpm/pool.d/crm.conf")" == "$PHP_CHANGE_POOL_MARKER" ]]; then
    pass "Pool created for an adopted project is marked as the installer's"
else
    fail "marker: $(head -n 2 "$PHP_ETC_DIR/8.4/fpm/pool.d/crm.conf")"
fi

# Test 8: Adopted again (8.4 -> 8.5): the pool the installer created is
# removed, the project's own original pool stays.

touch "$STATE_DIR/php8.5"
: > "$CALLS_FILE"

if output="$(printf 'crm\n' | run_change_php crm 8.5)" &&
   [[ "$output" == *"Old pool:     removed after the site works ($PHP_ETC_DIR/8.4/fpm/pool.d/crm.conf, created by an earlier --php)"* &&
      "$output" == *"[DONE] crm: PHP 8.4 -> 8.5"* ]] &&
   [[ ! -e "$PHP_ETC_DIR/8.4/fpm/pool.d/crm.conf" && -f "$PHP_ETC_DIR/8.5/fpm/pool.d/crm.conf" ]] &&
   cmp -s "$PHP_ETC_DIR/8.3/fpm/pool.d/crm.conf" "$work_dir/crm.pool.orig" &&
   grep -qx "php_admin_value\[memory_limit\] = 512M" "$PHP_ETC_DIR/8.5/fpm/pool.d/crm.conf" &&
   [[ "$(field crm support)" == "supported" ]]; then
    pass "Adopted again: installer's pool removed, original pool kept, settings carried on, support updated"
else
    fail "adopted again: $output"
fi

# Test 9: A site broken BECAUSE of its PHP (Drupal 11.3 on PHP 8.2) may
# be changed; a site broken for another reason may not.

make_installer_project theta 8.2
touch "$STATE_DIR/php8.2"

if output="$(printf 'theta\n' | DRUSH_FAILS_WITH=8.2 run_change_php theta 8.4)" &&
   [[ "$output" == *"[WARNING] The site does not work with PHP 8.2 now: Drupal 11.3 does not support PHP 8.2."* &&
      "$output" == *"[DONE] theta: PHP 8.2 -> 8.4"* ]] &&
   [[ "$(field theta php_version)" == "8.4" && ! -e "$PHP_ETC_DIR/8.2/fpm/pool.d/theta.conf" ]]; then
    pass "Site broken by an unsupported PHP: change allowed with a warning, and it works afterwards"
else
    fail "broken by php: $output"
fi

make_installer_project iota

if output="$(DRUSH_FAILS_WITH=8.3 run_change_php iota 8.4 < /dev/null)"; then
    fail "Site broken for another reason accepted"
elif [[ "$output" == *"[BLOCKED] The site does not work right now"* ]] &&
     cmp -s "$(site_of iota)" "$work_dir/iota.nginx.orig"; then
    pass "Site broken for another reason (supported PHP): refused, nothing changed"
else
    fail "broken other: $output"
fi

# Test 10: Ctrl+C while Nginx reloads: everything restored, exit 130.

make_installer_project kappa
status=0
output="$(printf 'kappa\n' | SYSTEMCTL_INTERRUPT="$work_dir/interrupted" run_change_php kappa 8.4)" || status=$?

if [[ "$status" -eq 130 && "$output" == *"[INTERRUPTED] Stopping the PHP change and restoring the project"* &&
      "$output" == *"[OK] The project runs with PHP 8.3 again"* ]] && check_restored kappa; then
    pass "Ctrl+C during the change: Nginx, pool, launchers restored, exit code 130"
else
    fail "interrupt: $status / $output"
fi

# Test 11: Only one run at a time per project.

make_installer_project lambda
lock_file="$XDG_STATE_HOME/drupal-local-installer/locks/lambda.lock"
mkdir -p "$(dirname "$lock_file")"
flock "$lock_file" sleep 5 &
lock_holder=$!
sleep 0.5

if output="$(run_change_php lambda 8.4 < /dev/null)"; then
    fail "Locked project accepted"
elif [[ "$output" == *"Another run of the installer is working on 'lambda'"* ]]; then
    pass "A project another run is working on is refused"
else
    fail "lock: $output"
fi

kill "$lock_holder" 2>/dev/null || true
wait "$lock_holder" 2>/dev/null || true

# Test 12: Compatibility checks with the new PHP, before anything changes.

touch "$STATE_DIR/php8.4"
make_installer_project nu

if output="$(REMOVE_DRY_RUN=1 run_change_php nu 8.4 < /dev/null)" &&
   [[ "$output" == *"Compatibility checks with PHP 8.4 (they change nothing):"* &&
      "$output" == *"[OK]      Drupal 11.3.10 supports PHP 8.4"* &&
      "$output" == *"[OK]      Composer: the installed packages accept PHP 8.4"* &&
      "$output" == *"[OK]      No custom modules, themes or profiles"* &&
      "$output" == *"[OK]      Trial run: Drush bootstraps the site with PHP 8.4"* &&
      "$output" == *"Checks:       passed (see above)"* ]] &&
   grep -q "drush(php8.4) status --field=bootstrap" "$CALLS_FILE"; then
    pass "Dry run: compatibility checks listed, including a trial run with PHP 8.4"
else
    fail "checks dry run: $output"
fi

mkdir -p "$PROJECT_PATH/web/modules/custom/shop/src"
printf '<?php\nfunction shop_ok() { return 1; }\n' > "$PROJECT_PATH/web/modules/custom/shop/shop.module"
printf '<?php\nfunction broken( {\n' > "$PROJECT_PATH/web/modules/custom/shop/src/Broken.php"
: > "$CALLS_FILE"

if output="$(printf 'nu\n' | run_change_php nu 8.4)"; then
    fail "Syntax error in custom code accepted"
elif [[ "$output" == *"[FAILED]  Syntax errors in the custom code with PHP 8.4:"* &&
        "$output" == *"web/modules/custom/shop/src/Broken.php"* ]] &&
     ! grep -q "sudo-asked" "$CALLS_FILE" && cmp -s "$(site_of nu)" "$work_dir/nu.nginx.orig"; then
    pass "Syntax error in custom code: shown with the file, blocked before sudo"
else
    fail "lint: $output"
fi

rm -f "$PROJECT_PATH/web/modules/custom/shop/src/Broken.php"

if output="$(DRUSH_FAILS_WITH=8.4 run_change_php nu 8.4 < /dev/null)"; then
    fail "Failed trial run accepted"
elif [[ "$output" == *"[FAILED]  Trial run: Drush cannot bootstrap the site with PHP 8.4."* ]] &&
     cmp -s "$(site_of nu)" "$work_dir/nu.nginx.orig"; then
    pass "Trial run with PHP 8.4 fails: blocked, nothing changed"
else
    fail "trial: $output"
fi

# PHPCompatibility: not installed (offer declined), then a fake checker.
if output="$(REMOVE_DRY_RUN=1 PHPCOMPAT_TOOL_DIR="$work_dir/no-tool" run_change_php nu 8.4 < /dev/null)" &&
   [[ "$output" == *"[OK]      Syntax of the custom code with PHP 8.4: 1 file(s)"* &&
      "$output" == *"The PHPCompatibility checker scans the custom code"* && "$output" == *"[SKIPPED] PHPCompatibility scan"* ]]; then
    pass "PHPCompatibility offered when missing; skipped when declined"
else
    fail "phpcompat offer: $output"
fi

tool="$work_dir/tool"
mkdir -p "$tool/vendor/bin"
cat > "$tool/vendor/bin/phpcs" <<'STUB'
#!/usr/bin/env bash
dir="${*: -1}"
echo "{\"totals\":{\"errors\":1,\"warnings\":1},\"files\":{\"$dir/shop/shop.module\":{\"messages\":[{\"line\":2,\"type\":\"ERROR\",\"message\":\"Function each() is removed since PHP 8.0\"},{\"line\":5,\"type\":\"WARNING\",\"message\":\"Passing null to parameter is deprecated since PHP 8.1\"}]}}}"
exit 2
STUB
chmod +x "$tool/vendor/bin/phpcs"

if output="$(REMOVE_DRY_RUN=1 PHPCOMPAT_TOOL_DIR="$tool" run_change_php nu 8.4 < /dev/null)" &&
   [[ "$output" == *"[WARNING] PHPCompatibility: 1 error(s), 1 warning(s) in the custom code:"* &&
      "$output" == *"web/modules/custom/shop/shop.module:2 ERROR: Function each() is removed since PHP 8.0"* &&
      "$output" == *"Checks:       passed; PHPCompatibility found 1 error(s), 1 warning(s) (see above)"* &&
      "$output" == *"[DRY RUN] Nothing was changed."* ]]; then
    pass "PHPCompatibility findings shown in the dry run"
else
    fail "phpcompat dry run: $output"
fi

: > "$CALLS_FILE"

if output="$(printf 'n\n' | PHPCOMPAT_TOOL_DIR="$tool" run_change_php nu 8.4)"; then
    fail "PHPCompatibility errors ignored without asking"
elif [[ "$output" == *"Cancelled; nothing was changed."* ]] &&
     ! grep -q "sudo-asked" "$CALLS_FILE"; then
    pass "PHPCompatibility errors: the user decides; 'n' changes nothing"
else
    fail "phpcompat confirm: $output"
fi

# Test 13: After the change, errors Drupal logged with the new PHP are
# reported, and the manual checks are listed.

if output="$(printf 'y\nnu\n' | PHPCOMPAT_TOOL_DIR="$tool" WATCHDOG_NEW=1 run_change_php nu 8.4)" &&
   [[ "$output" == *"[DONE] nu: PHP 8.3 -> 8.4"* &&
      "$output" == *"[WARNING] Drupal logged new errors with PHP 8.4:"* &&
      "$output" == *"php: Deprecated function: old_call() in custom_module_page()"* &&
      "$output" != *"old error"* &&
      "$output" == *"back to PHP 8.3 if something breaks: ./install.sh --php nu 8.3"* ]]; then
    pass "After the change: new log errors reported (old ones not), manual checks listed"
else
    fail "after checks: $output"
fi

echo "[SUCCESS] PHP change tests passed."
