#!/usr/bin/env bash

# ./install.sh --launchers NAME, and the offer after --scan. Everything
# happens in a temporary directory; php8.3 and composer are stubs.

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
source lib/checklist.sh
source lib/scan.sh
source lib/remove.sh
source lib/git.sh
source lib/launchers.sh

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; exit 1; }

export XDG_DATA_HOME="$work_dir/data"
export XDG_STATE_HOME="$work_dir/state"
export DRUPAL_PROJECTS_DIR="$work_dir/www"
stub_bin="$work_dir/bin"
etc_dir="$work_dir/etc"
mkdir -p "$stub_bin" "$DRUPAL_PROJECTS_DIR" "$etc_dir"
PROJECT_USER="$(id -un)"
REMOVE_DRY_RUN=0
LOG_FILE=""

cat > "$stub_bin/php8.3" <<'STUB'
#!/usr/bin/env bash
echo "php8.3 $*"
STUB
cat > "$stub_bin/composer" <<'STUB'
#!/usr/bin/env bash
echo "composer $*"
STUB
chmod +x "$stub_bin"/*
PATH="$stub_bin:$PATH"

get_nginx_sites_enabled_dir() { printf '%s\n' "$etc_dir"; }
get_nginx_sites_available_dir() { printf '%s\n' "$etc_dir"; }

record_of() { printf '%s/drupal-local-installer/projects/%s.conf\n' "$XDG_DATA_HOME" "$1"; }

# An adopted project: its own Nginx site (with an error log), a pool
# socket or TCP address, Drush in vendor/bin.
make_adopted() {
    local name="$1"
    local url="${2-http://$1.test}"
    local socket="${3-/run/php/php8.3-fpm.sock}"
    local dir="$DRUPAL_PROJECTS_DIR/$name"
    local site="$etc_dir/$name.conf"

    rm -rf "$dir" "$(record_of "$name")"
    mkdir -p "$dir/vendor/bin" "$dir/web"
    echo '{"name": "x/y"}' > "$dir/composer.json"
    # shellcheck disable=SC2016  # the stub's own code.
    printf '#!/usr/bin/env bash\necho "uri=$DRUSH_OPTIONS_URI php=$(command -v php)"\n' > "$dir/vendor/bin/drush"
    chmod +x "$dir/vendor/bin/drush"
    printf 'server {\n    server_name %s.test;\n    error_log /var/log/nginx/%s.error.log;\n}\n' "$name" "$name" > "$site"
    git -C "$dir" init -q
    echo "/vendor/" > "$dir/.gitignore"

    declare -gA REGISTRY_VALUES
    REGISTRY_VALUES=(
        [managed_by]="adopted" [support]="supported" [name]="$name" [machine_name]="$name"
        [owner]="$PROJECT_USER" [project_path]="$dir" [web_root]="$dir/web" [url]="$url"
        [drupal_version]="11.4.11" [install_profile]="" [php_version]="8.3"
        [database_engine]="mariadb" [database_name]="$name" [database_user]="$name"
        [sqlite_path]="" [php_fpm_pool]="" [php_fpm_socket]="$socket"
        [nginx_available]="$site" [nginx_enabled]="$site" [log_file]=""
    )
    PROJECT_MACHINE_NAME="$name"
    write_project_record > /dev/null
    REGISTRY_VALUES=()
    printf '%s\n' "$dir"
}

# Test 1: The plan; --dry-run and "n" write nothing.

project="$(make_adopted shop)"

if output="$(REMOVE_DRY_RUN=1 run_launchers_project shop < /dev/null)" &&
   [[ "$output" == *"Write ./start     starts PHP-FPM 8.3, Nginx and the database; checks the site"* &&
      "$output" == *"Write ./drush     Drush with PHP 8.3 and the project URL"* &&
      "$output" == *"Write ./composer  Composer with PHP 8.3"* &&
      "$output" == *"Nginx, the"*"PHP-FPM pool and the project's settings stay as they are."* &&
      "$output" == *"[DRY RUN] Nothing was changed."* ]] &&
   [[ ! -e "$project/start" && ! -e "$project/drush" && ! -e "$project/composer" ]]; then
    pass "Plan: what is written and that nothing else changes; dry run writes nothing"
else
    fail "plan: $output"
fi

if run_launchers_project shop <<< "n" > /dev/null; then
    fail "'n' wrote launchers"
elif [[ ! -e "$project/start" && ! -e "$project/drush" ]]; then
    pass "'n' (the default) writes nothing"
else
    fail "files after 'n'"
fi

# Test 2: "y" writes them, with the project's own URL, site, socket and
# error log; .git/info/exclude for this computer, .gitignore untouched.

if output="$(run_launchers_project shop <<< "y")" &&
   [[ "$output" == *"[OK] ./start written (PHP 8.3)"* && "$output" == *"[OK] ./drush written"* &&
      "$output" == *"[OK] ./composer written"* && "$output" == *"Added to .git/info/exclude"* ]] &&
   grep -qxF "url=http://shop.test" "$project/start" &&
   grep -qxF "site_config=$etc_dir/shop.conf" "$project/start" &&
   grep -qxF "socket=/run/php/php8.3-fpm.sock" "$project/start" &&
   grep -qxF "error_log=/var/log/nginx/shop.error.log" "$project/start" &&
   grep -qxF "services=(php8.3-fpm nginx mariadb)" "$project/start" &&
   [[ "$("$project/drush")" == "uri=http://shop.test php=$project/.drupal-local-installer/bin/php" ]] &&
   [[ "$(readlink "$project/.drupal-local-installer/bin/php")" == "$stub_bin/php8.3" ]] &&
   grep -qxF "/start" "$project/.git/info/exclude" && grep -qxF "/.drupal-local-installer/" "$project/.git/info/exclude" &&
   [[ "$(cat "$project/.gitignore")" == "/vendor/" ]] &&
   bash -n "$project/start"; then
    pass "Launchers written with the project's URL, site, socket and error log; git exclude only"
else
    fail "write: $output / $(head -n 20 "$project/start" 2>/dev/null)"
fi

echo "# mine" > "$project/start.keep"
cp "$project/start" "$project/start.keep"

if output="$(run_launchers_project shop < /dev/null)" &&
   [[ "$output" == *"./start exists already; kept"* && "$output" == *"[OK] Nothing to write."* ]] &&
   cmp -s "$project/start" "$project/start.keep"; then
    pass "Run again: existing launchers kept, nothing written"
else
    fail "again: $output"
fi

# Test 3: A drush/ folder (custom commands) means no ./drush; a TCP pool
# means no socket check; no Nginx site means no ./start.

project="$(make_adopted crm "http://crm.test" "127.0.0.1:9000")"
mkdir -p "$project/drush/Commands"

if output="$(run_launchers_project crm <<< "y")" &&
   [[ "$output" == *"./drush: the project has a drush/ folder (custom Drush commands), so no ./drush file"* ]] &&
   [[ -d "$project/drush" && -x "$project/composer" ]] &&
   grep -qx "socket=" "$project/start" && ! grep -qxF "/drush" "$project/.git/info/exclude"; then
    pass "drush/ folder kept (no ./drush); TCP pool: no socket check in ./start"
else
    fail "drush folder / tcp: $output"
fi

project="$(make_adopted nosite "")"

if output="$(run_launchers_project nosite <<< "y")" &&
   [[ "$output" == *"./start: no Nginx site was found for this project"* ]] &&
   [[ ! -e "$project/start" && -x "$project/drush" ]] &&
   [[ "$("$project/drush")" == "uri= php=$project/.drupal-local-installer/bin/php" ]]; then
    pass "No Nginx site: no ./start; ./drush without a URL"
else
    fail "no site: $output"
fi

# Test 4: After --scan: the projects just registered, chosen from a list.

project="$(make_adopted blog)"
make_adopted wiki > /dev/null

if output="$(offer_launchers_after_scan blog wiki < <(printf '1\n'))" &&
   [[ "$output" == *"Adopted projects have no ./start, ./drush and ./composer"* &&
      "$output" == *"[OK] ./drush written"* ]] &&
   [[ -x "$project/drush" && ! -e "$DRUPAL_PROJECTS_DIR/wiki/drush" ]]; then
    pass "After --scan: launchers only for the projects chosen from the list"
else
    fail "scan offer: $output"
fi

if output="$(offer_launchers_after_scan wiki < /dev/null)" &&
   [[ "$output" == *"No launchers written."* && ! -e "$DRUPAL_PROJECTS_DIR/wiki/drush" ]]; then
    pass "After --scan: nothing chosen, nothing written"
else
    fail "scan offer none: $output"
fi

# Test 5: Projects of another user and unknown names are refused.

if output="$(run_launchers_project nosuch < /dev/null)"; then
    fail "Unknown project accepted"
elif [[ "$output" == *"'nosuch' is not in the registry."* ]]; then
    pass "Unknown project refused"
else
    fail "unknown: $output"
fi

echo "[SUCCESS] Launcher tests passed."
