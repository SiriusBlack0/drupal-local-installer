#!/usr/bin/env bash

# Snapshot of the code before an update (offline restore), and
# web/sites/default made writable during the update.

# Folders Composer writes code into: vendor/ and the installer-paths of
# composer.json (web/core, web/modules/contrib, ...).
get_composer_code_dirs() {
    # Single quotes: PHP code, not shell code.
    # shellcheck disable=SC2016
    "php${2}" -r '
$root = $argv[1];
$c = json_decode(file_get_contents($root . "/composer.json"), true) ?: [];
$dirs = [$c["config"]["vendor-dir"] ?? "vendor"];
foreach (array_keys($c["extra"]["installer-paths"] ?? []) as $p) {
    $i = strpos($p, "{\$");
    if ($i !== false) { $p = substr($p, 0, $i); }
    $dirs[] = rtrim($p, "/");
}
foreach (array_unique($dirs) as $d) {
    if ($d === "" || $d[0] === "/" || strpos($d, "..") !== false || !is_dir("$root/$d")) { continue; }
    echo $d, "\n";
}
' "$1"
}

# Files the core scaffold plugin writes (index.php, .htaccess,
# default.settings.php, ...), relative to the project folder.
get_scaffold_files() {
    local web_rel="$1"

    (
        cd "$RECORD_PROJECT_PATH" || exit 1
        find "$web_rel" "$web_rel/sites" -maxdepth 1 -type f 2>/dev/null
        find "$web_rel/sites/default" -maxdepth 1 -type f -name 'default.*' 2>/dev/null
        for file in .editorconfig .gitattributes; do
            if [[ -f "$file" ]]; then
                printf '%s\n' "$file"
            fi
        done
    ) | sed 's|^\./||' | sort -u
}

# Copies paths (relative to $1) into $2 with tar, as the developer.
# Unlike "cp -a --parents", tar sets the mode of read-only folders (such
# as web/sites/default after a Drupal installation) only after their
# files are written.
copy_tree() {
    local from="$1"
    local to="$2"
    shift 2

    [[ "$#" -gt 0 ]] || return 0

    run_as_project_user "$PROJECT_USER" tar -C "$from" -cf - -- "$@" |
        run_as_project_user "$PROJECT_USER" tar -C "$to" -xpf -
}

# Drupal makes web/sites/default read-only after the installation. The
# core scaffold (and an offline restore) must replace default.settings.php
# and default.services.yml in it, so it is made writable for the owner
# during the update and gets its old mode back afterwards.
make_sites_default_writable() {
    local dir="$UPDATE_WEB_ROOT/sites/default"
    local mode

    UPDATE_SITES_DEFAULT_MODE=""
    [[ -d "$dir" && ! -L "$dir" ]] || return 0

    mode="$(stat -c '%a' "$dir")" || return 0
    (( (8#$mode & 8#200) != 0 )) && return 0

    if run_as_project_user "$PROJECT_USER" chmod u+w -- "$dir"; then
        UPDATE_SITES_DEFAULT_MODE="$mode"
        echo "[INFO] web/sites/default is writable during the ${UPDATE_KIND:-update} (Drupal protects it; mode $mode is restored afterwards)"
    fi
}

restore_sites_default_mode() {
    [[ -n "$UPDATE_SITES_DEFAULT_MODE" ]] || return 0
    run_as_project_user "$PROJECT_USER" chmod "$UPDATE_SITES_DEFAULT_MODE" -- "$UPDATE_WEB_ROOT/sites/default" ||
        echo "[WARNING] Could not protect web/sites/default again: chmod $UPDATE_SITES_DEFAULT_MODE $UPDATE_WEB_ROOT/sites/default"
    UPDATE_SITES_DEFAULT_MODE=""
}

# A copy of the code as it is now, inside the project folder (same disk),
# so that a failed update can be undone without the network: "composer
# install" would have to download the old packages again. Skipped, with
# a warning, when the disk is too full.
create_code_snapshot() {
    local project="$RECORD_PROJECT_PATH"
    local web_rel
    local needed
    local available
    local -a dirs
    local -a files

    UPDATE_SNAPSHOT_DIR=""
    web_rel="${UPDATE_WEB_ROOT#"$project"}"
    web_rel="${web_rel#/}"
    [[ -n "$web_rel" ]] || web_rel="."

    mapfile -t dirs < <(get_composer_code_dirs "$project" "$RECORD_PHP_VERSION")
    mapfile -t files < <(get_scaffold_files "$web_rel")

    [[ "${#dirs[@]}" -gt 0 || "${#files[@]}" -gt 0 ]] || return 0

    needed="$(cd "$project" && du -sk -- "${dirs[@]}" "${files[@]}" 2>/dev/null | awk '{ s += $1 } END { print s + 0 }')"
    available="$(df -Pk "$project" 2>/dev/null | awk 'NR == 2 { print $4 + 0 }')"

    if [[ -z "$available" ]] || (( available < needed + 102400 )); then
        echo "[WARNING] Not enough free disk space for an offline copy of the code"
        echo "          ($((needed / 1024)) MB needed); restoring would need the network."
        return 0
    fi

    printf 'Copying the current code (for an offline restore) ... '

    # A copy left behind by an interrupted or older run may contain
    # read-only folders: make them writable before removing it.
    if remove_snapshot_folder "$project/.drupal-local-installer/update-snapshot" &&
       run_as_project_user "$PROJECT_USER" mkdir -p -- "$project/.drupal-local-installer/update-snapshot/code" &&
       printf '%s\n' "${dirs[@]}" | run_as_project_user "$PROJECT_USER" tee "$project/.drupal-local-installer/update-snapshot/dirs.list" > /dev/null &&
       printf '%s\n' "${files[@]}" | run_as_project_user "$PROJECT_USER" tee "$project/.drupal-local-installer/update-snapshot/files.list" > /dev/null &&
       copy_tree "$project" "$project/.drupal-local-installer/update-snapshot/code" "${dirs[@]}" "${files[@]}"; then
        UPDATE_SNAPSHOT_DIR="$project/.drupal-local-installer/update-snapshot"
        echo "OK"
    else
        echo "FAILED"
        remove_snapshot_folder "$project/.drupal-local-installer/update-snapshot" 2>/dev/null
        echo "[WARNING] No offline copy of the code; restoring would need the network."
    fi
}

restore_code_snapshot() {
    local dir

    [[ -n "$UPDATE_SNAPSHOT_DIR" && -d "$UPDATE_SNAPSHOT_DIR/code" && -f "$UPDATE_SNAPSHOT_DIR/dirs.list" ]] || return 1

    while IFS= read -r dir; do
        [[ -n "$dir" && "$dir" != /* && "$dir" != *..* ]] || continue
        run_as_project_user "$PROJECT_USER" rm -rf -- "${RECORD_PROJECT_PATH:?}/$dir" || return 1
    done < "$UPDATE_SNAPSHOT_DIR/dirs.list"

    copy_tree "$UPDATE_SNAPSHOT_DIR/code" "$RECORD_PROJECT_PATH" . || return 1

    # Scaffold files that only the new release wrote (for Drupal 10 -> 11:
    # web/autoload_runtime.php, web/.gitignore) go again.
    if [[ -f "$UPDATE_SNAPSHOT_DIR/files.list" ]]; then
        remove_new_scaffold_files "$UPDATE_SNAPSHOT_DIR/files.list" > /dev/null
    fi
}

# The relative path of the web root ("web"), "." for a project without one.
get_web_root_relative() {
    local web_rel="${UPDATE_WEB_ROOT#"$RECORD_PROJECT_PATH"}"

    web_rel="${web_rel#/}"
    printf '%s\n' "${web_rel:-.}"
}

# Scaffold files that exist now but are not in the list given (files of
# an older state): "web/autoload_runtime.php" per line.
get_new_scaffold_files() {
    local old_list="$1"

    get_scaffold_files "$(get_web_root_relative)" | grep -vxF -f "$old_list" || true
}

# Removes those files; prints each one removed.
remove_new_scaffold_files() {
    local old_list="$1"
    local file

    while IFS= read -r file; do
        [[ -n "$file" && "$file" != /* && "$file" != *..* && -f "$RECORD_PROJECT_PATH/$file" && ! -L "$RECORD_PROJECT_PATH/$file" ]] || continue
        run_as_project_user "$PROJECT_USER" rm -f -- "$RECORD_PROJECT_PATH/$file" && printf '%s\n' "$file"
    done < <(get_new_scaffold_files "$old_list")
}

# vendor/ as Composer left it; removed before "composer install" goes
# back to an older lock file: a Composer plugin of the newer release in
# vendor/ (such as symfony/runtime) stops "composer install" otherwise.
# Only the standard vendor/ folder of the project, never a link.
remove_project_vendor() {
    local vendor="$RECORD_PROJECT_PATH/vendor"
    local configured

    # Single quotes: PHP code, not shell code.
    # shellcheck disable=SC2016
    configured="$("php${RECORD_PHP_VERSION}" -r '
$c = json_decode(file_get_contents($argv[1]), true) ?: [];
echo $c["config"]["vendor-dir"] ?? "vendor";
' "$RECORD_PROJECT_PATH/composer.json" 2>/dev/null)" || configured="vendor"

    [[ "$configured" == "vendor" && -d "$vendor" && ! -L "$vendor" ]] || return 0
    run_as_project_user "$PROJECT_USER" rm -rf -- "${RECORD_PROJECT_PATH:?}/vendor"
}

# Removes a snapshot folder, also when it holds read-only folders.
remove_snapshot_folder() {
    local folder="$1"

    [[ "$folder" == */.drupal-local-installer/update-snapshot ]] || return 1
    [[ -e "$folder" ]] || return 0

    run_as_project_user "$PROJECT_USER" chmod -R u+w -- "$folder" 2>/dev/null
    run_as_project_user "$PROJECT_USER" rm -rf -- "$folder"
}

remove_code_snapshot() {
    [[ -n "$UPDATE_SNAPSHOT_DIR" ]] || return 0
    remove_snapshot_folder "$UPDATE_SNAPSHOT_DIR"
    UPDATE_SNAPSHOT_DIR=""
}
