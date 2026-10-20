#!/usr/bin/env bash

# Git repository of a new project: the phase 1 question, and git init,
# .gitignore, .git/info/exclude and the initial commit in a temporary
# project. Only the temporary folder is touched; the user's own git
# configuration is replaced by a temporary one.

set -euo pipefail

cd "$(dirname "$0")/.."

pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; exit 1; }

# Test 1: Sourcing has no side effects.

if output="$(bash -c 'source lib/git.sh; source lib/ui/git.sh' < /dev/null 2>&1)" && [[ -z "$output" ]]; then
    pass "Sourcing git.sh and ui/git.sh has no side effects"
else
    fail "sourcing: $output"
fi

source lib/site.sh
source lib/git.sh
source lib/ui/git.sh
source lib/ui/confirm.sh

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

current_user="$(id -un)"
argv_log="$work_dir/argv"
DB_SECRET="Db#Secret.42"
DATABASE_PASSWORD="$DB_SECRET"

# No user or system git configuration: the identity is set per test.
export GIT_CONFIG_GLOBAL="$work_dir/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
: > "$GIT_CONFIG_GLOBAL"

set_identity() {
    git config --global user.name "Test User"
    git config --global user.email "test@example.com"
}

clear_identity() {
    : > "$GIT_CONFIG_GLOBAL"
}

# Every command run as the project user is recorded: the password
# must never be in a command line.
run_as_project_user() {
    shift
    printf '%s\n' "$*" >> "$argv_log"
    "$@"
}

# A project as the installer leaves it, with something in every place
# that must stay out of git.
new_project() {
    local project="$work_dir/$1"
    local path

    rm -rf "$project"

    for path in \
        composer.json composer.lock \
        vendor/autoload.php \
        web/index.php web/.htaccess \
        web/core/lib/Drupal.php \
        web/modules/contrib/webform/webform.info.yml \
        web/themes/contrib/gin/gin.info.yml \
        web/profiles/contrib/p/p.info.yml \
        web/libraries/lib/lib.js \
        web/modules/custom/mymodule/mymodule.info.yml \
        recipes/core/recipe.yml \
        web/sites/default/default.settings.php \
        web/sites/default/files/upload.jpg \
        private/database.sqlite \
        start drush composer \
        .drupal-local-installer/bin/php \
        config/sync/system.site.yml; do
        mkdir -p "$project/$(dirname "$path")"
        echo "content of $path" > "$project/$path"
    done

    # shellcheck disable=SC2016  # PHP code, not shell.
    printf '<?php\n$databases = [];\n$settings['"'"'hash_salt'"'"'] = '"'"''"'"';\n' \
        > "$project/web/sites/default/settings.php"
    printf "<?php\n\$databases['default']['default'] = ['password' => '%s'];\n" "$DB_SECRET" \
        > "$project/web/sites/default/settings.local.php"
    : > "$argv_log"
    printf '%s\n' "$project"
}

tracked() {
    git -C "$1" ls-files | sort | tr '\n' ' '
}

expected_files=".gitignore composer.json composer.lock config/sync/system.site.yml web/.htaccess web/index.php web/modules/custom/mymodule/mymodule.info.yml web/sites/default/default.settings.php web/sites/default/settings.php "

# Test 2: The whole step with a git identity: one commit with the
# project's own files only.

set_identity
project="$(new_project with_identity)"

if output="$(setup_project_git "$project" "$current_user" "Initial commit: test")" &&
   [[ "$(tracked "$project")" == "$expected_files" ]] &&
   [[ "$(git -C "$project" symbolic-ref --short HEAD)" == "main" ]] &&
   [[ "$(git -C "$project" log --format=%s)" == "Initial commit: test" ]] &&
   [[ -z "$(git -C "$project" status --porcelain)" ]] &&
   [[ "$output" == *"[OK] Git repository created (branch main, 9 files staged)"* ]] &&
   [[ "$output" == *"[OK] Initial commit "*"\"Initial commit: test\""* ]]; then
    pass "git init on main, one commit with the project's own files; nothing left over"
else
    fail "with identity: $output / $(tracked "$project")"
fi

if grep -qxF "/web/sites/*/settings.local.php" "$project/.gitignore" &&
   grep -qxF "/vendor/" "$project/.gitignore" &&
   ! grep -qxF "/start" "$project/.gitignore" &&
   grep -qxF "/start" "$project/.git/info/exclude" &&
   grep -qxF "/.drupal-local-installer/" "$project/.git/info/exclude"; then
    pass ".gitignore: downloads, files and secrets; info/exclude: this computer's launchers"
else
    fail "ignore files: $(cat "$project/.gitignore" "$project/.git/info/exclude")"
fi

if grep -qF "$DB_SECRET" "$argv_log"; then
    fail "The database password appeared in a command line"
else
    pass "No password in any command line"
fi

# Test 3: Without a git identity the files are staged, and the commands
# to finish are shown.

clear_identity
project="$(new_project without_identity)"

if output="$(setup_project_git "$project" "$current_user" "Initial commit: test")" &&
   ! git -C "$project" rev-parse -q --verify HEAD > /dev/null &&
   [[ "$(git -C "$project" diff --cached --name-only | sort | tr '\n' ' ')" == "$expected_files" ]] &&
   [[ "$output" == *"git does not know your name and email"* ]] &&
   [[ "$output" == *"git config --global user.email"* ]] &&
   [[ "$output" == *"cd $project && git commit -m \"Initial commit: test\""* ]]; then
    pass "No git identity: files staged, no commit, the commands are shown"
else
    fail "without identity: $output"
fi

set_identity

# Test 4: An existing repository is left alone.

project="$(new_project existing)"
git -C "$project" init -q
before="$(ls -A "$project")"

if output="$(setup_project_git "$project" "$current_user" "Initial commit: test")" &&
   [[ "$output" == *"already a git repository; left as it is"* ]] &&
   [[ "$(ls -A "$project")" == "$before" ]] &&
   ! git -C "$project" rev-parse -q --verify HEAD > /dev/null; then
    pass "Existing repository left as it is"
else
    fail "existing repository: $output"
fi

# Test 5: An existing .gitignore keeps its lines; only missing ones are added.

project="$(new_project own_gitignore)"
printf '%s\n' '# mine' '/vendor/' '*.log' > "$project/.gitignore"

if setup_project_git "$project" "$current_user" "Initial commit: test" > /dev/null &&
   [[ "$(head -3 "$project/.gitignore")" == $'# mine\n/vendor/\n*.log' ]] &&
   [[ "$(grep -cxF '/vendor/' "$project/.gitignore")" -eq 1 ]] &&
   grep -qxF "/web/core/" "$project/.gitignore"; then
    pass "Existing .gitignore kept; only the missing lines are added"
else
    fail "own .gitignore: $(cat "$project/.gitignore")"
fi

write_project_gitignore "$project" "$current_user"
write_project_git_exclude "$project" "$current_user"

if [[ "$(grep -c '^# Downloaded by Composer' "$project/.gitignore")" -eq 1 &&
      "$(grep -c '^# Written by drupal-local-installer' "$project/.git/info/exclude")" -eq 1 &&
      "$(grep -cxF '/start' "$project/.git/info/exclude")" -eq 1 ]]; then
    pass "Writing the ignore files again adds nothing"
else
    fail "ignore files written twice"
fi

# A drush/ folder (custom Drush commands) is not excluded; .drupal-local-installer/ is.

project="$(new_project drush_folder)"
rm -f "$project/drush"
mkdir -p "$project/drush/Commands/custom"
echo "custom" > "$project/drush/Commands/custom/MyCommands.php"

if setup_project_git "$project" "$current_user" "Initial commit: test" > /dev/null &&
   ! grep -qxF "/drush" "$project/.git/info/exclude" &&
   grep -qxF "/.drupal-local-installer/" "$project/.git/info/exclude" &&
   git -C "$project" ls-files --error-unmatch drush/Commands/custom/MyCommands.php > /dev/null 2>&1; then
    pass "A drush/ folder of the project stays in git"
else
    fail "drush folder: $(cat "$project/.git/info/exclude")"
fi

# Test 6: A secret in a staged file: nothing is committed or staged.

project="$(new_project leaked_password)"
echo "password: $DB_SECRET" > "$project/web/modules/custom/mymodule/notes.txt"

if output="$(setup_project_git "$project" "$current_user" "Initial commit: test")"; then
    fail "Password in a staged file accepted"
elif [[ "$output" == *"A staged file contains the database password."* &&
        "$output" == *"Nothing was committed."* &&
        "$output" != *"$DB_SECRET"* ]] &&
     ! git -C "$project" rev-parse -q --verify HEAD > /dev/null &&
     [[ -z "$(git -C "$project" diff --cached --name-only)" ]]; then
    pass "Password in a staged file: unstaged, not committed, not printed"
else
    fail "leaked password: $output"
fi

project="$(new_project database_in_settings)"
echo "\$databases['default']['default'] = [];" >> "$project/web/sites/default/settings.php"

if output="$(setup_project_git "$project" "$current_user" "Initial commit: test")"; then
    fail "Database settings in settings.php accepted"
elif [[ "$output" == *"settings.php contains database settings"* ]] &&
     ! git -C "$project" rev-parse -q --verify HEAD > /dev/null; then
    pass "Database settings in settings.php: not committed"
else
    fail "database in settings.php: $output"
fi

# settings.local.php staged by force (git add -f): refused.
project="$(new_project forced_local)"
git -C "$project" init -q
git -C "$project" add -f web/sites/default/settings.local.php

if check_staged_secrets "$project" "$current_user" > "$work_dir/out" 2>&1; then
    fail "Staged settings.local.php accepted"
elif grep -q "settings.local.php would be committed" "$work_dir/out"; then
    pass "Staged settings.local.php is refused"
else
    fail "staged settings.local.php: $(cat "$work_dir/out")"
fi

# Test 7: Without git only a warning.

project="$(new_project no_git)"
empty_bin="$work_dir/empty_bin"
mkdir -p "$empty_bin"

if output="$(PATH="$empty_bin" setup_project_git "$project" "$current_user" "Initial commit: test")"; then
    fail "Missing git reported as success"
elif [[ "$output" == *"git is not installed: no repository was created."* && ! -e "$project/.git" ]]; then
    pass "Missing git: warning, nothing created"
else
    fail "missing git: $output"
fi

# Test 8: The phase 1 question.

answer() {
    GIT_SETUP="unset"
    prompt_git_setup > "$work_dir/out" < <(printf '%b' "$1")
    printf '%s' "$GIT_SETUP"
}

if [[ "$(answer '\n')" == "yes" && "$(answer 'y\n')" == "yes" &&
      "$(answer 'N\n')" == "no" && "$(answer 'maybe\nn\n')" == "no" ]] &&
   grep -q "Please enter y or n." "$work_dir/out" &&
   grep -q "settings.local.php, which is never committed" "$work_dir/out"; then
    pass "Question: Enter or y = yes, n = no, anything else asked again"
else
    fail "git question: $(cat "$work_dir/out")"
fi

if output="$(bash -c 'source lib/ui/git.sh; prompt_git_setup; echo AFTER' < /dev/null)" &&
   [[ "$output" == *"Input cancelled."* && "$output" != *AFTER* ]]; then
    pass "Question: end of input cancels"
else
    fail "git question EOF: $output"
fi

# Test 9: The summary shows the choice.

PROJECT_NAME="Test" PROJECT_MACHINE_NAME="test" DRUPAL_VERSION="11.4.9"
PHP_VERSION="8.5" PHP_STATUS="installed" DATABASE_ENGINE="sqlite"
DATABASE_VERSION="3" DATABASE_STATUS="installed" SQLITE_DATABASE_PATH="/x"
ADMIN_USER="admin" ADMIN_PASSWORD_GENERATED=1

summary_yes="$(GIT_SETUP=yes confirm_installation <<< 'y')"
summary_no="$(GIT_SETUP=no confirm_installation <<< 'y')"

if [[ "$summary_yes" == *"Git:      git init + initial commit"* &&
      "$summary_no" == *"Git:      no repository"* ]]; then
    pass "Summary shows the git choice"
else
    fail "summary: $summary_yes"
fi

echo "[SUCCESS] Git repository tests passed."
