#!/usr/bin/env bash

# ==================================================
# Updating Drupal core (--check-updates, --update NAME)
#
# Patch (10.6.16 -> 10.6.18) and minor (10.6 -> 10.7) updates of Drupal
# core only. Major upgrades are not automated.
#
# The target version is fixed with "composer update --with", so
# composer.json is never changed. Before anything changes, the database
# and composer.json/composer.lock are backed up; if any step fails, code
# and database are restored automatically.
# ==================================================

# Core packages that move together with the core version.
CORE_COMPANION_PACKAGES=(
    drupal/core-composer-scaffold
    drupal/core-project-message
    drupal/core-dev
)

UPDATE_CORE_PACKAGE=""
UPDATE_WITH_PACKAGES=()
UPDATE_BACKUP_DIR=""
UPDATE_DATABASE_BACKUP=""
UPDATE_DATABASE_OWNER=""
UPDATE_DATABASE_CHANGED=0
UPDATE_PREVIOUS_VERSION=""
UPDATE_TARGET=""
UPDATE_WEB_ROOT=""

get_composer_path() {
    command -v composer
}

# Runs Composer for the project with the project's PHP, as the developer.
run_project_composer() {
    local project_path="$1"
    local php_version="$2"
    shift 2

    run_as_project_user "$PROJECT_USER" "php${php_version}" "$(get_composer_path)" \
        --working-dir="$project_path" --no-interaction "$@"
}

# Runs the project's Drush: the ./drush launcher of projects made by the
# installer, or vendor/bin/drush with the project's PHP first in PATH.
run_project_drush() {
    local project_path="$1"
    local php_version="$2"
    shift 2
    local shim
    local status=0

    if [[ -x "$project_path/drush" && ! -d "$project_path/drush" ]]; then
        run_as_project_user "$PROJECT_USER" "$project_path/drush" "$@"
        return
    fi

    [[ -x "$project_path/vendor/bin/drush" ]] || return 127

    # Drush starts "php" from PATH: put the project's PHP first.
    shim="$(mktemp -d)"
    chmod 755 "$shim"
    ln -s "$(command -v "php${php_version}")" "$shim/php"
    (cd "$project_path" && run_as_project_user "$PROJECT_USER" \
        env PATH="$shim:$PATH" "$project_path/vendor/bin/drush" "$@") || status=$?
    rm -rf "$shim"
    return "$status"
}

# Prints the core package the project requires (drupal/core-recommended
# or drupal/core), then the companion packages it also requires.
get_core_packages() {
    local project_path="$1"
    local php_version="$2"

    # Single quotes: PHP code, not shell code.
    # shellcheck disable=SC2016
    "php${php_version}" -r '
$c = json_decode(file_get_contents($argv[1]), true);
if (!is_array($c)) { exit(1); }
$req = ($c["require"] ?? []) + ($c["require-dev"] ?? []);
if (isset($req["drupal/core-recommended"])) { echo "drupal/core-recommended\n"; }
elseif (isset($req["drupal/core"])) { echo "drupal/core\n"; }
else { exit(2); }
foreach (array_slice($argv, 2) as $p) { if (isset($req[$p])) { echo $p, "\n"; } }
' "$project_path/composer.json" "${CORE_COMPANION_PACKAGES[@]}"
}

# Prints "patch_target|minor_target" (each may be empty) from the
# versions Composer reports for the core package. Minor targets are
# limited to the minors in config/compatibility.conf, so a release the
# installer knows nothing about yet is never offered.
get_update_targets() {
    local project_path="$1"
    local php_version="$2"
    local current="$3"
    local json
    local known_minors

    known_minors="$(get_supported_drupal_minors | paste -sd, -)"
    json="$(run_project_composer "$project_path" "$php_version" \
        show --all --format=json "$UPDATE_CORE_PACKAGE" 2>/dev/null)" || return 1

    # Single quotes: PHP code, not shell code.
    # shellcheck disable=SC2016
    printf '%s' "$json" | "php${php_version}" -r '
$d = json_decode(stream_get_contents(STDIN), true);
if (!is_array($d) || !isset($d["versions"])) { exit(1); }
$cur = $argv[1];
$known = explode(",", $argv[2]);
[$maj, $min] = array_map("intval", explode(".", $cur));
$patch = ""; $minor = "";
foreach ($d["versions"] as $v) {
    if (!preg_match("/^\d+\.\d+\.\d+$/", $v) || version_compare($v, $cur, "<=")) { continue; }
    [$vmaj, $vmin] = array_map("intval", explode(".", $v));
    if ($vmaj !== $maj) { continue; }
    if ($vmin === $min) { if ($patch === "" || version_compare($v, $patch, ">")) { $patch = $v; } }
    elseif ($vmin > $min && in_array("$vmaj.$vmin", $known, true) &&
            ($minor === "" || version_compare($v, $minor, ">"))) { $minor = $v; }
}
echo $patch, "|", $minor, "\n";
' "$current" "$known_minors"
}

# Asks "composer audit" whether the installed Drupal core has a
# published security advisory (drupal.org security announcements).
# Returns 0: it has one, 1: none known, 2: could not check (network?).
has_core_security_advisory() {
    local project_path="$1"
    local php_version="$2"
    local json

    # composer audit exits non-zero when it finds advisories.
    json="$(run_project_composer "$project_path" "$php_version" \
        audit --locked --format=json 2>/dev/null)" || true

    [[ -n "$json" ]] || return 2

    # Single quotes: PHP code, not shell code.
    # shellcheck disable=SC2016
    printf '%s' "$json" | "php${php_version}" -r '
$d = json_decode(stream_get_contents(STDIN), true);
if (!is_array($d) || !array_key_exists("advisories", $d)) { exit(2); }
exit(empty($d["advisories"]["drupal/core"]) ? 1 : 0);
'
}

# Checks the target release against config/compatibility.conf.
check_target_compatibility() {
    local target="$1"
    local php_version="$2"
    local engine="$3"
    local minor
    local major="${target%%.*}"
    local minimum
    local installed

    minor="$(echo "$target" | cut -d. -f1,2)"

    if ! get_compatibility_row "$minor" > /dev/null; then
        echo "[BLOCKED] Drupal $minor is not in config/compatibility.conf yet."
        echo "          Add its requirements from drupal.org first."
        return 1
    fi

    if ! get_supported_php_versions "$minor" | grep -qxF "$php_version"; then
        echo "[BLOCKED] Drupal $minor does not support PHP $php_version."
        echo "          Supported: $(get_supported_php_versions "$minor" | tr '\n' ' ')"
        echo "          Changing the PHP version of a project is a separate, later feature."
        return 1
    fi

    case "$engine" in
        mariadb|mysql|postgresql|sqlite)
            minimum="$(get_database_minimum_version "$major" "$engine")" || return 0
            installed="$(get_installed_database_version "$engine" 2>/dev/null)" || installed=""

            if [[ -n "$installed" ]] && ! database_version_meets_minimum "$installed" "$minimum"; then
                echo "[BLOCKED] Drupal $major needs $engine $minimum or newer; this system has $installed."
                return 1
            fi
            ;;
    esac
}

# ---------------------------------------------------
# --check-updates
# ---------------------------------------------------

run_check_updates() {
    local record
    local name
    local path
    local php
    local current
    local web_root
    local targets
    local patch
    local minor
    local security
    local security_status
    local found=0
    local vulnerable=()

    echo
    echo "Checking for Drupal core updates (this asks Packagist, it may take a while)..."
    echo

    printf '%-20s %-9s %-11s %-9s %s\n' "PROJECT" "CURRENT" "PATCH" "MINOR" "SECURITY (INSTALLED VERSION)"

    for record in "$(get_registry_directory)"/*.conf; do
        [[ -f "$record" ]] || continue
        found=1

        name="$(read_project_field "$record" machine_name)"
        path="$(read_project_field "$record" project_path)"
        php="$(read_project_field "$record" php_version)"
        web_root="$(read_project_field "$record" web_root)"
        [[ -n "$web_root" ]] || web_root="$path/web"

        if [[ ! -f "$path/composer.json" || ! -f "$path/composer.lock" ]]; then
            printf '%-20s %s\n' "$name" "skipped: not a Composer project"
            continue
        fi

        if [[ -z "$php" ]] || ! command -v "php${php}" > /dev/null; then
            printf '%-20s %s\n' "$name" "skipped: PHP ${php:-version unknown} not available"
            continue
        fi

        current="$(get_drupal_version_in "$web_root" 2>/dev/null)" || current=""

        if [[ "$current" =~ ^([0-9]+)\. ]] && [[ "${BASH_REMATCH[1]}" -lt 10 ]]; then
            printf '%-20s %-9s %s\n' "$name" "$current" "end of life: not updated by the installer"
            continue
        fi

        if [[ ! "$current" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
           ! UPDATE_CORE_PACKAGE="$(get_core_packages "$path" "$php")" ||
           [[ -z "$UPDATE_CORE_PACKAGE" ]]; then
            printf '%-20s %s\n' "$name" "skipped: Drupal core version or package not found"
            continue
        fi

        # The first line is the core package; the rest are companions.
        UPDATE_CORE_PACKAGE="${UPDATE_CORE_PACKAGE%%$'\n'*}"

        if ! targets="$(get_update_targets "$path" "$php" "$current")"; then
            printf '%-20s %-9s %s\n' "$name" "$current" "could not ask Packagist"
            continue
        fi

        IFS='|' read -r patch minor <<< "$targets"

        security_status=0
        has_core_security_advisory "$path" "$php" || security_status=$?

        case "$security_status" in
            0)
                security="VULNERABLE - update now"
                vulnerable+=("$name")
                ;;
            1) security="no known issues" ;;
            *) security="not checked (composer audit failed)" ;;
        esac

        printf '%-20s %-9s %-11s %-9s %s\n' "$name" "$current" \
            "${patch:-up to date}" "${minor:--}" "$security"
    done

    if [[ "$found" -eq 0 ]]; then
        echo "No projects registered. Use --scan to register existing ones."
        return 0
    fi

    echo
    echo "PATCH: newest bug fix and security release of the same minor (recommended)."
    echo "MINOR: newest minor release this installer knows; major upgrades are not offered."
    echo "SECURITY: whether the version installed now has a published Drupal core"
    echo "          security advisory (checked with \"composer audit\")."

    if [[ "${#vulnerable[@]}" -gt 0 ]]; then
        echo
        echo "[ACTION] Installed versions with a security advisory. Update them:"
        printf '  ./install.sh --update %s\n' "${vulnerable[@]}"
    fi

    echo
    echo "Update one with: ./install.sh --update <project> (--dry-run to preview)"
}

# ---------------------------------------------------
# --update NAME
# ---------------------------------------------------

# PostgreSQL: the owner of the database, so it can be recreated as it was.
get_postgresql_database_owner() {
    # Single quotes: SQL with a psql variable, not shell code.
    # shellcheck disable=SC2016
    printf '%s\n' "SELECT pg_catalog.pg_get_userbyid(datdba) FROM pg_catalog.pg_database WHERE datname = :'db';" |
        sudo -u postgres psql -X -q -t -A -v db="$RECORD_DATABASE_NAME" -d postgres
}

# Backs up the database so that restoring it gives back exactly that
# state: tables that the update adds are removed again on restore.
# MariaDB/MySQL: the dump drops and recreates the database itself.
# PostgreSQL: the database is dropped and recreated before the dump is
# loaded. SQLite: a copy of the file (and its -wal file, if any).
dump_database_for_restore() {
    local -a status

    case "$RECORD_DATABASE_ENGINE" in
        mariadb|mysql)
            UPDATE_DATABASE_BACKUP="$UPDATE_BACKUP_DIR/database.sql.gz"
            sudo mysqldump --single-transaction --routines --triggers \
                --databases --add-drop-database -- "$RECORD_DATABASE_NAME" | gzip > "$UPDATE_DATABASE_BACKUP"
            status=("${PIPESTATUS[@]}")
            ;;
        postgresql)
            UPDATE_DATABASE_BACKUP="$UPDATE_BACKUP_DIR/database.sql.gz"
            UPDATE_DATABASE_OWNER="$(get_postgresql_database_owner)" || return 1
            is_valid_database_user "$UPDATE_DATABASE_OWNER" || [[ "$UPDATE_DATABASE_OWNER" == "postgres" ]] || return 1
            printf '%s\n' "$UPDATE_DATABASE_OWNER" > "$UPDATE_BACKUP_DIR/database.owner"
            sudo -u postgres pg_dump -- "$RECORD_DATABASE_NAME" | gzip > "$UPDATE_DATABASE_BACKUP"
            status=("${PIPESTATUS[@]}")
            ;;
        sqlite)
            UPDATE_DATABASE_BACKUP="$UPDATE_BACKUP_DIR/database.sqlite"
            [[ -f "$RECORD_SQLITE_PATH" ]] || return 1
            cp -- "$RECORD_SQLITE_PATH" "$UPDATE_DATABASE_BACKUP" || return 1

            if [[ -f "$RECORD_SQLITE_PATH-wal" ]]; then
                cp -- "$RECORD_SQLITE_PATH-wal" "$UPDATE_DATABASE_BACKUP-wal" || return 1
            fi

            status=(0 0)
            ;;
        *)
            return 1
            ;;
    esac

    [[ "${status[0]}" -eq 0 && "${status[1]}" -eq 0 && -s "$UPDATE_DATABASE_BACKUP" ]]
}

restore_database_from_backup() {
    local -a status
    local dropdb_options=(--if-exists)

    case "$RECORD_DATABASE_ENGINE" in
        mariadb|mysql)
            gunzip -c -- "$UPDATE_DATABASE_BACKUP" | sudo mysql
            status=("${PIPESTATUS[@]}")
            ;;
        postgresql)
            # --force (PostgreSQL 13+) closes connections left by PHP-FPM.
            if [[ "$(sudo -u postgres psql -X -q -t -A -d postgres -c 'SHOW server_version_num' 2>/dev/null)" -ge 130000 ]] 2>/dev/null; then
                dropdb_options+=(--force)
            fi

            sudo -u postgres dropdb "${dropdb_options[@]}" -- "$RECORD_DATABASE_NAME" &&
            sudo -u postgres createdb -O "$UPDATE_DATABASE_OWNER" -- "$RECORD_DATABASE_NAME" || return 1
            gunzip -c -- "$UPDATE_DATABASE_BACKUP" |
                sudo -u postgres psql -X -q -v ON_ERROR_STOP=1 -d "$RECORD_DATABASE_NAME" > /dev/null
            status=("${PIPESTATUS[@]}")
            ;;
        sqlite)
            rm -f -- "$RECORD_SQLITE_PATH-wal" "$RECORD_SQLITE_PATH-shm"
            cp -- "$UPDATE_DATABASE_BACKUP" "$RECORD_SQLITE_PATH" || return 1

            if [[ -f "$UPDATE_DATABASE_BACKUP-wal" ]]; then
                cp -- "$UPDATE_DATABASE_BACKUP-wal" "$RECORD_SQLITE_PATH-wal" || return 1
            fi

            status=(0 0)
            ;;
        *)
            return 1
            ;;
    esac

    [[ "${status[0]}" -eq 0 && "${status[1]}" -eq 0 ]]
}

create_update_backup() {
    local machine_name="$1"
    local old_umask
    local ok=1

    UPDATE_BACKUP_DIR="$(get_backup_base_dir)/${machine_name}-update-$(date +%Y%m%d-%H%M%S)"

    if ! run_as_project_user "$PROJECT_USER" install -d -m 0700 "$UPDATE_BACKUP_DIR"; then
        echo "[ERROR] Could not create the backup directory: $UPDATE_BACKUP_DIR"
        return 1
    fi

    old_umask="$(umask)"
    umask 077
    printf 'Backing up the database ... '

    if dump_database_for_restore; then
        echo "OK"
        printf 'Backing up composer.json and composer.lock ... '

        if cp -p -- "$RECORD_PROJECT_PATH/composer.json" "$RECORD_PROJECT_PATH/composer.lock" "$UPDATE_BACKUP_DIR/"; then
            echo "OK"
        else
            echo "FAILED"
            ok=0
        fi
    else
        echo "FAILED"
        ok=0
    fi

    umask "$old_umask"

    if [[ "$ok" -ne 1 ]]; then
        echo "[ERROR] Backup failed. Nothing was changed."
        return 1
    fi

    echo "[OK] Backup saved: $UPDATE_BACKUP_DIR"
}

set_maintenance_mode() {
    run_project_drush "$RECORD_PROJECT_PATH" "$RECORD_PHP_VERSION" \
        state:set system.maintenance_mode "$1" --input-format=integer > /dev/null 2>&1
}

# Restores code (composer.json/lock + composer install) and, when it was
# changed, the database. Prints manual steps if that fails too.
rollback_update() {
    local failed=0

    echo
    echo "Restoring the project as it was before the update..."

    if cp -p -- "$UPDATE_BACKUP_DIR/composer.json" "$UPDATE_BACKUP_DIR/composer.lock" "$RECORD_PROJECT_PATH/" &&
       run_logged "Restoring the previous code" \
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

    if [[ "$failed" -eq 0 && "$(get_drupal_version_in "$UPDATE_WEB_ROOT" 2>/dev/null)" != "$UPDATE_PREVIOUS_VERSION" ]]; then
        echo "[FAILED] Drupal does not report version $UPDATE_PREVIOUS_VERSION again."
        failed=1
    fi

    if [[ "$failed" -eq 0 ]]; then
        echo "[OK] The project is back to its previous version."
        return 0
    fi

    echo
    echo "[ERROR] Automatic restore did not complete. Restore by hand from:"
    echo "        $UPDATE_BACKUP_DIR"
    echo "  cp $UPDATE_BACKUP_DIR/composer.json $UPDATE_BACKUP_DIR/composer.lock $RECORD_PROJECT_PATH/"
    echo "  cd $RECORD_PROJECT_PATH && composer install"
    echo "  (database: see README.md, \"Updating Drupal core\")"
    return 1
}

update_record_version() {
    local record="$1"
    local version="$2"

    run_as_project_user "$PROJECT_USER" sed -i "s/^drupal_version=.*/drupal_version=$version/" "$record"
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
        echo "1) Patch update to $patch (recommended: fixes and security)"
        echo "2) Minor update to $minor"

        if ! read -r -p "Select [1-2]: " answer; then
            echo
            return 1
        fi

        case "$answer" in
            1) UPDATE_TARGET="$patch"; return 0 ;;
            2) UPDATE_TARGET="$minor"; return 0 ;;
            *) echo "Invalid selection." ;;
        esac
    done
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
    local errors_after=""
    local new_errors

    machine_name="$(get_project_machine_name "$1")"

    if [[ ! "$machine_name" =~ ^[a-z0-9_]+$ ]]; then
        echo "[ERROR] Invalid project name: '$1'"
        return 1
    fi

    record="$(get_project_record_path "$machine_name")" || return 1

    if [[ ! -f "$record" ]]; then
        echo "[ERROR] '$machine_name' is not in the registry. Register it with --scan first."
        return 1
    fi

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

    if [[ "$(run_project_drush "$RECORD_PROJECT_PATH" "$RECORD_PHP_VERSION" status --field=bootstrap 2>/dev/null)" != *"Successful"* ]]; then
        echo "[BLOCKED] The site does not work right now (Drush cannot bootstrap it)."
        echo "          Fix that first: an update could not be checked afterwards."
        return 1
    fi

    echo
    echo "Looking for updates of $UPDATE_CORE_PACKAGE $current..."

    if ! targets="$(get_update_targets "$RECORD_PROJECT_PATH" "$RECORD_PHP_VERSION" "$current")"; then
        echo "[ERROR] Composer could not list the available versions (network?)."
        return 1
    fi

    IFS='|' read -r patch minor <<< "$targets"

    if [[ -z "$patch" && -z "$minor" ]]; then
        echo "[OK] Drupal $current is the newest release of Drupal ${current%%.*}."
        echo "     Major upgrades are not automated."
        return 0
    fi

    UPDATE_TARGET=""
    choose_update_target "$patch" "$minor" || { echo "Update cancelled."; return 1; }

    check_target_compatibility "$UPDATE_TARGET" "$RECORD_PHP_VERSION" "$RECORD_DATABASE_ENGINE" || return 1

    with_args=()
    for package in "${UPDATE_WITH_PACKAGES[@]}"; do
        with_args+=(--with "$package:$UPDATE_TARGET")
    done

    if ! dry_output="$(run_project_composer "$RECORD_PROJECT_PATH" "$RECORD_PHP_VERSION" \
            update "${UPDATE_WITH_PACKAGES[@]}" "${with_args[@]}" --with-all-dependencies --dry-run 2>&1)"; then
        echo "[BLOCKED] Composer cannot update to $UPDATE_TARGET with the current composer.json:"
        printf '%s\n' "$dry_output" | tail -n 12 | sed 's/^/  /'
        echo "  Nothing was changed."
        return 1
    fi

    log_line "Dry run for $UPDATE_TARGET:"$'\n'"$dry_output"

    echo
    echo "======================================"
    echo "  Update project: $machine_name"
    echo "======================================"
    echo
    echo "Drupal core:  $current -> $UPDATE_TARGET"
    if has_core_security_advisory "$RECORD_PROJECT_PATH" "$RECORD_PHP_VERSION"; then
        echo "              Security: $current has a published security advisory; this update is needed."
    fi
    echo "PHP $RECORD_PHP_VERSION:      supported by $(echo "$UPDATE_TARGET" | cut -d. -f1,2)"
    echo "Packages:     $(describe_lock_operations "$dry_output")"
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

    UPDATE_DATABASE_CHANGED=0
    echo
    set_maintenance_mode 1 && echo "[OK] Maintenance mode on"

    if ! run_logged "Updating Drupal core to $UPDATE_TARGET" \
            run_project_composer "$RECORD_PROJECT_PATH" "$RECORD_PHP_VERSION" \
            update "${UPDATE_WITH_PACKAGES[@]}" "${with_args[@]}" --with-all-dependencies; then
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

    errors_after="$(get_project_requirement_errors)" || errors_after=""
    new_errors="$(comm -13 <(printf '%s\n' "$errors_before" | sort -u) <(printf '%s\n' "$errors_after" | sort -u) | grep . || true)"

    if [[ -n "$new_errors" ]]; then
        echo "[WARNING] New errors in the Drupal status report:"
        printf '%s\n' "$new_errors" | sed 's/^/            - /'
    else
        echo "[OK] No new errors in the Drupal status report"
    fi

    update_record_version "$record" "$UPDATE_TARGET" || true

    echo
    echo "[DONE] $machine_name: Drupal $current -> $UPDATE_TARGET"
    echo "Backup (keep it until you are sure): $UPDATE_BACKUP_DIR"
    echo "If the project keeps configuration in git, export it now:"
    echo "  drush config:export   (then review and commit the changes)"
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
