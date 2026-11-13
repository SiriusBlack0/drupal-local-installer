#!/usr/bin/env bash

# A new project with DDEV: the choice native/DDEV, PHP and database in
# DDEV, the installation (ddev config, start, composer, site:install,
# password through stdin), the rollback, the registry (runtime=ddev,
# --list) and the commands that do not support DDEV projects yet. ddev,
# curl and sudo are stubs; no container runs.

set -euo pipefail

cd "$(dirname "$0")/.."

source lib/output.sh
source lib/compatibility.sh
source lib/system.sh
source lib/nginx.sh
source lib/php_fpm.sh
source lib/database.sh
source lib/registry.sh
source lib/project.sh
source lib/site.sh
source lib/composer.sh
source lib/git.sh
source lib/remove.sh
source lib/ui.sh
source lib/update.sh
source lib/php_source.sh
source lib/packages.sh
source lib/ddev.sh

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; exit 1; }

export XDG_DATA_HOME="$work_dir/data"
export XDG_STATE_HOME="$work_dir/state"
export DRUPAL_PROJECTS_DIR="$work_dir/www"
export DDEV_HOME="$work_dir/home"
export CALLS_FILE="$work_dir/calls"
export GIT_CONFIG_GLOBAL="$work_dir/gitconfig"
stub_bin="$work_dir/bin"
mkdir -p "$stub_bin" "$DRUPAL_PROJECTS_DIR" "$DDEV_HOME/.ddev"
printf 'router_http_port: "8081"\nrouter_https_port: "8444"\n' > "$DDEV_HOME/.ddev/global_config.yaml"
printf '[user]\n    name = Test\n    email = test@example.invalid\n' > "$GIT_CONFIG_GLOBAL"
PROJECT_USER="$(id -un)"
REMOVE_DRY_RUN=0
LOG_FILE="$work_dir/install.log"
: > "$LOG_FILE"
: > "$CALLS_FILE"

# ddev: records every call (never stdin); create-project lays out a
# Drupal project; php:eval answers password-ok for a password on stdin.
# DDEV_FAIL=<word>: that step fails.
cat > "$stub_bin/ddev" <<'STUB'
#!/usr/bin/env bash
echo "ddev $* (in $PWD) noninteractive=${DDEV_NONINTERACTIVE:-} stdin=$([[ -t 0 ]] && echo tty || echo other)" >> "$CALLS_FILE"
[[ -n "${DDEV_FAIL:-}" && " $* " == *" $DDEV_FAIL "* ]] && { echo "Error: $DDEV_FAIL failed"; exit 1; }
case "$1" in
    config) mkdir -p .ddev && echo "name: x" > .ddev/config.yaml ;;
    start) mkdir -p web/sites/default && echo "<?php // settings.ddev.php" > web/sites/default/settings.ddev.php ;;
    delete) rm -rf .ddev ;;
    utility) echo "Pulling ddev/ddev-webserver:v1.25.5 ... done" ;;
    composer)
        case "$2" in
            create-project)
                mkdir -p web/core/lib/Drupal web/sites/default vendor
                echo '{"name": "drupal/recommended-project"}' > composer.json
                echo '{"packages": []}' > composer.lock
                echo "<?php" > web/index.php
                echo "<?php // settings" > web/sites/default/settings.php
                ;;
        esac
        ;;
    drush)
        shift
        case "$1" in
            site:install) echo " [success] Installation complete.  User name: admin  User password: tEmPoRaRy" ;;
            # The password file in the mounted folder, mode 600.
            php:eval)
                f=".drupal-local-installer/admin-password"
                if [[ -s "$f" && "$(stat -c '%a' "$f")" == "600" ]]; then
                    cp "$f" "$CALLS_FILE.password"; echo "password-ok"
                else
                    echo "password-empty"
                fi
                ;;
            status) echo "Successful" ;;
        esac
        ;;
    describe) echo '{"raw":{"primary_url":"https://shop.ddev.site:8444"}}' ;;
esac
STUB

cat > "$stub_bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$CALLS_FILE"
[[ "${SITE_DOWN:-0}" == "1" ]] && { echo "HTTP/1.1 502 Bad Gateway"; exit 0; }
printf 'HTTP/1.1 200 OK\r\nX-Generator: Drupal 11 (https://www.drupal.org)\r\n\r\n'
STUB

cat > "$stub_bin/sudo" <<'STUB'
#!/usr/bin/env bash
echo "sudo $*" >> "$CALLS_FILE"
[[ "$1" == "-u" ]] && shift 2
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

chmod +x "$stub_bin"/*
PATH="$stub_bin:$PATH"

record_of() { printf '%s/drupal-local-installer/projects/%s.conf\n' "$XDG_DATA_HOME" "$1"; }

set_project() {
    PROJECT_NAME="$1"
    PROJECT_MACHINE_NAME="$1"
    PROJECT_PATH="$DRUPAL_PROJECTS_DIR/$1"
    DRUPAL_VERSION="11.4.2"
    PHP_VERSION="8.4"
    DATABASE_ENGINE="mariadb"
    DATABASE_VERSION="11.8"
    DDEV_DATABASE="mariadb:11.8"
    DATABASE_PASSWORD=""
    ADMIN_USER="admin"
    ADMIN_MAIL="admin@example.com"
    ADMIN_PASSWORD="S3cret-Passw0rd-xyz"
    ADMIN_PASSWORD_GENERATED=1
    GIT_SETUP="yes"
    rm -rf "$PROJECT_PATH" "$(record_of "$1")"
    : > "$CALLS_FILE"
    : > "$LOG_FILE"
}

# Test 1: The choice native/DDEV: only when the computer is ready.

is_ddev_ready() { return 1; }
check_ddev_readiness() { :; }

if output="$(prompt_project_runtime < /dev/null)" && [[ "$output" != *"How should the project run?"* ]] &&
   prompt_project_runtime < /dev/null > /dev/null && [[ "$PROJECT_RUNTIME" == "native" ]]; then
    pass "Not ready for DDEV: no question, native"
else
    fail "runtime not ready: $output"
fi

is_ddev_ready() { return 0; }

if output="$(prompt_project_runtime <<< "")" && [[ "$output" == *"2) DDEV:   containers with their own PHP and database"* &&
      "$output" == *"(https://<name>.ddev.site:8444)"* ]] &&
   prompt_project_runtime <<< "2" > /dev/null && [[ "$PROJECT_RUNTIME" == "ddev" ]] &&
   prompt_project_runtime <<< "" > /dev/null && [[ "$PROJECT_RUNTIME" == "native" ]]; then
    pass "Ready: native (Enter) or DDEV (2), with DDEV's URL"
else
    fail "runtime: $output"
fi

# Test 2: PHP and database for DDEV: from the compatibility table, nothing
# installed on the system.

DRUPAL_VERSION="11.4.2"
supported="$(get_supported_php_versions 11.4 | paste -sd ' ' -)"

if output="$(prompt_ddev_php_version <<< "")" && prompt_ddev_php_version <<< "" > /dev/null &&
   [[ "$PHP_VERSION" == "${supported##* }" && "$output" == *"PHP versions for Drupal 11.4 (in the DDEV container):"* ]] &&
   prompt_ddev_php_version <<< "1" > /dev/null && [[ "$PHP_VERSION" == "${supported%% *}" ]]; then
    pass "PHP for DDEV: the versions of the compatibility table (Enter = newest)"
else
    fail "ddev php: $output / $PHP_VERSION"
fi

if output="$(prompt_ddev_database <<< "")" && prompt_ddev_database <<< "" > /dev/null &&
   [[ "$DATABASE_ENGINE" == "mariadb" && "$DATABASE_VERSION" == "11.8" && "$DDEV_DATABASE" == "mariadb:11.8" &&
      "$output" == *"1) mariadb 11.8  (DDEV's default)"* && "$output" == *"postgresql 16"* ]] &&
   prompt_ddev_database <<< "5" > /dev/null && [[ "$DDEV_DATABASE" == "postgres:17" && "$DATABASE_ENGINE" == "postgresql" ]]; then
    pass "Database for DDEV: versions the Drupal major supports, DDEV's names (postgres:17)"
else
    fail "ddev database: $output"
fi

# Test 3: The installation: folder (the only sudo step), ddev config and
# start, Composer in the container, launchers, site:install, password
# through stdin, check, registry, git.

set_project shop
project="$PROJECT_PATH"

if output="$(run_ddev_installation_workflow)" &&
   [[ "$output" == *"[OK] ./drush, ./composer and ./start (DDEV)"* &&
      "$output" == *"[OK] Administrator password set"* &&
      "$output" == *"[OK] Drupal site installed and answering: https://shop.ddev.site:8444"* &&
      "$output" == *"[OK] Initial commit"* ]] &&
   grep -q "ddev config --project-name=shop --project-type=drupal11 --docroot=web --php-version=8.4 --database=mariadb:11.8 (in $project)" "$CALLS_FILE" &&
   grep -q "ddev composer create-project --no-interaction drupal/recommended-project:11.4.2 (in $project)" "$CALLS_FILE" &&
   grep -q "ddev composer require --no-interaction drush/drush" "$CALLS_FILE" &&
   grep -q "ddev drush site:install standard --yes --site-name=shop" "$CALLS_FILE" &&
   grep -q -- "--resolve shop.ddev.site:8081:127.0.0.1 http://shop.ddev.site:8081/" "$CALLS_FILE" &&
   [[ "$output" == *"DDEV's container images (the first time about 1 GB"* &&
      "$output" == *"  Pulling ddev/ddev-webserver:v1.25.5 ... done"* && "$output" == *"[OK] Container images ready"* ]] &&
   grep -q "Pulling ddev/ddev-webserver" "$LOG_FILE" &&
   [[ "$(grep -n -m1 "ddev utility download-images" "$CALLS_FILE" | cut -d: -f1)" -lt "$(grep -n -m1 "^ddev start" "$CALLS_FILE" | cut -d: -f1)" ]] &&
   ! grep "^ddev " "$CALLS_FILE" | grep -v "noninteractive=true" | grep -qv "^ddev drush\|^ddev composer [^c]\|^ddev cr" &&
   ! grep -qF "S3cret-Passw0rd-xyz" "$CALLS_FILE" && ! grep -qF "S3cret-Passw0rd-xyz" "$LOG_FILE" &&
   [[ "$(cat "$CALLS_FILE.password")" == "S3cret-Passw0rd-xyz" && ! -e "$project/.drupal-local-installer/admin-password" ]] &&
   ! grep -q "tEmPoRaRy" "$LOG_FILE" &&
   [[ "$(grep -c '^sudo ' "$CALLS_FILE")" -eq 1 ]] && grep -q "^sudo install -d" "$CALLS_FILE" &&
   ! grep -q "nginx\|php-fpm\|apt-get\|systemctl" "$CALLS_FILE"; then
    pass "DDEV project: config, start, Composer and Drush in the container; password through a 600 file, removed after (not in argv or log); one sudo (the folder)"
else
    fail "workflow: $output / $(cat "$CALLS_FILE")"
fi

record="$(record_of shop)"

if [[ "$(read_project_field "$record" runtime)" == "ddev" &&
      "$(read_project_field "$record" url)" == "https://shop.ddev.site:8444" &&
      "$(read_project_field "$record" php_version)" == "8.4" &&
      "$(read_project_field "$record" database_engine)" == "mariadb" &&
      -z "$(read_project_field "$record" nginx_enabled)" && -z "$(read_project_field "$record" php_fpm_pool)" ]] &&
   [[ "$(head -n 4 "$project/drush" | tail -n 1)" == 'exec ddev drush "$@"' && -x "$project/composer" && -x "$project/start" ]] &&
   grep -qxF "/web/sites/*/settings.ddev.php" "$project/.gitignore" &&
   git -C "$project" ls-files | grep -qx ".ddev/config.yaml" &&
   ! git -C "$project" ls-files | grep -q "settings.ddev.php\|^drush$\|^start$"; then
    pass "Registry runtime=ddev with DDEV's URL, no Nginx or pool; launchers; .ddev/ in git, settings.ddev.php not"
else
    fail "record/git: $(cat "$record") / $(git -C "$project" ls-files)"
fi

# The launchers call DDEV from any folder.

: > "$CALLS_FILE"
(cd / && "$project/drush" cr > /dev/null)

if grep -q "ddev drush cr (in $project)" "$CALLS_FILE"; then
    pass "./drush runs ddev drush in the project folder, from any folder"
else
    fail "launcher: $(cat "$CALLS_FILE")"
fi

# Test 4: --list shows the runtime; old records (no runtime) are native.

printf 'format=1\nmachine_name=old\nproject_path=%s/old\nurl=http://old.localhost\nphp_version=8.3\ndatabase_engine=mariadb\n' "$DRUPAL_PROJECTS_DIR" > "$(record_of old)"
mkdir -p "$DRUPAL_PROJECTS_DIR/old"

if output="$(list_registered_projects)" &&
   [[ "$output" == *"RUNTIME"* ]] &&
   grep -qE '^shop +https://shop\.ddev\.site:8444 +8\.4 .* mariadb +ddev +installer +ok' <<< "$output" &&
   grep -qE '^old +http://old\.localhost +8\.3 .* mariadb +native ' <<< "$output"; then
    pass "--list: RUNTIME column (ddev / native; records without it are native)"
else
    fail "list: $output"
fi

# Test 5: Commands that change Nginx, pools or the system database refuse
# DDEV projects (for now); --check-updates skips them.

if output="$(run_update_project shop < /dev/null)"; then
    fail "--update accepted a DDEV project"
elif [[ "$output" == *"[NOT YET] shop runs with DDEV; this command supports native projects only"* ]]; then
    pass "--update (and --remove, --php, --restore, --launchers) refuse DDEV projects for now"
else
    fail "not yet: $output"
fi

# Test 6: A failure removes what this run made: the DDEV project, then
# the folder.

set_project failing

if output="$(DDEV_FAIL=site:install run_ddev_installation_workflow)"; then
    fail "Failed site:install accepted"
elif [[ "$output" == *"[ERROR] Drupal site installation failed."* &&
        "$output" == *"[OK] DDEV project removed (containers and database)"* &&
        "$output" == *"[OK] Removed $DRUPAL_PROJECTS_DIR/failing"* ]] &&
     grep -q "ddev delete --omit-snapshot --yes (in $DRUPAL_PROJECTS_DIR/failing)" "$CALLS_FILE" &&
     [[ ! -e "$DRUPAL_PROJECTS_DIR/failing" && ! -e "$(record_of failing)" ]]; then
    pass "Failure: ddev delete (no snapshot), folder removed, nothing registered"
else
    fail "rollback: $output / $(cat "$CALLS_FILE")"
fi

set_project failing2

if output="$(SITE_DOWN=1 run_ddev_installation_workflow)"; then
    fail "Site that does not answer accepted"
elif [[ "$output" == *"[ERROR] http://failing2.ddev.site:8081 does not answer as an installed Drupal site."* &&
        ! -e "$DRUPAL_PROJECTS_DIR/failing2" ]]; then
    pass "Site that does not answer through the router: rolled back"
else
    fail "site down: $output"
fi

# DDEV's project name is a host name: "_" becomes "-".

if [[ "$(get_ddev_project_name my_shop_2)" == "my-shop-2" &&
      "$(get_ddev_project_url my_shop_2)" == "https://my-shop-2.ddev.site:8444" ]]; then
    pass "Machine name my_shop_2 -> DDEV name my-shop-2"
else
    fail "name: $(get_ddev_project_name my_shop_2)"
fi

echo "[SUCCESS] DDEV project tests passed."
