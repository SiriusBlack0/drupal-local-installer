#!/usr/bin/env bash

# ==================================================
# Restoring a backup (--restore NAME [BACKUP])
#
# Goes back to the state of a backup of --update, --upgrade or an
# earlier --restore: composer.json, composer.lock, the code, and the
# database. For later, when the update worked but something turns out
# broken; a failed update is restored automatically already.
#
# The order protects the site: the code first, then a check that Drupal
# reports the backup's version, and only then the database. Before
# anything changes, the current state is backed up too, so a restore can
# be undone with --restore again; if a step fails, that state comes back.
# ==================================================

RESTORE_BACKUP_DIR=""
RESTORE_VERSION=""
# The BACKUP argument of --restore (optional). Set in lib/output.sh.
RESTORE_BACKUP_ARGUMENT=""

# Backups of a project that can be restored, newest first: folders
# NAME-update-*, NAME-upgrade-* and NAME-restore-* with composer.json,
# composer.lock and a database backup.
list_restorable_backups() {
    local machine_name="$1"
    local base
    local dir

    base="$(get_backup_base_dir)"
    [[ -d "$base" ]] || return 0

    while IFS= read -r dir; do
        is_restorable_backup "$dir" && printf '%s\n' "$dir"
    done < <(find "$base" -mindepth 1 -maxdepth 1 -type d \
                \( -name "${machine_name}-update-*" -o -name "${machine_name}-upgrade-*" -o -name "${machine_name}-restore-*" \) \
                -printf '%f\n' 2>/dev/null | sort -t- -k3 -r | sed "s|^|$base/|")
}

is_restorable_backup() {
    local dir="$1"

    [[ -d "$dir" && ! -L "$dir" && -f "$dir/composer.json" && -f "$dir/composer.lock" ]] || return 1
    [[ -s "$dir/database.sql.gz" || -s "$dir/database.sqlite" ]]
}

# The Drupal core version in a composer.lock.
get_lock_core_version() {
    # Single quotes: PHP code, not shell code.
    # shellcheck disable=SC2016
    "php${RECORD_PHP_VERSION}" -r '
$l = json_decode(file_get_contents($argv[1]), true) ?: [];
foreach ($l["packages"] ?? [] as $p) {
    if (($p["name"] ?? "") === "drupal/core") { echo ltrim($p["version"] ?? "", "v"), "\n"; exit(0); }
}
exit(1);
' "$1" 2>/dev/null
}

# "upgrade, 2026-10-23, Drupal 10.6.20" for a backup folder
# (NAME-KIND-YYYYMMDD-HHMMSS).
describe_backup() {
    local dir="$1"
    local name
    local kind="?"
    local day="?"
    local version

    name="$(basename "$dir")"
    version="$(get_lock_core_version "$dir/composer.lock")" || version="?"

    if [[ "$name" =~ -([a-z]+)-([0-9]{4})([0-9]{2})([0-9]{2})-[0-9]{6}$ ]]; then
        kind="${BASH_REMATCH[1]}"
        day="${BASH_REMATCH[2]}-${BASH_REMATCH[3]}-${BASH_REMATCH[4]}"
    fi

    printf '%s, %s, Drupal %s\n' "$kind" "$day" "$version"
}

# The folder name ends with "-YYYYMMDD-HHMMSS": the date and time part.
get_backup_time() {
    local name

    name="$(basename "$1")"

    if [[ "$name" =~ -([0-9]{4})([0-9]{2})([0-9]{2})-([0-9]{2})([0-9]{2})[0-9]{2}$ ]]; then
        printf '%s-%s-%s %s:%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}"
    else
        echo "?"
    fi
}

# Sets RESTORE_BACKUP_DIR: the folder given (it must be one of the
# project's backups), or the one chosen from the list.
choose_restore_backup() {
    local machine_name="$1"
    local given="$2"
    local -a backups=()
    local dir
    local answer
    local index

    mapfile -t backups < <(list_restorable_backups "$machine_name")

    if [[ -n "$given" ]]; then
        given="$(realpath -e -- "$given" 2>/dev/null)" || given=""

        for dir in "${backups[@]}"; do
            if [[ "$dir" == "$given" ]]; then
                RESTORE_BACKUP_DIR="$dir"
                return 0
            fi
        done

        echo "[ERROR] Not a backup of '$machine_name' that can be restored: $2"
        echo "        Backups are in $(get_backup_base_dir) (${machine_name}-update-*,"
        echo "        ${machine_name}-upgrade-*, ${machine_name}-restore-*)."
        return 1
    fi

    if [[ "${#backups[@]}" -eq 0 ]]; then
        echo "[ERROR] No backup of '$machine_name' to restore in $(get_backup_base_dir)."
        echo "        Backups are made by --update, --upgrade and --restore."
        return 1
    fi

    echo
    echo "Backups of $machine_name (newest first; each is the state BEFORE that run):"
    echo

    for index in "${!backups[@]}"; do
        printf '  %d) %s (%s)\n' "$((index + 1))" "$(basename "${backups[index]}")" "$(describe_backup "${backups[index]}")"
    done

    echo

    while true; do
        if ! read -r -p "Restore which backup? [1-${#backups[@]}, Enter = cancel]: " answer || [[ -z "$answer" ]]; then
            echo
            return 1
        fi

        if [[ "$answer" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= ${#backups[@]} )); then
            RESTORE_BACKUP_DIR="${backups[answer - 1]}"
            return 0
        fi

        echo "Invalid selection."
    done
}

# rollback_update loads UPDATE_DATABASE_BACKUP: the database of the
# backup of the current state (made at the start of --restore).
# shellcheck disable=SC2034
use_current_state_database() {
    UPDATE_DATABASE_BACKUP="$UPDATE_BACKUP_DIR/database.sql.gz"
    [[ "$RECORD_DATABASE_ENGINE" == "sqlite" ]] && UPDATE_DATABASE_BACKUP="$UPDATE_BACKUP_DIR/database.sqlite"
    [[ -f "$UPDATE_BACKUP_DIR/database.owner" ]] && UPDATE_DATABASE_OWNER="$(cat "$UPDATE_BACKUP_DIR/database.owner")"
    return 0
}

confirm_restore() {
    local machine_name="$1"
    local answer

    echo
    echo "Type the project name to restore the backup."

    if ! read -r -p "Project name ($machine_name): " answer; then
        echo
        return 1
    fi

    [[ "$answer" == "$machine_name" ]]
}

# Ctrl+C while the project is being restored: the state of before comes
# back (from the backup made at the start), then stop.
interrupt_restore() {
    trap '' INT TERM
    to_console
    echo
    echo "[INTERRUPTED] Stopping the restore; putting the project back as it was..."
    use_current_state_database
    rollback_update
    exit 130
}

# Scaffold files that only a newer release wrote (for Drupal 11 back to
# 10: web/autoload_runtime.php, web/.gitignore). They are listed; the
# developer decides whether they go.
offer_removing_newer_scaffold_files() {
    local list="$RESTORE_BACKUP_DIR/scaffold-files.list"
    local files
    local answer

    if [[ ! -f "$list" ]]; then
        echo "[INFO] Files that only the newer release wrote may be left (for Drupal 11:"
        echo "       web/autoload_runtime.php, web/.gitignore). This backup is older than"
        echo "       the list of such files; in git, \"git status\" shows them as new."
        return 0
    fi

    files="$(get_new_scaffold_files "$list")"
    [[ -n "$files" ]] || return 0

    echo
    echo "These files were written by the newer release and are not in the backup:"
    printf '%s\n' "$files" | sed 's/^/  /'

    echo "(A file you added yourself at that place would be listed too.)"

    if ! read -r -p "Remove them? [y/N]: " answer; then
        echo
        answer="n"
    fi

    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        echo "[INFO] Kept. Remove them by hand when you are sure they are not yours."
        return 0
    fi

    remove_new_scaffold_files "$list" | sed 's/^/[OK] Removed /'
}

# Registry after the restore: the backup's version; notes that belonged
# to the newer state go.
update_record_after_restore() {
    local record="$1"
    local machine_name="$2"

    set_project_field "$record" drupal_version "$RESTORE_VERSION" || true
    set_project_field "$record" restored_from "$(date +%F) $(basename "$RESTORE_BACKUP_DIR")" || true
    remove_project_field "$record" accepted_advisories || true

    if [[ "${RESTORE_VERSION%%.*}" -lt "${UPDATE_PREVIOUS_VERSION%%.*}" ]] 2>/dev/null; then
        remove_project_field "$record" upgraded_from || true
    fi

    if ! grep -q '"mglaman/composer-drupal-lenient"' "$RECORD_PROJECT_PATH/composer.json"; then
        remove_project_field "$record" lenient_packages || true
    fi

    log_line "Registry of $machine_name: drupal_version=$RESTORE_VERSION"
}

# UPDATE_* variables are read in lib/update/ (backup, rollback, checks).
# shellcheck disable=SC2034
run_restore_project() {
    local machine_name
    local record
    local web_root
    local current
    local backup_time
    local status=0

    machine_name="$(get_project_machine_name "$1")"
    RESTORE_BACKUP_DIR=""
    RESTORE_VERSION=""

    if [[ ! "$machine_name" =~ ^[a-z0-9_]+$ ]]; then
        echo "[ERROR] Invalid project name: '$1'"
        return 1
    fi

    record="$(get_project_record_path "$machine_name")" || return 1

    if [[ ! -f "$record" ]]; then
        echo "[ERROR] '$machine_name' is not in the registry."
        suggest_registered_name "$machine_name"
        return 1
    fi

    acquire_project_lock "$machine_name" || return 1
    load_project_record "$machine_name" "$record" || return 1
    web_root="${RECORD_WEB_ROOT:-$RECORD_PROJECT_PATH/web}"
    UPDATE_WEB_ROOT="$web_root"
    UPDATE_KIND="restore"

    # ---- Checks (read only). The site itself may be broken: that is
    # often why it is restored, so Drush is not required to work. ----
    if [[ ! -d "$RECORD_PROJECT_PATH" ]]; then
        echo "[ERROR] Project folder not found: $RECORD_PROJECT_PATH"
        return 1
    fi

    if [[ "$(stat -c '%U' "$RECORD_PROJECT_PATH")" != "$PROJECT_USER" ]]; then
        echo "[BLOCKED] $RECORD_PROJECT_PATH belongs to $(stat -c '%U' "$RECORD_PROJECT_PATH"), not to you ($PROJECT_USER)."
        echo "          Composer never runs as root or as another user."
        return 1
    fi

    if [[ -z "$RECORD_PHP_VERSION" ]] || ! command -v "php${RECORD_PHP_VERSION}" > /dev/null; then
        echo "[BLOCKED] The project's PHP (${RECORD_PHP_VERSION:-unknown}) is not available."
        return 1
    fi

    case "$RECORD_DATABASE_ENGINE" in
        mariadb|mysql|postgresql|sqlite) ;;
        *)
            echo "[BLOCKED] The project's database is unknown, so it cannot be restored."
            return 1
            ;;
    esac

    if [[ ! -f "$RECORD_PROJECT_PATH/composer.json" || ! -f "$RECORD_PROJECT_PATH/composer.lock" ]]; then
        echo "[BLOCKED] Not a Composer project (composer.json and composer.lock are needed)."
        return 1
    fi

    choose_restore_backup "$machine_name" "$RESTORE_BACKUP_ARGUMENT" || { echo "Restore cancelled; nothing was changed."; return 1; }

    if ! RESTORE_VERSION="$(get_lock_core_version "$RESTORE_BACKUP_DIR/composer.lock")" ||
       [[ ! "$RESTORE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "[BLOCKED] The backup's composer.lock names no stable Drupal core release."
        return 1
    fi

    if [[ "$RECORD_DATABASE_ENGINE" == "sqlite" && ! -s "$RESTORE_BACKUP_DIR/database.sqlite" ]] ||
       [[ "$RECORD_DATABASE_ENGINE" != "sqlite" && ! -s "$RESTORE_BACKUP_DIR/database.sql.gz" ]]; then
        echo "[BLOCKED] The backup has no database of this engine ($RECORD_DATABASE_ENGINE)."
        return 1
    fi

    if [[ "$RECORD_DATABASE_ENGINE" == "postgresql" ]] &&
       { [[ ! -f "$RESTORE_BACKUP_DIR/database.owner" ]] ||
         ! is_valid_database_user "$(cat "$RESTORE_BACKUP_DIR/database.owner")" && [[ "$(cat "$RESTORE_BACKUP_DIR/database.owner")" != "postgres" ]]; }; then
        echo "[BLOCKED] The backup does not name the owner of the PostgreSQL database (database.owner)."
        return 1
    fi

    current="$(get_drupal_version_in "$web_root" 2>/dev/null)" || current=""
    UPDATE_PREVIOUS_VERSION="$current"
    backup_time="$(get_backup_time "$RESTORE_BACKUP_DIR")"

    # ---- Plan ----
    echo
    echo "======================================"
    echo "  Restore project: $machine_name"
    echo "======================================"
    echo
    echo "Backup:       $RESTORE_BACKUP_DIR"
    echo "              ($(describe_backup "$RESTORE_BACKUP_DIR"); the state before that run)"
    echo "Drupal core:  ${current:-unknown} -> $RESTORE_VERSION"
    echo "Database:     replaced by the backup's. Content, users and configuration"
    echo "              changed since $backup_time are lost."
    echo "First:        a backup of the current state (${machine_name}-restore-...), so this"
    echo "              restore can be undone with --restore again."
    echo
    echo "Steps: backup -> maintenance mode -> code (composer install) -> check that"
    echo "Drupal reports $RESTORE_VERSION -> database -> cache -> checks"
    echo "The database is replaced only after the code is back. If a step fails,"
    echo "the current state comes back automatically."

    if [[ -d "$RECORD_PROJECT_PATH/.git" ]] &&
       [[ -n "$(run_as_project_user "$PROJECT_USER" git -C "$RECORD_PROJECT_PATH" status --porcelain -- composer.json composer.lock 2>/dev/null)" ]]; then
        echo
        echo "[NOTE] composer.json or composer.lock have uncommitted changes. They are"
        echo "       replaced too (the backup of the current state keeps them)."
    fi

    if [[ "$REMOVE_DRY_RUN" -eq 1 ]]; then
        echo
        echo "[DRY RUN] Nothing was changed."
        return 0
    fi

    if ! confirm_restore "$machine_name"; then
        echo "Name does not match. Restore cancelled; nothing was changed."
        return 1
    fi

    # sudo for the database backup before Composer (which clears the cached
    # password); the database restore after Composer may ask once more.
    if [[ "$RECORD_DATABASE_ENGINE" != "sqlite" ]]; then
        require_sudo || return 1
    fi

    create_update_backup "$machine_name" || return 1

    trap 'interrupt_restore' INT TERM
    perform_restore "$record" "$machine_name" || status=$?
    trap - INT TERM

    return "$status"
}

# The changing part of --restore. Uses the variables of run_restore_project.
# UPDATE_BACKUP_DIR is the backup of the current state (for rollback_update);
# RESTORE_BACKUP_DIR the backup being restored.
# shellcheck disable=SC2034
perform_restore() {
    local record="$1"
    local machine_name="$2"
    local version

    UPDATE_DATABASE_CHANGED=0
    set_maintenance_mode 1 && echo "[OK] Maintenance mode on"
    make_sites_default_writable
    create_code_snapshot

    echo

    if ! cp --preserve=timestamps -- "$RESTORE_BACKUP_DIR/composer.json" "$RESTORE_BACKUP_DIR/composer.lock" "$RECORD_PROJECT_PATH/" ||
       ! remove_project_vendor ||
       ! run_logged_retrying_network "Installing the code of the backup (composer install)" - \
            run_project_composer "$RECORD_PROJECT_PATH" "$RECORD_PHP_VERSION" install; then
        echo "[ERROR] The code of the backup could not be installed; the database was not touched."
        rollback_update
        return 1
    fi

    version="$(get_drupal_version_in "$UPDATE_WEB_ROOT" 2>/dev/null)" || version=""

    if [[ "$version" != "$RESTORE_VERSION" ]]; then
        echo "[ERROR] Drupal reports '$version' instead of $RESTORE_VERSION; the database was not touched."
        rollback_update
        return 1
    fi

    echo "[OK] Code of the backup installed: Drupal $RESTORE_VERSION"
    offer_removing_newer_scaffold_files

    if [[ "$RECORD_DATABASE_ENGINE" != "sqlite" ]]; then
        echo "The database is restored with sudo (it may ask for your password again)."
    fi

    # From here on the database changes: a failure restores it too.
    UPDATE_DATABASE_CHANGED=1
    UPDATE_DATABASE_BACKUP="$RESTORE_BACKUP_DIR/database.sql.gz"
    [[ "$RECORD_DATABASE_ENGINE" == "sqlite" ]] && UPDATE_DATABASE_BACKUP="$RESTORE_BACKUP_DIR/database.sqlite"
    [[ -f "$RESTORE_BACKUP_DIR/database.owner" ]] && UPDATE_DATABASE_OWNER="$(cat "$RESTORE_BACKUP_DIR/database.owner")"

    if ! restore_database_from_backup; then
        echo "[ERROR] The database of the backup could not be restored."
        use_current_state_database
        rollback_update
        return 1
    fi

    echo "[OK] Database of the backup restored"

    # A rollback from here on loads the current-state database again.
    use_current_state_database

    if ! run_logged "Rebuilding caches" \
            run_project_drush "$RECORD_PROJECT_PATH" "$RECORD_PHP_VERSION" cache:rebuild; then
        rollback_update
        return 1
    fi

    set_maintenance_mode 0 && echo "[OK] Maintenance mode off"

    # verify_updated_site compares with UPDATE_TARGET.
    UPDATE_TARGET="$RESTORE_VERSION"

    if ! verify_updated_site "$UPDATE_WEB_ROOT"; then
        echo "[ERROR] The restored site does not work; putting back the state of before."
        rollback_update
        return 1
    fi

    update_record_after_restore "$record" "$machine_name"
    remove_code_snapshot
    restore_sites_default_mode

    echo
    echo "[DONE] $machine_name: Drupal ${UPDATE_PREVIOUS_VERSION:-unknown} -> $RESTORE_VERSION (backup of $(get_backup_time "$RESTORE_BACKUP_DIR"))"
    echo "The state before this restore: $UPDATE_BACKUP_DIR"
    echo "  (undo: ./install.sh --restore $machine_name $UPDATE_BACKUP_DIR)"
    print_git_commit_hint "Restore backup $(basename "$RESTORE_BACKUP_DIR") (Drupal $RESTORE_VERSION)"
}
