#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

source lib/output.sh
source lib/registry.sh
source lib/php_fpm.sh
source lib/nginx.sh
source lib/project.sh

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

# All project paths in these tests live in a temporary base directory.
export DRUPAL_PROJECTS_DIR="$work_dir/www"
mkdir "$DRUPAL_PROJECTS_DIR"

current_user="$(id -un)"
mock_log="$work_dir/calls.log"

# Test 1: Existing directory must be rejected.

existing_dir="$(mktemp -d)"

if output="$(check_project_directory "$existing_dir")"; then
    echo "[FAIL] Existing directory was accepted."
    rmdir "$existing_dir"
    exit 1
else
    rmdir "$existing_dir"
    if [[ "$output" == *"[ERROR] Project path already exists:"* ]]; then
        echo "[PASS] Existing directory rejected"
    else
        echo "[FAIL] Unexpected error message"
        exit 1
    fi
fi

# Test 2: Available project path must be accepted.

if output="$(check_project_directory "$DRUPAL_PROJECTS_DIR/new_site")" &&
   [[ "$output" == *"[OK] Project path is available:"* ]]; then
    echo "[PASS] Available project path accepted"
else
    echo "[FAIL] Available project path was rejected"
    exit 1
fi

# Test 3: Broken symbolic link must be rejected.

ln -s /tmp/nonexistent-drupal-target "$DRUPAL_PROJECTS_DIR/broken_link"

if check_project_directory "$DRUPAL_PROJECTS_DIR/broken_link" > /dev/null; then
    echo "[FAIL] Broken symbolic link was accepted"
    exit 1
else
    echo "[PASS] Broken symbolic link rejected"
fi

# Test 4: Only paths produced by get_project_path are managed.

if is_managed_project_path "$DRUPAL_PROJECTS_DIR/my_site" &&
   ! is_managed_project_path "/etc/my_site" &&
   ! is_managed_project_path "$DRUPAL_PROJECTS_DIR" &&
   ! is_managed_project_path "$DRUPAL_PROJECTS_DIR/../etc" &&
   ! is_managed_project_path "$DRUPAL_PROJECTS_DIR/my-site" &&
   ! is_managed_project_path "$DRUPAL_PROJECTS_DIR/a/b"; then
    echo "[PASS] Only managed project paths accepted"
else
    echo "[FAIL] Managed path check incorrect"
    exit 1
fi

# Mock sudo: log the call and run it without privileges.
# "install -o/-g" would need root, so only the directory is created.
sudo() {
    echo "sudo $*" >> "$mock_log"

    if [[ "$1" == "install" ]]; then
        mkdir -m 2750 "${!#}"
    elif [[ "$1" == "rm" ]]; then
        rm -rf -- "${!#}"
    elif [[ "$1" == "-u" ]]; then
        shift 3
        "$@"
    fi
}

# Test 5: Project directory owned by the developer, group www-data.

: > "$mock_log"
site="$DRUPAL_PROJECTS_DIR/site_one"

if create_project_directory "$site" "devuser" > /dev/null &&
   [[ "$(cat "$mock_log")" == "sudo install -d -o devuser -g www-data -m 2750 $site" ]] &&
   [[ -d "$site" ]]; then
    echo "[PASS] Project directory created with owner, group and mode"
else
    echo "[FAIL] Project directory creation incorrect: $(cat "$mock_log")"
    exit 1
fi

# Test 6: Unmanaged paths and bad owners never reach sudo.

: > "$mock_log"

if create_project_directory "/etc/site_two" "devuser" > /dev/null ||
   create_project_directory "$DRUPAL_PROJECTS_DIR/site_two" "bad user" > /dev/null ||
   remove_project_directory "/etc" > /dev/null ||
   remove_project_directory "$DRUPAL_PROJECTS_DIR" > /dev/null; then
    echo "[FAIL] Unsafe directory operation accepted"
    exit 1
elif [[ ! -s "$mock_log" ]]; then
    echo "[PASS] Unsafe directory operations rejected before sudo"
else
    echo "[FAIL] sudo ran for unsafe input: $(cat "$mock_log")"
    exit 1
fi

# Stub php8.5 and composer: record how Composer is started.
stub_bin="$work_dir/bin"
mkdir "$stub_bin"
PATH="$stub_bin:$PATH"

# Unquoted heredoc: $mock_log is filled in now, \$ parts stay for the stub.
cat > "$stub_bin/php8.5" <<STUB
#!/usr/bin/env bash
echo "php8.5 \$*" >> "$mock_log"
case "\$*" in
    *" require "*)
        # Like Composer: add a vendor/bin/drush proxy that calls plain "php".
        dir="\$(printf '%s\n' "\$@" | sed -n 's/^--working-dir=//p')"
        mkdir -p "\$dir/vendor/bin"
        printf '#!/usr/bin/env bash\nexec php drush-entry "\$@"\n' > "\$dir/vendor/bin/drush"
        chmod +x "\$dir/vendor/bin/drush"
        exit "\${MOCK_REQUIRE_EXIT:-0}"
        ;;
    *"--version"*) echo "Drush Commandline Tool 13.6.0" ;;
esac
exit "\${MOCK_COMPOSER_EXIT:-0}"
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$stub_bin/composer"
chmod +x "$stub_bin/php8.5" "$stub_bin/composer"

# Test 7: Composer runs with the project PHP, as the current developer.

: > "$mock_log"

if create_drupal_project "11.4.8" "$site" "8.5" "$current_user" > /dev/null &&
   [[ "$(cat "$mock_log")" == "php8.5 $stub_bin/composer create-project --no-interaction drupal/recommended-project:11.4.8 $site" ]]; then
    echo "[PASS] Composer runs with the selected PHP version"
else
    echo "[FAIL] Unexpected Composer call: $(cat "$mock_log")"
    exit 1
fi

# Test 8: For another user (installer started with sudo), sudo -u is used.

: > "$mock_log"
create_drupal_project "11.4.8" "$site" "8.5" "otheruser" > /dev/null

if [[ "$(head -n 1 "$mock_log")" == "sudo -u otheruser -- php8.5 "* ]]; then
    echo "[PASS] Composer runs as the project owner"
else
    echo "[FAIL] Composer not run as project owner: $(cat "$mock_log")"
    exit 1
fi

# Test 9: Invalid versions are rejected before Composer runs.

: > "$mock_log"

if create_drupal_project "11.x" "$site" "8.5" "$current_user" > /dev/null ||
   create_drupal_project "11.4.8" "$site" "8; ls" "$current_user" > /dev/null; then
    echo "[FAIL] Invalid version accepted"
    exit 1
elif [[ ! -s "$mock_log" ]]; then
    echo "[PASS] Invalid Drupal or PHP version rejected"
else
    echo "[FAIL] Composer ran for invalid version"
    exit 1
fi

# Test 10: Successful provisioning: directory, then Composer.

: > "$mock_log"
site="$DRUPAL_PROJECTS_DIR/site_three"

if output="$(provision_drupal_project "11.4.8" "$site" "8.5" "$current_user")" &&
   [[ "$(sed -n 1p "$mock_log")" == "sudo install -d"* ]] &&
   [[ "$(sed -n 2p "$mock_log")" == "php8.5 "* ]] &&
   [[ "$output" == *"[SUCCESS] Drupal project files created."* ]]; then
    echo "[PASS] Drupal provisioning creates directory then runs Composer"
else
    echo "[FAIL] Drupal provisioning order incorrect"
    exit 1
fi

# Test 11: Composer failure removes the new directory.

: > "$mock_log"
site="$DRUPAL_PROJECTS_DIR/site_four"

if output="$(MOCK_COMPOSER_EXIT=1 provision_drupal_project "11.4.8" "$site" "8.5" "$current_user")"; then
    echo "[FAIL] Composer failure ignored"
    exit 1
elif [[ "$output" == *"[OK] Rollback completed."* ]] &&
     [[ ! -e "$site" ]] &&
     [[ "$(tail -n 1 "$mock_log")" == "sudo rm -rf -- $site" ]]; then
    echo "[PASS] Composer failure rolls back the project directory"
else
    echo "[FAIL] Rollback after Composer failure incorrect"
    exit 1
fi

# Test 12: Existing directory stops provisioning before Composer.

: > "$mock_log"
mkdir "$DRUPAL_PROJECTS_DIR/site_five"

if provision_drupal_project "11.4.8" "$DRUPAL_PROJECTS_DIR/site_five" "8.5" "$current_user" > /dev/null; then
    echo "[FAIL] Existing project directory accepted"
    exit 1
elif [[ ! -s "$mock_log" ]] && [[ -d "$DRUPAL_PROJECTS_DIR/site_five" ]]; then
    echo "[PASS] Existing directory untouched and Composer not run"
else
    echo "[FAIL] Existing directory handling incorrect"
    exit 1
fi

# Test 13: Drush is added with Composer and the project PHP.

: > "$mock_log"
site="$DRUPAL_PROJECTS_DIR/site_six"
mkdir "$site"

if install_drush "$site" "8.5" "$current_user" > /dev/null &&
   [[ "$(cat "$mock_log")" == "php8.5 $stub_bin/composer require --no-interaction --working-dir=$site drush/drush" ]]; then
    echo "[PASS] Drush installed with the project PHP"
else
    echo "[FAIL] Unexpected Drush install call: $(cat "$mock_log")"
    exit 1
fi

# Test 14: Launchers, the per-project php link, and permissions.

# The launcher lines are searched as fixed text, so single quotes are intended.
# shellcheck disable=SC2016
if create_project_launchers "$site" "8.5" "$current_user" > /dev/null &&
   [[ "$(readlink "$site/.drupal-local-installer/bin/php")" == "$stub_bin/php8.5" ]] &&
   grep -qxF 'export PATH="$project_dir/.drupal-local-installer/bin:$PATH"' "$site/drush" &&
   grep -qxF 'exec "$project_dir/vendor/bin/drush" "$@"' "$site/drush" &&
   grep -qxF 'export DRUSH_OPTIONS_URI="${DRUSH_OPTIONS_URI:-http://site_six.localhost}"' "$site/drush" &&
   ! grep -qF 'DRUSH_OPTIONS_URI' "$site/composer" &&
   grep -qxF "exec $stub_bin/php8.5 $stub_bin/composer \"\$@\"" "$site/composer" &&
   [[ "$(stat -c '%a' "$site/drush")" == "750" ]] &&
   [[ "$(stat -c '%a' "$site/composer")" == "750" ]]; then
    echo "[PASS] ./drush and ./composer launchers created with the project php link"
else
    echo "[FAIL] Launchers incorrect"
    cat "$site/drush" "$site/composer" 2>/dev/null
    exit 1
fi

# Test 15: Plain "php" inside Drush resolves to the project PHP,
# also when ./drush is called through a symbolic link from elsewhere.

: > "$mock_log"
ln -s "$site/drush" "$work_dir/drush-link"
(cd / && "$work_dir/drush-link" cr > /dev/null)

if [[ "$(cat "$mock_log")" == "php8.5 drush-entry cr" ]]; then
    echo "[PASS] ./drush runs Drush with the project PHP"
else
    echo "[FAIL] Unexpected launcher call: $(cat "$mock_log")"
    exit 1
fi

# Test 15b: A missing project PHP gives a clear message, not a crash.

mv "$stub_bin/php8.5" "$stub_bin/php8.5.off"

if output="$("$site/drush" status 2>&1)"; then
    echo "[FAIL] Launcher ran without its PHP"
    exit 1
elif [[ "$output" == "This project needs $stub_bin/php8.5, which is not installed on this system." ]]; then
    echo "[PASS] Launcher explains a missing project PHP"
else
    echo "[FAIL] Unexpected launcher message: $output"
    exit 1
fi

mv "$stub_bin/php8.5.off" "$stub_bin/php8.5"

# Test 15c: verify_drush fails when the output is not Drush.

printf '#!/usr/bin/env bash\necho "#!/usr/bin/env bash proxy text"\n' > "$work_dir/fake_drush"
chmod +x "$work_dir/fake_drush"
mkdir -p "$work_dir/fake_project"
cp "$work_dir/fake_drush" "$work_dir/fake_project/drush"

if output="$(verify_drush "$work_dir/fake_project" "$current_user")"; then
    echo "[FAIL] verify_drush accepted output that is not Drush"
    exit 1
elif [[ "$output" == *"[ERROR] Drush does not run correctly."* ]]; then
    echo "[PASS] verify_drush checks the Drush output, not only the exit code"
else
    echo "[FAIL] Unexpected verify_drush result: $output"
    exit 1
fi

# Test 16: Existing launcher files are never replaced.

echo "custom" > "$site/drush.keep"
cp "$site/drush.keep" "$site/drush" 2>/dev/null || true

if write_project_launcher "$site/drush" "$stub_bin/php8.5" "x" "$current_user" > /dev/null; then
    echo "[FAIL] Existing launcher was replaced"
    exit 1
elif [[ "$(cat "$site/drush")" == "custom" ]]; then
    echo "[PASS] Existing launcher left untouched"
else
    echo "[FAIL] Existing launcher was modified"
    exit 1
fi

# Test 17: Full provisioning adds Drush and checks it runs.

: > "$mock_log"
site="$DRUPAL_PROJECTS_DIR/site_seven"

if output="$(provision_drupal_project "11.4.8" "$site" "8.5" "$current_user")" &&
   grep -q " require --no-interaction --working-dir=$site drush/drush" "$mock_log" &&
   [[ "$output" == *"[OK] Drush Commandline Tool 13.6.0"* ]] &&
   [[ -x "$site/drush" && -x "$site/composer" ]]; then
    echo "[PASS] Provisioning installs Drush, launchers and verifies Drush"
else
    echo "[FAIL] Provisioning with Drush incorrect"
    exit 1
fi

# Test 18: Drush failure rolls back the whole project directory.

site="$DRUPAL_PROJECTS_DIR/site_eight"

if output="$(MOCK_REQUIRE_EXIT=1 provision_drupal_project "11.4.8" "$site" "8.5" "$current_user")"; then
    echo "[FAIL] Drush failure ignored"
    exit 1
elif [[ "$output" == *"[OK] Rollback completed."* ]] && [[ ! -e "$site" ]]; then
    echo "[PASS] Drush failure rolls back the project directory"
else
    echo "[FAIL] Rollback after Drush failure incorrect"
    exit 1
fi

echo "[SUCCESS] Project directory tests passed."
