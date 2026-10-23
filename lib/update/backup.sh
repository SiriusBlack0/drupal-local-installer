#!/usr/bin/env bash

# Backup before an update: database and composer files, and their restore.

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
    local -a pipe_status

    case "$RECORD_DATABASE_ENGINE" in
        mariadb|mysql)
            UPDATE_DATABASE_BACKUP="$UPDATE_BACKUP_DIR/database.sql.gz"
            sudo mysqldump --single-transaction --routines --triggers \
                --databases --add-drop-database -- "$RECORD_DATABASE_NAME" | gzip > "$UPDATE_DATABASE_BACKUP"
            pipe_status=("${PIPESTATUS[@]}")
            ;;
        postgresql)
            UPDATE_DATABASE_BACKUP="$UPDATE_BACKUP_DIR/database.sql.gz"
            UPDATE_DATABASE_OWNER="$(get_postgresql_database_owner)" || return 1
            is_valid_database_user "$UPDATE_DATABASE_OWNER" || [[ "$UPDATE_DATABASE_OWNER" == "postgres" ]] || return 1
            printf '%s\n' "$UPDATE_DATABASE_OWNER" > "$UPDATE_BACKUP_DIR/database.owner"
            sudo -u postgres pg_dump -- "$RECORD_DATABASE_NAME" | gzip > "$UPDATE_DATABASE_BACKUP"
            pipe_status=("${PIPESTATUS[@]}")
            ;;
        sqlite)
            UPDATE_DATABASE_BACKUP="$UPDATE_BACKUP_DIR/database.sqlite"
            [[ -f "$RECORD_SQLITE_PATH" ]] || return 1
            cp -- "$RECORD_SQLITE_PATH" "$UPDATE_DATABASE_BACKUP" || return 1

            if [[ -f "$RECORD_SQLITE_PATH-wal" ]]; then
                cp -- "$RECORD_SQLITE_PATH-wal" "$UPDATE_DATABASE_BACKUP-wal" || return 1
            fi

            pipe_status=(0 0)
            ;;
        *)
            return 1
            ;;
    esac

    [[ "${pipe_status[0]}" -eq 0 && "${pipe_status[1]}" -eq 0 && -s "$UPDATE_DATABASE_BACKUP" ]]
}

restore_database_from_backup() {
    local -a pipe_status
    local dropdb_options=(--if-exists)

    case "$RECORD_DATABASE_ENGINE" in
        mariadb|mysql)
            gunzip -c -- "$UPDATE_DATABASE_BACKUP" | sudo mysql
            pipe_status=("${PIPESTATUS[@]}")
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
            pipe_status=("${PIPESTATUS[@]}")
            ;;
        sqlite)
            rm -f -- "$RECORD_SQLITE_PATH-wal" "$RECORD_SQLITE_PATH-shm"
            cp -- "$UPDATE_DATABASE_BACKUP" "$RECORD_SQLITE_PATH" || return 1

            if [[ -f "$UPDATE_DATABASE_BACKUP-wal" ]]; then
                cp -- "$UPDATE_DATABASE_BACKUP-wal" "$RECORD_SQLITE_PATH-wal" || return 1
            fi

            pipe_status=(0 0)
            ;;
        *)
            return 1
            ;;
    esac

    [[ "${pipe_status[0]}" -eq 0 && "${pipe_status[1]}" -eq 0 ]]
}

create_update_backup() {
    local machine_name="$1"
    local old_umask
    local ok=1

    UPDATE_BACKUP_DIR="$(get_backup_base_dir)/${machine_name}-${UPDATE_KIND}-$(date +%Y%m%d-%H%M%S)"

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

        if cp --preserve=timestamps -- "$RECORD_PROJECT_PATH/composer.json" "$RECORD_PROJECT_PATH/composer.lock" "$UPDATE_BACKUP_DIR/"; then
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
