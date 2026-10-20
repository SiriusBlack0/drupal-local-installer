#!/usr/bin/env bash

# ==================================================
# Git repository for a new project
#
# The project's own files go into git: composer.json, composer.lock,
# settings.php, config/, custom code and the files Drupal's scaffold
# writes (web/index.php, web/.htaccess, ...). Left out:
# - .gitignore: what Composer downloads (vendor/, core, contrib),
#   uploaded files, the private folder (SQLite database) and
#   settings.local.php, the only file with secrets;
# - .git/info/exclude: what this installer writes for this computer
#   (./start, ./drush, ./composer, .drupal-local-installer/). Not in
#   .gitignore, because they are not part of the project for others.
#
# Everything here is optional: a failure is a warning, the site is
# already installed and working.
# ==================================================

GIT_IGNORE_ENTRIES=(
    "/vendor/"
    "/web/core/"
    "/web/modules/contrib/"
    "/web/themes/contrib/"
    "/web/profiles/contrib/"
    "/web/libraries/"
    "/recipes/"
    "/drush/Commands/contrib/"
    "/web/sites/*/files/"
    "/web/sites/*/settings.local.php"
    "/private/"
)

GIT_EXCLUDE_ENTRIES=(
    "/start"
    "/drush"
    "/composer"
    "/.drupal-local-installer/"
)

project_git() {
    local project_path="$1"
    local run_user="$2"
    shift 2

    run_as_project_user "$run_user" git -C "$project_path" "$@"
}

# Adds the lines that are missing to a file (created when missing).
# Lines already there are left alone.
append_missing_lines() {
    local file="$1"
    local run_user="$2"
    local header="$3"
    shift 3
    local line
    local missing=()

    for line in "$@"; do
        if [[ ! -f "$file" ]] || ! grep -qxF -- "$line" "$file"; then
            missing+=("$line")
        fi
    done

    [[ "${#missing[@]}" -gt 0 ]] || return 0

    {
        if [[ -s "$file" ]]; then
            echo
        fi
        echo "$header"
        printf '%s\n' "${missing[@]}"
    } | run_as_project_user "$run_user" tee -a "$file" > /dev/null
}

write_project_gitignore() {
    local project_path="$1"
    local run_user="$2"

    append_missing_lines "$project_path/.gitignore" "$run_user" \
        "# Downloaded by Composer, uploaded files and secrets (drupal-local-installer)." \
        "${GIT_IGNORE_ENTRIES[@]}"
}

# A pattern such as "/drush" also matches a folder: a project's own
# drush/ folder (custom Drush commands) is never excluded.
write_project_git_exclude() {
    local project_path="$1"
    local run_user="$2"
    local entry
    local entries=()

    for entry in "${GIT_EXCLUDE_ENTRIES[@]}"; do
        if [[ "$entry" != */ && -d "$project_path$entry" ]]; then
            continue
        fi
        entries+=("$entry")
    done

    run_as_project_user "$run_user" mkdir -p "$project_path/.git/info" &&
    append_missing_lines "$project_path/.git/info/exclude" "$run_user" \
        "# Written by drupal-local-installer for this computer only." \
        "${entries[@]}"
}

# The staged files must not contain a secret: settings.local.php, the
# database password, or database settings in settings.php.
check_staged_secrets() {
    local project_path="$1"
    local run_user="$2"
    local staged

    staged="$(project_git "$project_path" "$run_user" ls-files --cached -- \
        'web/sites/*/settings.local.php')" || return 1

    if [[ -n "$staged" ]]; then
        echo "[WARNING] settings.local.php would be committed: $staged"
        return 1
    fi

    if ! check_settings_without_secrets "$project_path"; then
        echo "[WARNING] settings.php contains database settings or the hash salt."
        return 1
    fi

    # The password goes to git through stdin, never in a command line.
    if [[ -n "${DATABASE_PASSWORD:-}" ]] &&
       printf '%s\n' "$DATABASE_PASSWORD" |
            project_git "$project_path" "$run_user" grep --cached -q -F -f - 2>/dev/null; then
        echo "[WARNING] A staged file contains the database password."
        return 1
    fi

    return 0
}

print_git_identity_help() {
    local project_path="$1"
    local message="$2"

    echo "[INFO] The files are staged, but git does not know your name and email"
    echo "       yet, so nothing was committed. Set them once, then commit:"
    echo "         git config --global user.name \"Your Name\""
    echo "         git config --global user.email \"you@example.com\""
    echo "         cd $project_path && git commit -m \"$message\""
}

# git init, .gitignore, .git/info/exclude, git add -A, and the initial
# commit when git knows the user's name and email.
setup_project_git() {
    local project_path="$1"
    local run_user="$2"
    local message="$3"
    local output
    local count
    local commit

    if ! command -v git > /dev/null 2>&1; then
        echo "[WARNING] git is not installed: no repository was created."
        return 1
    fi

    if [[ -e "$project_path/.git" ]]; then
        echo "[INFO] $project_path is already a git repository; left as it is."
        return 0
    fi

    # init.defaultBranch: the first branch is "main" whatever the
    # user's git default is.
    if ! output="$(run_as_project_user "$run_user" \
            git -c init.defaultBranch=main init -q "$project_path" 2>&1)"; then
        echo "[WARNING] git init failed: $output"
        return 1
    fi

    if ! write_project_gitignore "$project_path" "$run_user" ||
       ! write_project_git_exclude "$project_path" "$run_user"; then
        echo "[WARNING] .gitignore or .git/info/exclude could not be written;"
        echo "          nothing was added to git."
        return 1
    fi

    if ! output="$(project_git "$project_path" "$run_user" add -A 2>&1)"; then
        echo "[WARNING] git add failed: $output"
        return 1
    fi

    if ! check_staged_secrets "$project_path" "$run_user"; then
        project_git "$project_path" "$run_user" reset -q > /dev/null 2>&1 || true
        echo "          Nothing was committed. Check .gitignore and settings.php,"
        echo "          then: cd $project_path && git add -A && git commit"
        return 1
    fi

    count="$(project_git "$project_path" "$run_user" diff --cached --name-only | grep -c .)" || count=0
    echo "[OK] Git repository created (branch main, $count files staged)"

    if [[ -z "$(project_git "$project_path" "$run_user" config user.name 2>/dev/null)" ||
          -z "$(project_git "$project_path" "$run_user" config user.email 2>/dev/null)" ]]; then
        print_git_identity_help "$project_path" "$message"
        return 0
    fi

    if ! output="$(project_git "$project_path" "$run_user" commit -q -m "$message" 2>&1)"; then
        echo "[WARNING] The initial commit failed: $output"
        echo "          The files are staged: cd $project_path && git commit -m \"$message\""
        return 1
    fi

    commit="$(project_git "$project_path" "$run_user" rev-parse --short HEAD 2>/dev/null)" || commit=""
    echo "[OK] Initial commit ${commit:+$commit }\"$message\""
}
