#!/usr/bin/env bash

# ==================================================
# Package releases known to break a project (config/known-bad-packages.conf)
#
# A new release of a dependency (not Drupal, not Drush) can declare a
# compatibility it does not have; Composer then picks it, being the
# newest. Before Drush is added to a new project, the releases listed in
# the file are excluded with a "conflict" in composer.json, but only
# where their condition holds for the packages actually installed. When
# Drush still fails, the packages released in the last days are named:
# the usual suspects.
#
# composer.lock is read with awk (no PHP needed: DDEV projects may have
# none on the system). Composer writes it with 4 spaces per level, so
# a package's own fields are the ones indented by 12 spaces.
# ==================================================

KNOWN_BAD_LIB_DIR="$(dirname "${BASH_SOURCE[0]}")"
KNOWN_BAD_DAYS=14

get_known_bad_file() {
    printf '%s\n' "${KNOWN_BAD_PACKAGES_FILE:-$KNOWN_BAD_LIB_DIR/../config/known-bad-packages.conf}"
}

# The entries: "package|bad versions|condition|why", trimmed.
read_known_bad_entries() {
    local file

    file="$(get_known_bad_file)"
    [[ -f "$file" ]] || return 0

    awk -F'|' '
        /^[[:space:]]*(#|$)/ { next }
        NF >= 4 {
            for (i = 1; i <= 4; i++) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i) }
            why = $4
            for (i = 5; i <= NF; i++) { why = why "|" $i }
            print $1 "|" $2 "|" $3 "|" why
        }' "$file"
}

# The packages of a composer.lock: "name|version|date" (version without
# a leading v; date YYYY-MM-DD, empty when unknown).
list_locked_packages() {
    [[ -f "$1" ]] || return 0

    awk '
        function value(line) { sub(/^[^:]*:[[:space:]]*"/, "", line); sub(/",?[[:space:]]*$/, "", line); return line }
        function flush() { if (name != "") { print name "|" version "|" date } name = ""; version = ""; date = "" }
        /^        [{}]/ { flush() }
        /^            "name": "/ { name = value($0) }
        /^            "version": "/ { version = value($0); sub(/^v/, "", version) }
        /^            "time": "/ { date = substr(value($0), 1, 10) }
        END { flush() }' "$1"
}

get_locked_version() {
    list_locked_packages "$1" | awk -F'|' -v p="$2" '$1 == p { print $2; exit }'
}

# Does version $1 satisfy "op version" tokens $2 (all of them)?
# Ops: >= > <= < = (or none, which is =). Pre-release versions are
# compared by sort -V, which is enough for the ranges in the file.
version_matches_range() {
    local version="$1"
    local token
    local op
    local wanted

    [[ "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 1

    for token in $2; do
        op="${token%%[0-9]*}"
        wanted="${token#"$op"}"

        case "$op" in
            ">=") version_at_least "$version" "$wanted" || return 1 ;;
            ">") version_at_least "$version" "$wanted" && [[ "$version" != "$wanted" ]] || return 1 ;;
            "<=") version_at_least "$wanted" "$version" || return 1 ;;
            "<") version_at_least "$wanted" "$version" && [[ "$version" != "$wanted" ]] || return 1 ;;
            "="|"") [[ "$version" == "$wanted" ]] || return 1 ;;
            *) return 1 ;;
        esac
    done
}

# Does an entry's condition hold for composer.lock $1?
known_bad_condition_holds() {
    local lock="$1"
    local condition="$2"
    local package
    local op
    local wanted
    local installed

    [[ "$condition" == "always" ]] && return 0
    read -r package op wanted <<< "$condition"
    [[ -n "$package" && -n "$op" && -n "$wanted" ]] || return 1

    installed="$(get_locked_version "$lock" "$package")"
    [[ -n "$installed" ]] || return 1
    version_matches_range "$installed" "$op$wanted"
}

# The entries whose condition holds for composer.lock $1.
find_known_bad_conflicts() {
    local package
    local range
    local condition
    local why

    while IFS='|' read -r package range condition why; do
        known_bad_condition_holds "$1" "$condition" && printf '%s|%s|%s|%s\n' "$package" "$range" "$condition" "$why"
    done < <(read_known_bad_entries)
}

# Releases in composer.lock $1 that the file lists (condition holding):
# "package|version|why".
find_known_bad_installed() {
    local lock="$1"
    local package
    local range
    local condition
    local why
    local installed

    while IFS='|' read -r package range condition why; do
        installed="$(get_locked_version "$lock" "$package")"
        [[ -n "$installed" ]] || continue
        version_matches_range "$installed" "$range" || continue
        known_bad_condition_holds "$lock" "$condition" || continue
        printf '%s|%s|%s\n' "$package" "$installed" "$why"
    done < <(read_known_bad_entries)
}

# Adds "conflict": {package: range} to composer.json $1, as the
# developer, with PHP command $4 ("php8.3") or, when $4 is empty, with
# python3 or the system's php (DDEV projects may have no project PHP on
# the system). Existing conflicts are kept (joined with ||); {} stays {}.
add_composer_conflict() {
    local file="$1"
    local package="$2"
    local range="$3"
    local php="${4:-}"

    if [[ -z "$php" ]] && command -v python3 > /dev/null 2>&1; then
        run_as_project_user "${PROJECT_USER:-$(id -un)}" python3 -c '
import json, sys
path, package, range_ = sys.argv[1:4]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)
conflict = data.setdefault("conflict", {})
old = conflict.get(package, "")
if range_ not in [part.strip() for part in old.split("||")]:
    conflict[package] = range_ if not old else old + " || " + range_
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(json.dumps(data, indent=4, ensure_ascii=False) + "\n")
' "$file" "$package" "$range"
        return
    fi

    [[ -n "$php" ]] || php="php"
    command -v "$php" > /dev/null 2>&1 || return 1

    # Single quotes: PHP code, not shell code.
    # shellcheck disable=SC2016
    run_as_project_user "${PROJECT_USER:-$(id -un)}" "$php" -r '
$file = $argv[1];
$data = json_decode((string) file_get_contents($file));
if (!is_object($data)) { fwrite(STDERR, "composer.json is not valid JSON\n"); exit(1); }
if (!isset($data->conflict) || !is_object($data->conflict)) { $data->conflict = new stdClass(); }
$package = $argv[2];
$range = $argv[3];
$old = $data->conflict->$package ?? "";
if (in_array($range, array_map("trim", explode("||", $old)), true)) { exit(0); }
$data->conflict->$package = $old === "" ? $range : "$old || $range";
$json = json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
exit(file_put_contents($file, $json . "\n") === false ? 1 : 0);
' "$file" "$package" "$range"
}

# Before Drush: the known bad releases whose condition holds become
# conflicts. $1: project folder; $2: PHP command for native projects
# (empty for DDEV). Never fails the installation by itself.
apply_known_bad_packages() {
    local project_path="$1"
    local php="${2:-}"
    local package
    local range
    local condition
    local why
    local here
    local found

    found="$(find_known_bad_conflicts "$project_path/composer.lock")"
    [[ -n "$found" ]] || return 0

    while IFS='|' read -r package range condition why; do
        if add_composer_conflict "$project_path/composer.json" "$package" "$range" "$php"; then
            here=""
            if [[ "$condition" != "always" ]]; then
                here=" (here: ${condition%% *} $(get_locked_version "$project_path/composer.lock" "${condition%% *}"))"
            fi
            say "[WORKAROUND] $package $range kept out: $why$here."
            say "             It is a \"conflict\" in composer.json; remove it once a fixed release is out."
        else
            say "[WARNING] Could not add the conflict for $package $range to composer.json."
        fi
    done <<< "$found"
}

# Packages of composer.lock $1 released in the last KNOWN_BAD_DAYS days,
# newest first: "name version (date)".
list_recent_packages() {
    local cutoff

    cutoff="$(date -d "-$KNOWN_BAD_DAYS days" +%F 2>/dev/null)" || return 0
    list_locked_packages "$1" | awk -F'|' -v c="$cutoff" '$3 != "" && $3 >= c { print $3 "|" $1 "|" $2 }' |
        sort -r | awk -F'|' '{ print $2 " " $3 " (" $1 ")" }'
}

# When Drush does not start: what the log needs, and the suspects.
print_drush_failure_diagnosis() {
    local project_path="$1"
    local output="$2"
    local lock="$project_path/composer.lock"
    local recent
    local package

    log_line "Drush output (full):"
    log_line "$output"
    log_line "Versions in composer.lock:"

    while IFS='|' read -r package _; do
        [[ "$package" =~ ^(drush/drush|consolidation/.*|symfony/console|drupal/core)$ ]] &&
            log_line "  $(list_locked_packages "$lock" | awk -F'|' -v p="$package" '$1 == p { print $1 " " $2 " (" $3 ")" }')"
    done < <(list_locked_packages "$lock")

    recent="$(list_recent_packages "$lock")"

    if [[ -n "$recent" ]]; then
        say "        Released in the last $KNOWN_BAD_DAYS days (the usual suspects: a new release"
        say "        that declares a compatibility it does not have):"
        while IFS= read -r package; do
            say "          - $package"
        done < <(head -n 12 <<< "$recent")
    fi

    say "        A release that breaks Drush can be listed in config/known-bad-packages.conf;"
    say "        the next run keeps it out. Details in the log."
}
