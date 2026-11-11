#!/usr/bin/env bash

# ==================================================
# Updating Drupal core (--check-updates, --update NAME)
#
# Patch (10.6.16 -> 10.6.18) and minor (10.6 -> 10.7) updates of Drupal
# core only. Major upgrades: lib/upgrade/ (--upgrade NAME).
#
# The target version is fixed with "composer update --with", so
# composer.json is never changed. Before anything changes, the database
# and composer.json/composer.lock are backed up; if any step fails, code
# and database are restored automatically.
# ==================================================

# Core packages that move together with the core version.
# Read in lib/update/check.sh.
# shellcheck disable=SC2034
CORE_COMPANION_PACKAGES=(
    drupal/core-composer-scaffold
    drupal/core-project-message
    drupal/core-dev
)

UPDATE_CORE_PACKAGE=""
UPDATE_WITH_PACKAGES=()
UPDATE_BACKUP_DIR=""
# Read in lib/update/backup.sh.
# shellcheck disable=SC2034
UPDATE_DATABASE_BACKUP=""
# shellcheck disable=SC2034
UPDATE_DATABASE_OWNER=""
UPDATE_DATABASE_CHANGED=0
UPDATE_PREVIOUS_VERSION=""
UPDATE_TARGET=""
UPDATE_WEB_ROOT=""
UPDATE_SNAPSHOT_DIR=""
# Read in lib/update/snapshot.sh.
# shellcheck disable=SC2034
UPDATE_SITES_DEFAULT_MODE=""
# Extra Composer options for this update (--no-security-blocking after the
# user accepted the advisories that block it).
UPDATE_EXTRA_ARGS=()
UPDATE_ACCEPTED_ADVISORIES=""
# Packages the update adds (from the dry run), for the plan and the end.
UPDATE_NEW_PACKAGES=""
# git status before the run (remember_git_status), for the commit line.
GIT_STATUS_BEFORE=""
GIT_STATUS_CAPTURED=0
# The target that was not chosen (patch or minor), for advice.
UPDATE_ALTERNATIVE=""
# composer.json ahead of composer.lock: the earlier commit whose
# composer.json matches the lock (prepare_locked_composer_json), kept in
# the backup as composer.locked.json.
UPDATE_LOCKED_JSON_COMMIT=""
UPDATE_LOCKED_JSON_SEARCHED=0
# Configuration items that differed before the run (remember_config_differences).
UPDATE_CONFIG_BEFORE=""
UPDATE_CONFIG_BEFORE_KNOWN=0
# "update" or "upgrade" (--upgrade reuses the backup and the restore).
UPDATE_KIND="update"


set_maintenance_mode() {
    run_project_drush "$RECORD_PROJECT_PATH" "$RECORD_PHP_VERSION" \
        state:set system.maintenance_mode "$1" --input-format=integer > /dev/null 2>&1
}

# Ctrl+C (or kill) while the project is being changed: undo, then stop.
interrupt_update() {
    trap '' INT TERM
    to_console
    echo
    echo "[INTERRUPTED] Stopping the update and restoring the project..."
    rollback_update
    exit 130
}

# Restores code (composer.json/lock, then the offline copy or "composer
# install") and, when it was changed, the database. Prints manual steps
# if that fails too.
rollback_update() {
    local code_ok=1
    local database_ok=1

    say
    say "Restoring the project as it was before the ${UPDATE_KIND}..."

    if ! cp --preserve=timestamps -- "$UPDATE_BACKUP_DIR/composer.json" "$UPDATE_BACKUP_DIR/composer.lock" "$RECORD_PROJECT_PATH/"; then
        say "[FAILED] composer.json and composer.lock could not be copied back"
        code_ok=0
    elif restore_code_snapshot; then
        say "[OK] Code restored (from the offline copy)"
    elif { [[ "$UPDATE_KIND" == "update" ]] || remove_project_vendor; } &&
         install_backup_code_with_composer; then
        say "[OK] Code restored"
    else
        say "[FAILED] Code"
        code_ok=0
    fi

    if [[ "$code_ok" -eq 1 && -n "$UPDATE_PREVIOUS_VERSION" &&
          "$(get_drupal_version_in "$UPDATE_WEB_ROOT" 2>/dev/null)" != "$UPDATE_PREVIOUS_VERSION" ]]; then
        say "[FAILED] Drupal does not report version $UPDATE_PREVIOUS_VERSION again."
        code_ok=0
    fi

    # The old database only with the old code: with the new code it would
    # be the wrong one (the new code and the updated database still match).
    if [[ "$UPDATE_DATABASE_CHANGED" -eq 1 ]]; then
        if [[ "$code_ok" -eq 0 ]]; then
            say "[SKIPPED] Database: not restored while the code is not back."
            database_ok=0
        else
            if [[ "$RECORD_DATABASE_ENGINE" != "sqlite" ]]; then
                say "The database is restored with sudo (it may ask for your password again)."
            fi

            if restore_database_from_backup; then
                say "[OK] Database restored"
            else
                say "[FAILED] Database"
                database_ok=0
            fi
        fi
    fi

    restore_sites_default_mode

    if [[ "$code_ok" -eq 1 && "$database_ok" -eq 1 ]]; then
        set_maintenance_mode 0 || true
        run_project_drush "$RECORD_PROJECT_PATH" "$RECORD_PHP_VERSION" cache:rebuild > /dev/null 2>&1 || true
        remove_code_snapshot
        mark_backup_result "rolled-back"
        say "[OK] The project is back to its previous version."
        return 0
    fi

    # Code and database do not match now: the site stays closed.
    set_maintenance_mode 1 || true
    mark_backup_result "rolled-back-incomplete"
    print_manual_restore "$code_ok" "$database_ok"
    return 1
}

# "composer install" of the backup's code during the rollback. A backup
# whose composer.json was ahead of composer.lock is installed with
# composer.locked.json, then its own composer.json goes back.
install_backup_code_with_composer() {
    local locked="$UPDATE_BACKUP_DIR/composer.locked.json"

    # An explicit status: a bare "return" in a trap handler (Ctrl+C)
    # would return the status of before the trap.
    if [[ ! -f "$locked" ]]; then
        run_logged "Restoring the previous code (composer install)" \
            run_project_composer "$RECORD_PROJECT_PATH" "$RECORD_PHP_VERSION" install || return 1
        return 0
    fi

    cp --preserve=timestamps -- "$locked" "$RECORD_PROJECT_PATH/composer.json" &&
    run_logged "Restoring the previous code (composer install)" \
        run_project_composer "$RECORD_PROJECT_PATH" "$RECORD_PHP_VERSION" install &&
    cp --preserve=timestamps -- "$UPDATE_BACKUP_DIR/composer.json" "$RECORD_PROJECT_PATH/composer.json"
}

# Notes in the backup folder how the run that made it ended, for the list
# of --restore ("run failed, restored automatically").
mark_backup_result() {
    [[ -n "$UPDATE_BACKUP_DIR" && -d "$UPDATE_BACKUP_DIR" ]] || return 0
    ( umask 077 && printf '%s %s\n' "$1" "$(date '+%F %H:%M')" > "$UPDATE_BACKUP_DIR/result" ) 2>/dev/null || true
}

# The command that loads the backup's database, for this engine.
get_manual_database_restore_command() {
    local backup="$UPDATE_BACKUP_DIR"

    case "$RECORD_DATABASE_ENGINE" in
        mariadb|mysql)
            echo "gunzip -c $backup/database.sql.gz | sudo mysql"
            ;;
        postgresql)
            echo "sudo -u postgres dropdb $RECORD_DATABASE_NAME && sudo -u postgres createdb -O \"\$(cat $backup/database.owner)\" $RECORD_DATABASE_NAME && gunzip -c $backup/database.sql.gz | sudo -u postgres psql -X -v ON_ERROR_STOP=1 -d $RECORD_DATABASE_NAME"
            ;;
        sqlite)
            echo "cp $backup/database.sqlite $RECORD_SQLITE_PATH"
            ;;
    esac
}

# What is left to do by hand: only the part that failed.
print_manual_restore() {
    local code_ok="$1"
    local database_ok="$2"

    say
    say "[ERROR] Automatic restore did not complete. The site stays in maintenance mode"
    say "        until code and database match again. Backup: $UPDATE_BACKUP_DIR"

    if [[ "$code_ok" -eq 0 ]]; then
        say "  1. The code:"
        say "     cd $RECORD_PROJECT_PATH && chmod u+w $UPDATE_WEB_ROOT/sites/default"
        if [[ -f "$UPDATE_BACKUP_DIR/composer.locked.json" ]]; then
            say "     cp $UPDATE_BACKUP_DIR/composer.locked.json composer.json && cp $UPDATE_BACKUP_DIR/composer.lock ."
            say "     rm -rf vendor && $(get_project_composer_hint) install && cp $UPDATE_BACKUP_DIR/composer.json ."
            say "     chmod 555 $UPDATE_WEB_ROOT/sites/default"
        else
            say "     cp $UPDATE_BACKUP_DIR/composer.json $UPDATE_BACKUP_DIR/composer.lock ."
            say "     rm -rf vendor && $(get_project_composer_hint) install && chmod 555 $UPDATE_WEB_ROOT/sites/default"
        fi
        say "     Check: $(get_project_drush_hint) status --field=drupal-version  (must say ${UPDATE_PREVIOUS_VERSION:-the old version})"
    else
        say "  The code is back (Drupal ${UPDATE_PREVIOUS_VERSION:-as before}); only the database is missing."
    fi

    if [[ "$UPDATE_DATABASE_CHANGED" -eq 1 ]]; then
        say "  $([[ "$code_ok" -eq 0 ]] && echo "2. Then the database" || echo "1. The database"):"
        say "     $(get_manual_database_restore_command)"
    fi

    say "  Last: cd $RECORD_PROJECT_PATH && $(get_project_drush_hint) cache:rebuild && $(get_project_drush_hint) state:set system.maintenance_mode 0"

    if [[ -n "$UPDATE_SNAPSHOT_DIR" && -d "$UPDATE_SNAPSHOT_DIR" ]]; then
        say "  The offline copy of the old code is kept: $UPDATE_SNAPSHOT_DIR"
        say "  Remove it once the site works: chmod -R u+w $UPDATE_SNAPSHOT_DIR && rm -rf $UPDATE_SNAPSHOT_DIR"
    fi
}

update_record_version() {
    set_project_field "$1" drupal_version "$2"
}

confirm_update() {
    local machine_name="$1"
    local answer

    echo
    echo "Type the project name to start the update."

    if ! read -r -p "Project name ($machine_name): " answer; then
        echo
        return 1
    fi

    [[ "$answer" == "$machine_name" ]]
}

choose_update_target() {
    local patch="$1"
    local minor="$2"
    local answer

    UPDATE_ALTERNATIVE=""

    # One target only: no question (said, so that the next answer is
    # not taken for this one).
    if [[ -n "$patch" && -z "$minor" ]]; then
        UPDATE_TARGET="$patch"
        echo "Only one target: $patch (patch update); no choice to make."
        return 0
    fi

    if [[ -z "$patch" && -n "$minor" ]]; then
        UPDATE_TARGET="$minor"
        echo "Only one target: $minor (minor update); no choice to make."
        return 0
    fi

    while true; do
        echo
        echo "1) Patch update to $patch (stays on Drupal $(echo "$patch" | cut -d. -f1,2): fixes of that line)"
        echo "2) Minor update to $minor (newer line; Drupal gives security fixes only to recent minors)"

        if ! read -r -p "Select [1-2]: " answer; then
            echo
            return 1
        fi

        # UPDATE_ALTERNATIVE is read in lib/update/advisories.sh.
        # shellcheck disable=SC2034
        case "$answer" in
            1) UPDATE_TARGET="$patch"; UPDATE_ALTERNATIVE="$minor"; return 0 ;;
            2) UPDATE_TARGET="$minor"; UPDATE_ALTERNATIVE="$patch"; return 0 ;;
            *) echo "Invalid selection." ;;
        esac
    done
}

# Checks shared by --update and --upgrade (read only): the project is
# registered, belongs to the developer, is a working Composer project with
# a stable Drupal 10+ release. Takes the lock. Sets the caller's
# machine_name, record, web_root and current (and the UPDATE_* basics).
check_core_change_project() {
    local with_args=()

    machine_name="$(get_project_machine_name "$1")"
    UPDATE_LOCKED_JSON_COMMIT=""
    UPDATE_LOCKED_JSON_SEARCHED=0

    if [[ ! "$machine_name" =~ ^[a-z0-9_]+$ ]]; then
        echo "[ERROR] Invalid project name: '$1'"
        return 1
    fi

    record="$(get_project_record_path "$machine_name")" || return 1

    if [[ ! -f "$record" ]]; then
        echo "[ERROR] '$machine_name' is not in the registry. Register it with --scan first."
        suggest_registered_name "$machine_name"
        return 1
    fi

    acquire_project_lock "$machine_name" || return 1
    load_project_record "$machine_name" "$record" || return 1
    web_root="${RECORD_WEB_ROOT:-$RECORD_PROJECT_PATH/web}"
    UPDATE_WEB_ROOT="$web_root"

    # ---- Checks (read only) ----
    if [[ ! -d "$RECORD_PROJECT_PATH" ]]; then
        print_missing_project_folder "$machine_name"
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

    if [[ "$RECORD_DATABASE_ENGINE" == "unknown" ]]; then
        echo "[BLOCKED] The project's database is unknown, so it cannot be backed up."
        echo "          Run --unregister and --scan again once Drush can read it."
        return 1
    fi

    if [[ ! -f "$RECORD_PROJECT_PATH/composer.json" || ! -f "$RECORD_PROJECT_PATH/composer.lock" ]]; then
        echo "[BLOCKED] Not a Composer project (composer.json and composer.lock are needed)."
        echo "          Drupal 7 and other non-Composer sites are not updated by the installer."
        return 1
    fi

    if ! current="$(get_drupal_version_in "$web_root")" || [[ ! "$current" =~ ^[0-9]+\. ]]; then
        echo "[ERROR] Could not read the Drupal version in $web_root"
        return 1
    fi

    UPDATE_PREVIOUS_VERSION="$current"

    if [[ "${current%%.*}" -lt 10 ]]; then
        echo "[BLOCKED] Drupal $current is end of life; it is not updated by the installer."
        return 1
    fi

    if [[ ! "$current" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "[BLOCKED] Drupal $current is not a stable release; only stable releases are updated."
        return 1
    fi

    if ! mapfile -t with_args < <(get_core_packages "$RECORD_PROJECT_PATH" "$RECORD_PHP_VERSION") ||
       [[ "${#with_args[@]}" -eq 0 ]]; then
        echo "[BLOCKED] composer.json requires neither drupal/core-recommended nor drupal/core."
        return 1
    fi

    UPDATE_CORE_PACKAGE="${with_args[0]}"
    UPDATE_WITH_PACKAGES=("${with_args[@]}")

    remember_git_status

    if [[ -d "$RECORD_PROJECT_PATH/.git" ]] &&
       [[ -n "$(run_as_project_user "$PROJECT_USER" git -C "$RECORD_PROJECT_PATH" status --porcelain -- composer.json composer.lock 2>/dev/null)" ]]; then
        echo "[BLOCKED] composer.json or composer.lock have uncommitted changes."
        echo "          Commit or revert them first, so the update does not mix with them."
        return 1
    fi

    # --update checks it after it found a target (nothing to say when Drupal
    # is already the newest release).
    if [[ "$UPDATE_KIND" == "upgrade" ]] && is_composer_lock_outdated "$RECORD_PROJECT_PATH"; then
        explain_outdated_lock || return 1
    fi

    if [[ "$(run_project_drush "$RECORD_PROJECT_PATH" "$RECORD_PHP_VERSION" status --field=bootstrap 2>/dev/null)" != *"Successful"* ]]; then
        echo "[BLOCKED] The site does not work right now (Drush cannot bootstrap it)."
        echo "          Fix that first: an update could not be checked afterwards."
        return 1
    fi
}

# composer.json has changes that are not in composer.lock yet. For an
# upgrade that is the usual way to allow new major releases of contrib
# ("composer require 'drupal/gin:^5' --no-update"): the upgrade installs
# them. For a core update it is unclear what should happen with them:
# the developer decides. Returns 1 to stop.
explain_outdated_lock() {
    local answer
    local reason
    local status=0

    # Can a later --restore of this run's backup install these files? Not
    # when composer.json requires a package that composer.lock lacks
    # ("composer require vendor/name --no-update"). The automatic restore
    # during the run is not affected: it uses an offline copy of the code.
    reason="$(check_composer_files_installable "$RECORD_PROJECT_PATH")" || status=$?

    # An earlier commit's composer.json that matches composer.lock: the
    # backup keeps it, so a --restore can install the code of now.
    if [[ "$status" -eq 1 ]] && prepare_locked_composer_json; then
        status=3
    fi

    if [[ "$UPDATE_KIND" == "upgrade" ]]; then
        echo "[INFO] composer.json has changes that are not in composer.lock yet (for example"
        echo "       \"composer require ... --no-update\"). The upgrade installs them together"
        echo "       with the new core; the Composer trial below shows what changes."

        [[ "$status" -eq 3 ]] && explain_locked_composer_json
        [[ "$status" -eq 1 ]] || return 0

        explain_unrestorable_backup "$reason"

        if [[ "$REMOVE_DRY_RUN" -eq 1 ]]; then
            echo "       (Dry run: a real run asks whether to continue.)"
            return 0
        fi

        if ! read -r -p "Continue with the upgrade anyway? [y/N]: " answer || [[ ! "$answer" =~ ^[Yy]$ ]]; then
            echo "Upgrade cancelled; nothing was changed."
            return 1
        fi

        return 0
    fi

    echo "[WARNING] composer.json has changes that are not in composer.lock yet: it was"
    echo "          changed without \"composer update\". A core update may install those"
    echo "          changes too, or fail because of them. Usually it is better to bring them"
    echo "          in line first, commit, and update then:"
    echo "            cd $RECORD_PROJECT_PATH && $(get_project_composer_hint) update --dry-run   (what differs)"
    echo "            $(get_project_composer_hint) update vendor/name   (or undo the change in composer.json)"

    case "$status" in
        0) echo "          The backup can be restored later: composer install accepts these files." ;;
        1) explain_unrestorable_backup "$reason" ;;
        3) explain_locked_composer_json ;;
        *) echo "          Whether a later --restore of the backup works could not be checked (network?)." ;;
    esac

    # Only when a stable next major exists (third field of the targets).
    if [[ -n "${major:-}" ]]; then
        echo "          If the change prepares Drupal ${major%%.*} (composer require ... --no-update),"
        echo "          it is fine as it is: run ./install.sh --upgrade $machine_name instead."
    fi

    if [[ "$REMOVE_DRY_RUN" -eq 1 ]]; then
        echo "          (Dry run: a real run asks whether to continue.)"
        return 0
    fi

    if ! read -r -p "Continue with the update anyway? [y/N]: " answer || [[ ! "$answer" =~ ^[Yy]$ ]]; then
        echo "Update cancelled; nothing was changed."
        return 1
    fi
}

# The backup of this run would hold composer files that "composer install"
# refuses: said plainly, with Composer's reason.
explain_unrestorable_backup() {
    echo "[WARNING] The backup of this ${UPDATE_KIND} could NOT be restored later with --restore:"
    echo "          composer install refuses the current composer files:"
    printf '%s\n' "$1" | head -n 4 | sed 's/^/            /'
    echo "          (If the ${UPDATE_KIND} itself fails, the automatic restore is not affected:"
    echo "          it uses an offline copy of the code.) Bring the files in line first to"
    echo "          keep a backup you can go back to."
}

run_update_project() {
    local machine_name
    local record
    local web_root
    local current
    local targets
    local patch
    local minor
    local major
    local with_args=()
    local package
    local dry_output
    local errors_before=""
    local log_before=""
    local security_status
    local blocked

    UPDATE_KIND="update"
    check_core_change_project "$1" || return 1

    echo
    echo "Looking for updates of $UPDATE_CORE_PACKAGE $current..."

    if ! targets="$(get_update_targets "$RECORD_PROJECT_PATH" "$RECORD_PHP_VERSION" "$current")" &&
       ! { sleep "${COMPOSER_RETRY_DELAY:-10}"; targets="$(get_update_targets "$RECORD_PROJECT_PATH" "$RECORD_PHP_VERSION" "$current")"; }; then
        echo "[ERROR] Composer could not list the available versions (network?)."
        return 1
    fi

    IFS='|' read -r patch minor major <<< "$targets"

    if [[ -z "$patch" && -z "$minor" ]]; then
        echo "[OK] Drupal $current is the newest release of Drupal ${current%%.*}."
        echo "     For the next major: ./install.sh --upgrade $machine_name --dry-run"
        return 0
    fi

    UPDATE_TARGET=""
    choose_update_target "$patch" "$minor" || { echo "Update cancelled."; return 1; }

    check_target_compatibility "$UPDATE_TARGET" "$RECORD_PHP_VERSION" "$RECORD_DATABASE_ENGINE" || return 1

    if is_composer_lock_outdated "$RECORD_PROJECT_PATH"; then
        explain_outdated_lock || return 1
    fi

    with_args=()
    for package in "${UPDATE_WITH_PACKAGES[@]}"; do
        with_args+=(--with "$package:$UPDATE_TARGET")
    done

    UPDATE_EXTRA_ARGS=()
    UPDATE_ACCEPTED_ADVISORIES=""

    if ! dry_output="$(run_project_composer "$RECORD_PROJECT_PATH" "$RECORD_PHP_VERSION" \
            update "${UPDATE_WITH_PACKAGES[@]}" "${with_args[@]}" --with-all-dependencies --dry-run 2>&1)"; then
        blocked="$(get_blocking_advisories "$dry_output")"

        if [[ -n "$blocked" ]]; then
            explain_blocking_advisories "$blocked" || return 1
            UPDATE_EXTRA_ARGS=(--no-security-blocking)
            UPDATE_ACCEPTED_ADVISORIES="$(printf '%s\n' "$blocked" | paste -sd ';' -)"
            dry_output="$(run_project_composer "$RECORD_PROJECT_PATH" "$RECORD_PHP_VERSION" \
                update "${UPDATE_WITH_PACKAGES[@]}" "${with_args[@]}" --with-all-dependencies --dry-run \
                "${UPDATE_EXTRA_ARGS[@]}" 2>&1)" || blocked=""
        fi

        if [[ -z "$blocked" ]]; then
            echo "[BLOCKED] Composer cannot update to $UPDATE_TARGET with the current composer.json:"
            printf '%s\n' "$dry_output" | summarize_composer_problem | sed 's/^/  /'
            echo "  Nothing was changed."
            return 1
        fi
    fi

    log_line "Dry run for $UPDATE_TARGET:"$'\n'"$dry_output"

    echo
    echo "======================================"
    echo "  Update project: $machine_name"
    echo "======================================"
    echo
    echo "Drupal core:  $current -> $UPDATE_TARGET"
    security_status=0
    check_core_security "$RECORD_PROJECT_PATH" "$RECORD_PHP_VERSION" || security_status=$?

    case "$security_status" in
        0)
            if [[ -n "$UPDATE_ACCEPTED_ADVISORIES" ]]; then
                echo "              Security: $current has a published security advisory. $UPDATE_TARGET fixes"
                echo "              part of it, but still has advisories (see [SECURITY] above)."
            else
                echo "              Security: $current has a published security advisory; this update is needed."
            fi
            ;;
        1) echo "              Security: no known advisory for $current." ;;
        *) echo "              Security: could not be checked (composer audit failed; network?)." ;;
    esac
    echo "PHP $RECORD_PHP_VERSION:      supported by $(echo "$UPDATE_TARGET" | cut -d. -f1,2)"
    echo "Packages:     $(describe_lock_operations "$dry_output")"
    UPDATE_NEW_PACKAGES="$(get_new_packages "$dry_output")"
    if [[ -n "$UPDATE_NEW_PACKAGES" ]]; then
        echo "New:          $(paste -sd ',' - <<< "$UPDATE_NEW_PACKAGES" | sed 's/,/, /g') (from composer.json)"
    fi
    print_pending_database_updates
    if [[ -n "$UPDATE_ACCEPTED_ADVISORIES" ]]; then
        echo "Advisories:   accepted for this update (see [SECURITY] above)"
    fi
    echo "composer.json is not changed (the version is fixed with --with)."
    echo
    echo "Steps: backup -> maintenance mode -> composer -> drush updatedb -> cache -> checks"
    echo "On failure: code and database are restored automatically."

    if [[ "$REMOVE_DRY_RUN" -eq 1 ]]; then
        echo
        echo "[DRY RUN] Nothing was changed."
        return 0
    fi

    errors_before="$(get_project_requirement_errors)" || errors_before=""
    log_before="$(get_last_log_error_id)"
    remember_config_differences

    if ! confirm_update "$machine_name"; then
        echo "Name does not match. Update cancelled; nothing was changed."
        return 1
    fi

    # All sudo work (the database backup) happens before Composer, which
    # clears the cached sudo password when it starts. SQLite needs none.
    if [[ "$RECORD_DATABASE_ENGINE" != "sqlite" ]]; then
        require_sudo || return 1
    fi
    create_update_backup "$machine_name" || return 1

    local status=0

    # From here on the project changes: Ctrl+C restores it first.
    trap 'interrupt_update' INT TERM
    perform_update || status=$?
    trap - INT TERM

    return "$status"
}

# The changing part of --update. Uses the variables of run_update_project.
perform_update() {
    UPDATE_DATABASE_CHANGED=0
    make_sites_default_writable
    create_code_snapshot

    echo
    set_maintenance_mode 1 && echo "[OK] Maintenance mode on"

    if ! run_logged_retrying_network "Updating Drupal core to $UPDATE_TARGET" - \
            run_project_composer "$RECORD_PROJECT_PATH" "$RECORD_PHP_VERSION" \
            update "${UPDATE_WITH_PACKAGES[@]}" "${with_args[@]}" --with-all-dependencies "${UPDATE_EXTRA_ARGS[@]}"; then
        rollback_update
        return 1
    fi

    UPDATE_DATABASE_CHANGED=1

    if ! run_logged "Updating the database (drush updatedb)" \
            run_project_drush "$RECORD_PROJECT_PATH" "$RECORD_PHP_VERSION" updatedb --yes ||
       ! run_logged "Rebuilding caches" \
            run_project_drush "$RECORD_PROJECT_PATH" "$RECORD_PHP_VERSION" cache:rebuild; then
        rollback_update
        return 1
    fi

    set_maintenance_mode 0 && echo "[OK] Maintenance mode off"

    if ! verify_updated_site "$web_root"; then
        rollback_update
        return 1
    fi

    report_update_results "$errors_before" "$log_before"

    update_record_version "$record" "$UPDATE_TARGET" || true

    if [[ -n "$UPDATE_ACCEPTED_ADVISORIES" ]]; then
        set_project_field "$record" accepted_advisories "$(date +%F) $UPDATE_TARGET: $UPDATE_ACCEPTED_ADVISORIES" || true
        echo "[NOTE] Installed with accepted security advisories; the registry notes them."
    else
        # Advisories accepted for an older version no longer apply.
        remove_project_field "$record" accepted_advisories || true
    fi

    # A note of an earlier --restore describes a state that is gone now.
    remove_project_field "$record" restored_from || true

    remove_code_snapshot
    restore_sites_default_mode

    print_update_done "$machine_name" "$current"

    if [[ -n "$UPDATE_NEW_PACKAGES" ]]; then
        echo "Also installed (from composer.json): $(paste -sd ',' - <<< "$UPDATE_NEW_PACKAGES" | sed 's/,/, /g')"
    fi

    echo "Backup (keep it until you are sure): $UPDATE_BACKUP_DIR"
    echo "Back to Drupal $current later: ./install.sh --restore $machine_name $UPDATE_BACKUP_DIR"
    report_config_after_update
    print_git_commit_hint "Drupal core $UPDATE_TARGET"
}

# Projects in git: nothing is committed by the installer. Shows what
# changed (composer files, scaffold files such as web/index.php, new
# folders) and the commit; the next --update or --upgrade refuses
# uncommitted composer files.
print_git_commit_hint() {
    local message="$1"
    local changed
    local own
    local count
    local line
    local path
    local answer
    local others=0
    local -a paths=()
    local -a words=()

    [[ -d "$RECORD_PROJECT_PATH/.git" ]] || return 0

    changed="$(project_git_status)" || return 0
    [[ -n "$changed" ]] || return 0

    # Only what this run changed: the developer's own untracked or
    # modified files (notes, exports) stay out of the commit.
    own="$changed"

    if [[ "$GIT_STATUS_CAPTURED" -eq 1 ]]; then
        own="$(grep -vxF -f <(printf '%s\n' "$GIT_STATUS_BEFORE") <<< "$changed" || true)"
        [[ -n "$GIT_STATUS_BEFORE" ]] && others=1
    fi

    [[ -n "$own" ]] || return 0

    if grep -qxF '?? recipes/' <<< "$own" &&
       ! grep -qxE '/?recipes/?' "$RECORD_PROJECT_PATH/.gitignore" 2>/dev/null; then
        echo
        echo "recipes/ is written by Composer (like vendor/), so it usually stays out of git."

        if read -r -p "Add /recipes/ to .gitignore? [y/N]: " answer && [[ "$answer" =~ ^[Yy]$ ]] &&
           printf '/recipes/\n' | run_as_project_user "$PROJECT_USER" tee -a "$RECORD_PROJECT_PATH/.gitignore" > /dev/null; then
            echo "[OK] /recipes/ added to .gitignore"
            changed="$(project_git_status)" || changed=""
            own="$(grep -vxF -f <(printf '%s\n' "$GIT_STATUS_BEFORE") <<< "$changed" || true)"
        else
            echo "  Kept as it is (later: echo '/recipes/' >> .gitignore)."
        fi
    fi

    count="$(grep -c . <<< "$own")"

    echo
    echo "Changed in git by this run ($count; composer files, and the files Drupal's"
    echo "scaffold writes such as web/index.php and web/.htaccess):"
    head -n 15 <<< "$own" | sed 's/^/  /'
    [[ "$count" -gt 15 ]] && echo "  ... ($((count - 15)) more: git status)"

    if [[ "$others" -eq 1 ]]; then
        echo "Other changes in the folder were there before this run; they are left out."
    fi

    while IFS= read -r line; do
        path="${line:3}"
        [[ "$path" == *" -> "* ]] && path="${path##* -> }"
        [[ -n "$path" ]] && paths+=("$path")
    done <<< "$own"

    # Many files: their top folders (git add -A -- web composer.json ...),
    # but only folders without changes of before this run: git add of such
    # a folder would take the developer's own files in it too.
    if [[ "${#paths[@]}" -gt 20 ]]; then
        mapfile -t paths < <(collapse_commit_paths "${paths[@]}")
    fi

    for path in "${paths[@]}"; do
        if [[ "$path" == \"* ]]; then
            words+=("$path")
        else
            words+=("$(printf '%q' "$path")")
        fi
    done

    if [[ -n "${2:-}" ]]; then
        printf '%s\n' "$2"
    else
        echo "Review it, then commit once the site works (the next --update or"
        echo "--upgrade waits for that, so changes never mix):"
    fi

    echo "  cd $RECORD_PROJECT_PATH && git add -A -- ${words[*]} && git commit -m \"$message\""
}

# The paths for the commit line, with folders of only this run's changes
# shortened to the top folder. Files in a top folder that had changes
# before the run (GIT_STATUS_BEFORE) stay listed one by one.
collapse_commit_paths() {
    local -A mixed=()
    local line
    local path
    local top

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        path="${line:3}"

        for path in "${path%% -> *}" "${path##* -> }"; do
            path="${path#\"}"
            [[ "$path" == */* ]] && mixed["${path%%/*}"]=1
            mixed["${path%/}"]=1
        done
    done <<< "$GIT_STATUS_BEFORE"

    for path in "$@"; do
        top="${path#\"}"
        top="${top%%/*}"

        if [[ "$path" == */* && -z "${mixed[$top]:-}" ]]; then
            printf '%s\n' "$top"
        else
            printf '%s\n' "$path"
        fi
    done | LC_ALL=C sort -u
}

# git status of the project, as the project user.
project_git_status() {
    run_as_project_user "$PROJECT_USER" git -C "$RECORD_PROJECT_PATH" status --porcelain 2>/dev/null
}

# Before a run changes anything: what git shows already, so that the
# commit line at the end names only what the run changed.
remember_git_status() {
    GIT_STATUS_CAPTURED=0
    GIT_STATUS_BEFORE=""
    [[ -d "$RECORD_PROJECT_PATH/.git" ]] || return 0

    if GIT_STATUS_BEFORE="$(project_git_status)"; then
        GIT_STATUS_CAPTURED=1
    fi
}

# The highest id of an error in the Drupal log (empty without dblog), so
# that errors logged during the update can be told apart from old ones.
get_last_log_error_id() {
    local json

    json="$(run_project_drush "$RECORD_PROJECT_PATH" "$RECORD_PHP_VERSION" \
        watchdog:show --severity=Error --count=1 --format=json 2>/dev/null)" || return 0
    [[ -n "$json" ]] || return 0

    # Single quotes: PHP code, not shell code.
    # shellcheck disable=SC2016
    printf '%s' "$json" | "php${RECORD_PHP_VERSION}" -r '
$d = json_decode(stream_get_contents(STDIN), true);
if (!is_array($d)) { exit(0); }
$max = 0;
foreach ($d as $k => $row) { $max = max($max, (int) ($row["wid"] ?? $k)); }
echo $max, "\n";
' 2>/dev/null || true
}

# Errors Drupal logged after id $1 (first 5): only what the update brought,
# not the old ones.
# The configuration export folder (config_sync_directory) of the site, as
# an absolute path; empty when there is none.
get_config_sync_dir() {
    # Single quotes: PHP code for Drush, not shell code.
    # shellcheck disable=SC2016
    run_project_drush "$RECORD_PROJECT_PATH" "$RECORD_PHP_VERSION" php:eval '
$d = (string) \Drupal\Core\Site\Settings::get("config_sync_directory", "");
if ($d !== "" && $d[0] !== "/") { $d = \Drupal::root() . "/" . $d; }
echo $d !== "" ? (realpath($d) ?: "") : "";
' 2>/dev/null
}

# The configuration items in which the export folder $1 and the database
# differ (drush config:status), one "name (state)" per line, sorted.
# Returns 1 when there is no export to compare with (no folder, or no
# .yml files in it).
list_config_differences() {
    local sync_dir="$1"
    local json

    [[ -n "$sync_dir" && -d "$sync_dir" ]] || return 1
    [[ -n "$(find "$sync_dir" -maxdepth 1 -name '*.yml' -print -quit 2>/dev/null)" ]] || return 1

    json="$(run_project_drush "$RECORD_PROJECT_PATH" "$RECORD_PHP_VERSION" \
        config:status --format=json 2>/dev/null)" || json=""

    # Single quotes: PHP code, not shell code.
    # shellcheck disable=SC2016
    printf '%s' "$json" | "php${RECORD_PHP_VERSION}" -r '
$d = json_decode(stream_get_contents(STDIN), true);
if (!is_array($d)) { exit(0); }
foreach ($d as $key => $row) {
    $name = is_array($row) && isset($row["name"]) ? $row["name"] : $key;
    $state = is_array($row) && isset($row["state"]) ? $row["state"] : "";
    echo $name, $state !== "" ? " ($state)" : "", "\n";
}
' 2>/dev/null | LC_ALL=C sort -u
}

# Their number (0 when the list is empty).
count_config_differences() {
    local list

    list="$(list_config_differences "$1")" || return 1
    grep -c . <<< "$list" || true
}

# Before the run: which items differ already, so that afterwards only the
# ones this run brought are put down to drush updatedb.
remember_config_differences() {
    UPDATE_CONFIG_BEFORE=""
    UPDATE_CONFIG_BEFORE_KNOWN=0

    if UPDATE_CONFIG_BEFORE="$(list_config_differences "$(get_config_sync_dir 2>/dev/null)")"; then
        UPDATE_CONFIG_BEFORE_KNOWN=1
    fi
}

# After an update or upgrade the database is the right one: drush
# updatedb changes configuration. The export folder is the older one, so
# it is exported (and "drush config:import" before that would undo the
# changes of updatedb).
report_config_after_update() {
    local sync_dir
    local count
    local rel

    sync_dir="$(get_config_sync_dir)" || sync_dir=""

    if ! count="$(count_config_differences "$sync_dir")"; then
        echo "If the project keeps configuration in git, export it now:"
        echo "  $(get_project_drush_hint) config:export   (then review and commit the changes)"
        return 0
    fi

    rel="${sync_dir#"$RECORD_PROJECT_PATH/"}"

    if [[ "$count" -eq 0 ]]; then
        echo "[OK] The configuration export ($rel) matches the database"
        return 0
    fi

    local after
    local new_items=""
    local new_count
    local old_count=0

    after="$(list_config_differences "$sync_dir")" || after=""

    if [[ "$UPDATE_CONFIG_BEFORE_KNOWN" -eq 1 ]]; then
        new_items="$(grep -vxF -f <(printf '%s\n' "$UPDATE_CONFIG_BEFORE") <<< "$after" || true)"
        [[ -n "$UPDATE_CONFIG_BEFORE" ]] && old_count="$(grep -c . <<< "$UPDATE_CONFIG_BEFORE")"
    else
        new_items="$after"
    fi

    new_count="$(grep -c . <<< "$new_items" || true)"

    if [[ "$new_count" -eq 0 ]]; then
        echo "[INFO] The configuration export ($rel) differs from the database in $count item(s),"
        echo "       the same ones as before this run: the export was older than the database"
        echo "       already, not because of drush updatedb. Nothing new to export for this run;"
        echo "       $(get_project_drush_hint) config:status lists them, you decide what to keep."
        return 0
    fi

    echo "[INFO] The configuration export ($rel) differs from the database in $count item(s):"

    if [[ "$UPDATE_CONFIG_BEFORE_KNOWN" -eq 1 ]]; then
        echo "       $new_count new after this run:"
        head -n 10 <<< "$new_items" | sed 's/^/         - /'
        [[ "$new_count" -gt 10 ]] && echo "         ... ($((new_count - 10)) more: $(get_project_drush_hint) config:status)"
        [[ "$old_count" -gt 0 ]] && echo "       $old_count differed before this run already (the export was older than the database)."
    fi

    echo "       drush updatedb changed configuration. Export it, review, commit:"
    echo "         $(get_project_drush_hint) config:export"
    echo "       Not \"drush config:import\" before that: it would undo those changes."
}

# Database updates that are pending already, before the update (custom
# or contrib code changed without "drush updatedb"). drush updatedb runs
# them too: "module 10001, module 10002". Empty when there are none.
get_pending_database_updates() {
    local json

    json="$(run_project_drush "$RECORD_PROJECT_PATH" "$RECORD_PHP_VERSION" \
        updatedb:status --format=json 2>/dev/null)" || return 0
    [[ -n "$json" ]] || return 0

    # Single quotes: PHP code, not shell code.
    # shellcheck disable=SC2016
    printf '%s' "$json" | "php${RECORD_PHP_VERSION}" -r '
$d = json_decode(stream_get_contents(STDIN), true);
if (!is_array($d)) { exit(0); }
$out = [];
foreach ($d as $k => $row) {
    if (!is_array($row)) { continue; }
    $out[] = trim(($row["module"] ?? "") . " " . ($row["update_id"] ?? $k));
}
echo implode(", ", array_slice($out, 0, 8)), count($out) > 8 ? ", ..." : "";
' 2>/dev/null || true
}

# A plan line about them, when there are any.
print_pending_database_updates() {
    local pending

    pending="$(get_pending_database_updates)"
    [[ -n "$pending" ]] || return 0

    echo "Pending:      $pending"
    echo "              (database updates that wait already; drush updatedb runs them too)"
}

# Packages the update adds that are not there yet (for example a module
# required in composer.json without "composer update"): from the dry run.
get_new_packages() {
    grep -oE '^[[:space:]]*- Locking [^[:space:]]+ \([^)]*\)' <<< "$1" |
        sed -E 's/^[[:space:]]*- Locking ([^[:space:]]+) \(([^)]*)\)/\1 \2/' | head -n 8
}

# What went wrong after a successful update or upgrade; the site works,
# but these need attention. Filled by report_update_results.
UPDATE_PROBLEMS=()

# Enabled modules and themes whose .info.yml does not allow the installed
# Drupal core: "type|name|path" per line. Their pages usually fail.
get_incompatible_extensions() {
    # Single quotes: PHP code for Drush, not shell code.
    # shellcheck disable=SC2016
    run_project_drush "$RECORD_PROJECT_PATH" "$RECORD_PHP_VERSION" php:eval '
$lists = ["module" => \Drupal::service("extension.list.module"), "theme" => \Drupal::service("extension.list.theme")];
$installed = [
  "module" => array_keys(\Drupal::moduleHandler()->getModuleList()),
  "theme" => array_keys(\Drupal::service("theme_handler")->listInfo()),
];
foreach ($lists as $type => $list) {
  foreach ($installed[$type] as $name) {
    $info = $list->getExtensionInfo($name);
    if (!empty($info["core_incompatible"])) { echo $type, "|", $name, "|", $list->getPath($name), "\n"; }
  }
}
' 2>/dev/null
}

# After the update: new errors of the status report and of the Drupal
# log, and modules or themes that no longer fit the new core.
report_update_results() {
    local errors_before="$1"
    local log_before="$2"
    local errors_after
    local new_errors
    local incompatible
    local type
    local name
    local path

    UPDATE_PROBLEMS=()

    errors_after="$(get_project_requirement_errors)" || errors_after=""
    new_errors="$(comm -13 <(printf '%s\n' "$errors_before" | sort -u) <(printf '%s\n' "$errors_after" | sort -u) | grep . || true)"

    if [[ -n "$new_errors" ]]; then
        echo "[WARNING] New errors in the Drupal status report:"
        printf '%s\n' "$new_errors" | sed 's/^/            - /'
        UPDATE_PROBLEMS+=("new errors in the status report: $(paste -sd ',' - <<< "$new_errors" | sed 's/,/, /g')")
    else
        echo "[OK] No new errors in the Drupal status report"
    fi

    incompatible="$(get_incompatible_extensions | grep '^[a-z]*|' || true)"

    if [[ -n "$incompatible" ]]; then
        echo "[WARNING] Enabled, but not compatible with Drupal $UPDATE_TARGET (their pages will"
        echo "          likely fail with an error 500):"

        while IFS='|' read -r type name path; do
            echo "            - $type $name ($path)"
            UPDATE_PROBLEMS+=("$type $name is not compatible with Drupal $UPDATE_TARGET")
        done <<< "$incompatible"

        if [[ "$UPDATE_KIND" == "upgrade" ]]; then
            echo "          Upgrade Status listed what to change in custom code (see above, or the"
            echo "          log). Fix the code, then: $(get_project_drush_hint) cache:rebuild"
        else
            echo "          Fix core_version_requirement in their .info.yml (custom code) or update"
            echo "          them with Composer (contrib), then: $(get_project_drush_hint) cache:rebuild"
        fi
    fi

    report_new_log_errors "$log_before"
}

# The last line: [DONE], or [DONE WITH PROBLEMS] and what they are.
print_update_done() {
    local machine_name="$1"
    local current="$2"

    echo

    if [[ "${#UPDATE_PROBLEMS[@]}" -eq 0 ]]; then
        echo "[DONE] $machine_name: Drupal $current -> $UPDATE_TARGET"
        return 0
    fi

    echo "[DONE WITH PROBLEMS] $machine_name: Drupal $current -> $UPDATE_TARGET"
    printf '  - %s\n' "${UPDATE_PROBLEMS[@]}"
    echo "The $UPDATE_KIND is installed, but check these before you work on the site."
}

report_new_log_errors() {
    local since="$1"
    local json
    local found

    [[ -n "$since" ]] || return 0

    json="$(run_project_drush "$RECORD_PROJECT_PATH" "$RECORD_PHP_VERSION" \
        watchdog:show --severity=Error --count=50 --format=json 2>/dev/null)" || return 0

    # Single quotes: PHP code, not shell code.
    # shellcheck disable=SC2016
    found="$(printf '%s' "$json" | "php${RECORD_PHP_VERSION}" -r '
$d = json_decode(stream_get_contents(STDIN), true) ?: [];
$n = 0;
foreach ($d as $k => $row) {
    if ((int) ($row["wid"] ?? $k) <= (int) $argv[1]) { continue; }
    if ($n++ >= 5) { break; }
    echo strip_tags((string) ($row["type"] ?? "")), ": ", mb_substr(preg_replace("/\s+/", " ", strip_tags((string) ($row["message"] ?? ""))), 0, 160), "\n";
}
' "$since" 2>/dev/null)" || return 0

    if [[ -n "$found" ]]; then
        UPDATE_PROBLEMS+=("new errors in the Drupal log")
        echo "[WARNING] Drupal logged new errors during the ${UPDATE_KIND}:"
        printf '%s\n' "$found" | sed 's/^/            - /'
        echo "          Details: drush watchdog:show --severity=Error"
    else
        echo "[OK] No new errors in the Drupal log (older ones are not counted)"
    fi
}

# "Lock file operations: 0 installs, 5 updates, 0 removals" from the
# Composer dry run, as "5 updated, 0 new, 0 removed".
describe_lock_operations() {
    local line

    line="$(grep -oE 'Lock file operations: [0-9]+ installs?, [0-9]+ updates?, [0-9]+ removals?' <<< "$1" | head -n 1)" || true

    if [[ "$line" =~ ([0-9]+)\ installs?,\ ([0-9]+)\ updates?,\ ([0-9]+)\ removals? ]]; then
        echo "${BASH_REMATCH[2]} updated, ${BASH_REMATCH[1]} new, ${BASH_REMATCH[3]} removed"
    else
        echo "see the log for the list"
    fi
}

verify_updated_site() {
    local web_root="$1"
    local version
    local headers

    version="$(get_drupal_version_in "$web_root" 2>/dev/null)" || version=""

    if [[ "$version" != "$UPDATE_TARGET" ]]; then
        echo "[ERROR] Drupal reports version '$version' instead of $UPDATE_TARGET."
        return 1
    fi

    if [[ "$(run_project_drush "$RECORD_PROJECT_PATH" "$RECORD_PHP_VERSION" status --field=bootstrap 2>/dev/null)" != *"Successful"* ]]; then
        echo "[ERROR] Drush cannot bootstrap the updated site."
        return 1
    fi

    if [[ -n "$RECORD_URL" ]] && command -v curl > /dev/null; then
        headers="$(get_site_headers 4 "$RECORD_URL")"

        if ! grep -qi '^x-generator: drupal' <<< "$headers"; then
            echo "[ERROR] $RECORD_URL does not answer as a Drupal site: $(describe_site_answer "$headers")"
            return 1
        fi
    fi

    echo "[OK] Drupal $UPDATE_TARGET is running"
}

# Error-level items of the status report, one title per line.
get_project_requirement_errors() {
    local json

    json="$(run_project_drush "$RECORD_PROJECT_PATH" "$RECORD_PHP_VERSION" \
        core:requirements --severity=2 --format=json 2>/dev/null)" || return 1

    # Single quotes: PHP code, not shell code.
    # shellcheck disable=SC2016
    printf '%s' "$json" | "php${RECORD_PHP_VERSION}" -r '
$d = json_decode(stream_get_contents(STDIN), true);
if (!is_array($d)) { exit(1); }
foreach ($d as $i) { echo strip_tags((string) ($i["title"] ?? "?")), "\n"; }
'
}
