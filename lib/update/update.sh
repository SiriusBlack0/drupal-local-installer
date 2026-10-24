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
# The target that was not chosen (patch or minor), for advice.
UPDATE_ALTERNATIVE=""
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
    local failed=0

    echo
    echo "Restoring the project as it was before the ${UPDATE_KIND}..."

    if ! cp --preserve=timestamps -- "$UPDATE_BACKUP_DIR/composer.json" "$UPDATE_BACKUP_DIR/composer.lock" "$RECORD_PROJECT_PATH/"; then
        echo "[FAILED] composer.json and composer.lock could not be copied back"
        failed=1
    elif restore_code_snapshot; then
        echo "[OK] Code restored (from the offline copy)"
    elif { [[ "$UPDATE_KIND" == "update" ]] || remove_project_vendor; } &&
         run_logged "Restoring the previous code (composer install)" \
            run_project_composer "$RECORD_PROJECT_PATH" "$RECORD_PHP_VERSION" install; then
        echo "[OK] Code restored"
    else
        echo "[FAILED] Code"
        failed=1
    fi

    if [[ "$UPDATE_DATABASE_CHANGED" -eq 1 ]]; then
        if [[ "$RECORD_DATABASE_ENGINE" != "sqlite" ]]; then
            echo "The database is restored with sudo (it may ask for your password again)."
        fi

        if restore_database_from_backup; then
            echo "[OK] Database restored"
        else
            echo "[FAILED] Database"
            failed=1
        fi
    fi

    set_maintenance_mode 0 || true
    run_project_drush "$RECORD_PROJECT_PATH" "$RECORD_PHP_VERSION" cache:rebuild > /dev/null 2>&1 || true

    if [[ "$failed" -eq 0 && -n "$UPDATE_PREVIOUS_VERSION" &&
          "$(get_drupal_version_in "$UPDATE_WEB_ROOT" 2>/dev/null)" != "$UPDATE_PREVIOUS_VERSION" ]]; then
        echo "[FAILED] Drupal does not report version $UPDATE_PREVIOUS_VERSION again."
        failed=1
    fi

    restore_sites_default_mode

    if [[ "$failed" -eq 0 ]]; then
        remove_code_snapshot
        echo "[OK] The project is back to its previous version."
        return 0
    fi

    echo
    [[ -n "$UPDATE_SNAPSHOT_DIR" ]] && echo "Offline copy of the old code (kept): $UPDATE_SNAPSHOT_DIR/code"
    echo "[ERROR] Automatic restore did not complete. Restore by hand from:"
    echo "        $UPDATE_BACKUP_DIR"
    echo "  cd $RECORD_PROJECT_PATH && chmod u+w $UPDATE_WEB_ROOT/sites/default"
    echo "  cp $UPDATE_BACKUP_DIR/composer.json $UPDATE_BACKUP_DIR/composer.lock ."
    echo "  rm -rf vendor && ./composer install && chmod 555 $UPDATE_WEB_ROOT/sites/default"
    echo "  The database only after Drupal reports $UPDATE_PREVIOUS_VERSION again:"
    echo "  README.md, \"Restoring a backup by hand\"."
    return 1
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

    if [[ -n "$patch" && -z "$minor" ]]; then
        UPDATE_TARGET="$patch"
        return 0
    fi

    if [[ -z "$patch" && -n "$minor" ]]; then
        UPDATE_TARGET="$minor"
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

    if [[ -d "$RECORD_PROJECT_PATH/.git" ]] &&
       [[ -n "$(run_as_project_user "$PROJECT_USER" git -C "$RECORD_PROJECT_PATH" status --porcelain -- composer.json composer.lock 2>/dev/null)" ]]; then
        echo "[BLOCKED] composer.json or composer.lock have uncommitted changes."
        echo "          Commit or revert them first, so the update does not mix with them."
        return 1
    fi

    if is_composer_lock_outdated "$RECORD_PROJECT_PATH"; then
        echo "[BLOCKED] composer.lock does not match composer.json: composer.json was changed"
        echo "          without \"composer update\". The ${UPDATE_KIND} would install that change"
        echo "          too, and its backup could not be restored (composer install fails)."
        echo "          See what differs:  cd $RECORD_PROJECT_PATH && ./composer update --dry-run"
        echo "          Then update the package you changed (./composer update vendor/name) or"
        echo "          undo the change in composer.json, commit, and run this again."
        return 1
    fi

    if [[ "$(run_project_drush "$RECORD_PROJECT_PATH" "$RECORD_PHP_VERSION" status --field=bootstrap 2>/dev/null)" != *"Successful"* ]]; then
        echo "[BLOCKED] The site does not work right now (Drush cannot bootstrap it)."
        echo "          Fix that first: an update could not be checked afterwards."
        return 1
    fi
}

run_update_project() {
    local machine_name
    local record
    local web_root
    local current
    local targets
    local patch
    local minor
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

    IFS='|' read -r patch minor _ <<< "$targets"

    if [[ -z "$patch" && -z "$minor" ]]; then
        echo "[OK] Drupal $current is the newest release of Drupal ${current%%.*}."
        echo "     For the next major: ./install.sh --upgrade $machine_name --dry-run"
        return 0
    fi

    UPDATE_TARGET=""
    choose_update_target "$patch" "$minor" || { echo "Update cancelled."; return 1; }

    check_target_compatibility "$UPDATE_TARGET" "$RECORD_PHP_VERSION" "$RECORD_DATABASE_ENGINE" || return 1

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
            printf '%s\n' "$dry_output" | tail -n 12 | sed 's/^/  /'
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

    remove_code_snapshot
    restore_sites_default_mode

    print_update_done "$machine_name" "$current"
    echo "Backup (keep it until you are sure): $UPDATE_BACKUP_DIR"
    echo "Back to Drupal $current later: ./install.sh --restore $machine_name $UPDATE_BACKUP_DIR"
    print_git_commit_hint "Drupal core $UPDATE_TARGET"
    echo "If the project keeps configuration in git, export it now:"
    echo "  drush config:export   (then review and commit the changes)"
}

# Projects in git: nothing is committed by the installer. Shows what
# changed (composer files, scaffold files such as web/index.php, new
# folders) and the commit; the next --update or --upgrade refuses
# uncommitted composer files.
print_git_commit_hint() {
    local message="$1"
    local changed
    local count

    [[ -d "$RECORD_PROJECT_PATH/.git" ]] || return 0

    changed="$(run_as_project_user "$PROJECT_USER" git -C "$RECORD_PROJECT_PATH" status --porcelain 2>/dev/null)" || return 0
    [[ -n "$changed" ]] || return 0
    count="$(grep -c . <<< "$changed")"

    echo
    echo "Changed in git ($count; composer files, and the files Drupal's scaffold"
    echo "writes such as web/index.php and web/.htaccess):"
    head -n 15 <<< "$changed" | sed 's/^/  /'
    [[ "$count" -gt 15 ]] && echo "  ... ($((count - 15)) more: git status)"

    if grep -qxF '?? recipes/' <<< "$changed"; then
        echo "recipes/ is written by Composer (like vendor/): if .gitignore leaves out"
        echo "vendor/, add it there too:  echo '/recipes/' >> $RECORD_PROJECT_PATH/.gitignore"
    fi

    echo "Review it, then commit once the site works (the next --update or"
    echo "--upgrade waits for that, so changes never mix):"
    echo "  cd $RECORD_PROJECT_PATH && git add -A && git commit -m \"$message\""
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
            echo "          log). Fix the code, then: ./drush cache:rebuild"
        else
            echo "          Fix core_version_requirement in their .info.yml (custom code) or update"
            echo "          them with Composer (contrib), then: ./drush cache:rebuild"
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
