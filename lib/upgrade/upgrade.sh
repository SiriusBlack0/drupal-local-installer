#!/usr/bin/env bash

# ==================================================
# Major upgrade of Drupal core (--upgrade NAME), one major at a time
# (10 -> 11, later 11 -> 12).
#
# Everything that changes nothing comes first (also in --dry-run): the
# upgrade table, PHP and database, modules that left core, Upgrade Status,
# and a Composer trial run on copies of composer.json/composer.lock.
# Then, like --update: backup (database, composer files, offline copy of
# the code), maintenance mode, Composer, drush updatedb, checks; any
# failure restores code, composer.json and database.
# ==================================================

# Ctrl+C (or kill) while the project is being changed: undo, then stop.
interrupt_upgrade() {
    trap '' INT TERM
    to_console
    echo
    echo "[INTERRUPTED] Stopping the upgrade and restoring the project..."
    rollback_update
    exit 130
}

# Ctrl+C during the Composer trial: remove the copies, then stop.
interrupt_upgrade_trial() {
    trap '' INT TERM
    to_console
    remove_upgrade_composer_copy
    echo
    echo "[INTERRUPTED] Nothing was changed."
    exit 130
}

confirm_upgrade() {
    local machine_name="$1"
    local answer

    echo
    echo "Type the project name to start the upgrade."

    if ! read -r -p "Project name ($machine_name): " answer; then
        echo
        return 1
    fi

    [[ "$answer" == "$machine_name" ]]
}

confirm_upgrade_findings() {
    local answer

    echo
    read -r -p "Upgrade Status found errors in your custom code (see above). Upgrade anyway? [y/N]: " answer &&
        [[ "$answer" =~ ^[Yy]$ ]]
}

run_upgrade_project() {
    local machine_name
    local record
    local web_root
    local current
    local major
    local to_major
    local row
    local minimum
    local drush_constraint
    local upgrade_status_constraint
    local removed
    local target
    local dry_output
    local dry_status
    local blocked
    local blockers
    local errors_before=""
    local log_before=""

    # Read in lib/update/ (restore, backup and advisories messages).
    # shellcheck disable=SC2034
    UPDATE_KIND="upgrade"
    UPGRADE_LENIENT=()
    UPGRADE_NEW_PLUGINS=()
    UPGRADE_PLUGIN_DECISION=""
    UPDATE_EXTRA_ARGS=()
    UPDATE_ACCEPTED_ADVISORIES=""
    # shellcheck disable=SC2034
    UPDATE_ALTERNATIVE=""

    check_core_change_project "$1" || return 1

    major="${current%%.*}"
    to_major=$((major + 1))

    if ! row="$(get_upgrade_row "$major")"; then
        echo "[OK] Upgrades from Drupal $major are not in config/upgrades.conf (yet)."
        return 0
    fi

    IFS='|' read -r _ _ minimum drush_constraint upgrade_status_constraint removed <<< "$row"

    echo
    echo "Looking for Drupal $to_major releases of $UPDATE_CORE_PACKAGE..."

    if ! target="$(get_upgrade_target "$RECORD_PROJECT_PATH" "$RECORD_PHP_VERSION" "$to_major")" &&
       ! { sleep "${COMPOSER_RETRY_DELAY:-10}"; target="$(get_upgrade_target "$RECORD_PROJECT_PATH" "$RECORD_PHP_VERSION" "$to_major")"; }; then
        echo "[ERROR] Composer could not list the available versions (network?)."
        return 1
    fi

    if [[ -z "$target" ]]; then
        echo "[OK] There is no stable Drupal $to_major release that config/compatibility.conf"
        echo "     knows yet. Nothing to do."
        return 0
    fi

    UPDATE_TARGET="$target"

    if ! run_upgrade_prechecks "$machine_name" "$current" "$target" "$minimum" "$removed"; then
        echo
        echo "[BLOCKED] Drupal $target cannot be installed yet (see [FAILED] above). Nothing was changed."
        return 1
    fi

    run_upgrade_status_check "$to_major" "$upgrade_status_constraint" || return 1

    prepare_upgrade_requirements "$target" "$drush_constraint"

    echo
    printf 'Trying the upgrade with Composer (on a copy of composer.json) ... '
    # Ctrl+C here: the copies go, nothing else changed.
    trap 'interrupt_upgrade_trial' INT TERM
    dry_status=0
    dry_output="$(try_upgrade_with_composer)" || dry_status=$?

    if [[ "$dry_status" -ne 0 ]]; then
        echo "not possible yet"
        blocked="$(get_blocking_advisories "$dry_output")"

        if [[ -n "$blocked" ]]; then
            explain_blocking_advisories "$blocked" || return 1
            UPDATE_EXTRA_ARGS=(--no-security-blocking)
            UPDATE_ACCEPTED_ADVISORIES="$(printf '%s\n' "$blocked" | paste -sd ';' -)"
            dry_status=0
            dry_output="$(try_upgrade_with_composer)" || dry_status=$?
        fi
    else
        echo "OK"
    fi

    trap - INT TERM

    mapfile -t UPGRADE_NEW_PLUGINS < <(sed -n 's/^DLI-NEW-PLUGIN: //p' <<< "$dry_output")
    dry_output="$(grep -v '^DLI-NEW-PLUGIN: ' <<< "$dry_output" || true)"
    log_line "Composer trial for $target:"$'\n'"$dry_output"

    if [[ "$dry_status" -ne 0 ]]; then
        blockers="$(get_upgrade_blocking_projects "$dry_output")"

        if [[ -n "$blockers" ]]; then
            if ! choose_blocking_projects_handling "$blockers" "$to_major"; then
                echo
                echo "Upgrade stopped; nothing was changed."
                return 1
            fi
        else
            echo "[BLOCKED] Composer cannot install Drupal $target with the current composer.json:"
            printf '%s\n' "$dry_output" | grep -vE '^(\./)?composer\.dli-upgrade\.json has been updated' | tail -n 12 | sed 's/^/  /'
            echo "  Nothing was changed."
            return 1
        fi
    fi

    if [[ "${#UPGRADE_NEW_PLUGINS[@]}" -gt 0 ]] && ! choose_new_plugins_handling "$to_major"; then
        echo
        echo "Upgrade stopped; nothing was changed."
        return 1
    fi

    echo
    echo "======================================"
    echo "  Upgrade project: $machine_name"
    echo "======================================"
    echo
    echo "Drupal core:   $current -> $target (major upgrade)"
    echo "PHP $RECORD_PHP_VERSION:       supported by $(echo "$target" | cut -d. -f1,2)"
    echo "composer.json: $(describe_upgrade_requirements)"
    echo "               (contrib projects are updated within their constraints)"

    if [[ "${#UPGRADE_LENIENT[@]}" -gt 0 ]]; then
        echo "Lenient:       $(printf '%s ' "${UPGRADE_LENIENT[@]}")(their drupal/core requirement is ignored;"
        echo "               Composer can check this only once the plugin is installed)"
    else
        echo "Packages:      $(describe_lock_operations "$dry_output")"
        describe_contrib_changes "$dry_output"
    fi

    if [[ -n "$UPDATE_ACCEPTED_ADVISORIES" ]]; then
        echo "Advisories:    accepted for this upgrade (see [SECURITY] above)"
    fi

    if [[ "${#UPGRADE_NEW_PLUGINS[@]}" -gt 0 ]]; then
        case "$UPGRADE_PLUGIN_DECISION" in
            true) echo "Plugins:       $(describe_new_plugins) (allowed in composer.json)" ;;
            false) echo "Plugins:       $(describe_new_plugins) (installed, plugin part switched off)" ;;
            *) echo "Plugins:       $(describe_new_plugins) (you decide in the real run)" ;;
        esac
    fi

    echo "Upgrade Status: $UPGRADE_STATUS_SUMMARY"
    echo
    echo "Steps: backup -> maintenance mode -> composer -> drush updatedb -> cache -> checks"
    echo "On failure: code, composer.json and database are restored automatically."

    if [[ "$REMOVE_DRY_RUN" -eq 1 ]]; then
        echo
        if [[ "$UPGRADE_STATUS_MODE" == "keep" ]]; then
            echo "[DRY RUN] Nothing else was changed (Upgrade Status stays installed, as you chose)."
        else
            echo "[DRY RUN] Nothing was changed."
        fi
        return 0
    fi

    if [[ "$UPGRADE_STATUS_RESULT" -eq 1 ]] && ! confirm_upgrade_findings; then
        echo "Upgrade cancelled; nothing was changed."
        return 1
    fi

    errors_before="$(get_project_requirement_errors)" || errors_before=""
    log_before="$(get_last_log_error_id)"

    if ! confirm_upgrade "$machine_name"; then
        echo "Name does not match. Upgrade cancelled; nothing was changed."
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
    trap 'interrupt_upgrade' INT TERM
    perform_upgrade || status=$?
    trap - INT TERM

    return "$status"
}

# The changing part of --upgrade. Uses the variables of run_upgrade_project.
perform_upgrade() {
    UPDATE_DATABASE_CHANGED=0
    make_sites_default_writable
    create_code_snapshot

    echo
    set_maintenance_mode 1 && echo "[OK] Maintenance mode on"

    if [[ "${#UPGRADE_LENIENT[@]}" -gt 0 ]] && ! add_lenient_plugin; then
        rollback_update
        return 1
    fi

    if ! run_logged "Writing the Drupal $to_major requirements into composer.json" \
            write_upgrade_requirements run_real_composer ||
       ! { [[ "${#UPGRADE_NEW_PLUGINS[@]}" -eq 0 ]] ||
           run_logged "Writing your decision about the new Composer plugins into composer.json" \
            write_plugin_decisions; } ||
       ! run_logged_retrying_network "Upgrading Drupal core to $UPDATE_TARGET" - \
            run_real_composer update "${UPGRADE_UPDATE_PACKAGES[@]}" "${UPGRADE_WITH_ARGS[@]}" \
            --with-all-dependencies "${UPDATE_EXTRA_ARGS[@]}"; then
        if [[ "${#UPGRADE_LENIENT[@]}" -gt 0 ]]; then
            echo "[INFO] Composer found no solution even with the lenient plugin (see above)."
        fi
        explain_blocked_plugin_failure
        rollback_update
        return 1
    fi

    # Read in lib/update/update.sh (rollback_update).
    # shellcheck disable=SC2034
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
    set_project_field "$record" upgraded_from "$(date +%F) $current" || true

    if [[ "${#UPGRADE_LENIENT[@]}" -gt 0 ]]; then
        set_project_field "$record" lenient_packages "$(printf '%s ' "${UPGRADE_LENIENT[@]}" | sed 's/ $//')" || true
    fi

    if [[ -n "$UPDATE_ACCEPTED_ADVISORIES" ]]; then
        set_project_field "$record" accepted_advisories "$(date +%F) $UPDATE_TARGET: $UPDATE_ACCEPTED_ADVISORIES" || true
        echo "[NOTE] Installed with accepted security advisories; the registry notes them."
    else
        # Advisories accepted for an older version no longer apply.
        remove_project_field "$record" accepted_advisories || true
    fi

    remove_code_snapshot
    restore_sites_default_mode

    print_update_done "$machine_name" "$current"
    echo "Backup (keep it until you are sure): $UPDATE_BACKUP_DIR"
    echo
    echo "Check it yourself (the installer only opened the front page):"
    echo "  - log in, open the pages your modules provide, submit a form"
    echo "  - export the configuration if you keep it in git: ./drush config:export"
    echo "    (review, then commit)"

    if [[ "${#UPGRADE_LENIENT[@]}" -gt 0 ]]; then
        echo "  - $(printf '%s ' "${UPGRADE_LENIENT[@]}")run without a release for Drupal $to_major (lenient):"
        echo "    test their pages; remove them from extra.drupal-lenient.allowed-list once"
        echo "    real releases exist"
    fi

    if [[ "$UPGRADE_STATUS_MODE" == "keep" ]]; then
        echo "  - Upgrade Status is still installed; remove it when you no longer need it:"
        echo "    ./drush pm:uninstall upgrade_status && composer remove --dev drupal/upgrade_status"
    fi

    echo "Back to Drupal $current later (the site's changes since now are lost then):"
    echo "  ./install.sh --restore $machine_name $UPDATE_BACKUP_DIR"
    print_git_commit_hint "Drupal core $UPDATE_TARGET (upgrade from $current)"
}
