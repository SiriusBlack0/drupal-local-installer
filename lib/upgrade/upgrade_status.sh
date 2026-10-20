#!/usr/bin/env bash

# Upgrade Status (drupal.org/project/upgrade_status) for --upgrade: the
# developer chooses to add it for this scan only, to keep it, or to skip
# the scan. "For this scan only" puts composer.json, composer.lock, the
# code and the database back as they were.

UPGRADE_STATUS_MODE=""
UPGRADE_STATUS_SAVED_DIR=""
UPGRADE_STATUS_WAS_IN_COMPOSER=0
UPGRADE_STATUS_ENABLED_BY_US=0
UPGRADE_STATUS_RESULT=3
UPGRADE_STATUS_SUMMARY=""

# "enabled", "disabled" (in the code base, not enabled) or "missing".
get_upgrade_status_state() {
    local json

    json="$(run_project_drush "$RECORD_PROJECT_PATH" "$RECORD_PHP_VERSION" \
        pm:list --type=module --format=json 2>/dev/null)" || { echo "missing"; return 0; }

    # Single quotes: PHP code, not shell code.
    # shellcheck disable=SC2016
    printf '%s' "$json" | "php${RECORD_PHP_VERSION}" -r '
$d = json_decode(stream_get_contents(STDIN), true);
if (!is_array($d) || !isset($d["upgrade_status"])) { echo "missing\n"; exit(0); }
echo stripos((string) ($d["upgrade_status"]["status"] ?? ""), "enabled") === 0 ? "enabled\n" : "disabled\n";
' 2>/dev/null || echo "missing"
}

# Asks how Upgrade Status may be used. Sets UPGRADE_STATUS_MODE to
# temporary, keep or skip.
choose_upgrade_status_mode() {
    local to_major="$1"
    local state="$2"
    local answer

    echo
    echo "Upgrade Status (drupal.org/project/upgrade_status) scans the enabled modules"
    echo "and themes, contrib and custom, for code that Drupal $to_major no longer supports"
    echo "(deprecated PHP APIs, .info.yml, Twig, libraries) and lists what must change."
    echo "It is a Drupal module: Composer adds it as a development dependency and Drush"
    echo "enables it. The scan takes a few minutes."

    if [[ "$state" == "disabled" ]]; then
        echo "It is already in the code base, but not enabled."
    fi

    echo
    echo "1) For this scan only: add it, scan, then remove it again"
    echo "   (composer.json, composer.lock and the database as before)"
    echo "2) Keep it: add it and leave it installed (scan again any time:"
    echo "   ./drush upgrade_status:analyze --all, or Reports > Upgrade status)"
    echo "3) Skip the scan"

    while true; do
        if ! read -r -p "Select [1-3]: " answer; then
            echo
            UPGRADE_STATUS_MODE="skip"
            return 0
        fi

        case "$answer" in
            1) UPGRADE_STATUS_MODE="temporary"; return 0 ;;
            2) UPGRADE_STATUS_MODE="keep"; return 0 ;;
            3) UPGRADE_STATUS_MODE="skip"; return 0 ;;
            *) echo "Invalid selection." ;;
        esac
    done
}

# Adds (if needed) and enables Upgrade Status.
add_upgrade_status() {
    local constraint="$1"
    local state="$2"

    UPGRADE_STATUS_WAS_IN_COMPOSER=1
    UPGRADE_STATUS_ENABLED_BY_US=0

    if [[ "$state" == "missing" ]]; then
        UPGRADE_STATUS_WAS_IN_COMPOSER=0

        if [[ "$UPGRADE_STATUS_MODE" == "temporary" ]]; then
            UPGRADE_STATUS_SAVED_DIR="$(mktemp -d)" || return 1
            cp -p -- "$RECORD_PROJECT_PATH/composer.json" "$RECORD_PROJECT_PATH/composer.lock" "$UPGRADE_STATUS_SAVED_DIR/" || return 1
        fi

        run_logged_retrying_network "Adding Upgrade Status ($constraint, development dependency)" - \
            run_project_composer "$RECORD_PROJECT_PATH" "$RECORD_PHP_VERSION" \
            require --dev "drupal/upgrade_status:$constraint" || return 1
    fi

    UPGRADE_STATUS_ENABLED_BY_US=1
    run_logged "Enabling Upgrade Status" \
        run_project_drush "$RECORD_PROJECT_PATH" "$RECORD_PHP_VERSION" pm:install upgrade_status --yes
}

# "For this scan only": uninstall the module, then composer.json,
# composer.lock and the code as before. Prints what to do by hand when
# that fails; returns 1 then.
remove_temporary_upgrade_status() {
    local failed=0

    [[ "$UPGRADE_STATUS_MODE" == "temporary" ]] || return 0

    if [[ "$UPGRADE_STATUS_ENABLED_BY_US" -eq 1 ]] &&
       ! run_logged "Uninstalling Upgrade Status" \
            run_project_drush "$RECORD_PROJECT_PATH" "$RECORD_PHP_VERSION" pm:uninstall upgrade_status --yes; then
        failed=1
    fi

    if [[ "$failed" -eq 0 && "$UPGRADE_STATUS_WAS_IN_COMPOSER" -eq 0 && -n "$UPGRADE_STATUS_SAVED_DIR" ]]; then
        if ! cp -p -- "$UPGRADE_STATUS_SAVED_DIR/composer.json" "$UPGRADE_STATUS_SAVED_DIR/composer.lock" "$RECORD_PROJECT_PATH/" ||
           ! run_logged_retrying_network "Removing Upgrade Status from the code (composer install)" - \
                run_project_composer "$RECORD_PROJECT_PATH" "$RECORD_PHP_VERSION" install; then
            failed=1
        fi
    fi

    if [[ "$failed" -eq 0 ]]; then
        [[ -n "$UPGRADE_STATUS_SAVED_DIR" ]] && rm -rf -- "$UPGRADE_STATUS_SAVED_DIR"
        UPGRADE_STATUS_SAVED_DIR=""
        UPGRADE_STATUS_ENABLED_BY_US=0
        echo "[OK] Upgrade Status removed again; the project is as before the scan"
        return 0
    fi

    echo "[ERROR] Upgrade Status could not be removed again. Remove it by hand:"
    echo "          cd $RECORD_PROJECT_PATH"
    [[ "$UPGRADE_STATUS_ENABLED_BY_US" -eq 1 ]] && echo "          ./drush pm:uninstall upgrade_status"

    if [[ "$UPGRADE_STATUS_WAS_IN_COMPOSER" -eq 0 && -n "$UPGRADE_STATUS_SAVED_DIR" ]]; then
        echo "          cp $UPGRADE_STATUS_SAVED_DIR/composer.json $UPGRADE_STATUS_SAVED_DIR/composer.lock ."
        echo "          composer install"
    fi

    echo "        The upgrade stops here, so it does not mix with that change."
    return 1
}

# Ctrl+C during the scan: remove a temporary Upgrade Status, then stop.
interrupt_upgrade_status() {
    trap '' INT TERM
    to_console
    echo
    echo "[INTERRUPTED] Stopping the scan..."
    remove_temporary_upgrade_status || true
    exit 130
}

# Summarizes the checkstyle report of upgrade_status:analyze: a line
# "errors warnings", then "type|project|errors|warnings" per project, then
# up to 8 findings in custom code. Returns 0: nothing, 1: errors in custom
# code, 2: other findings only, 3: no report.
summarize_upgrade_status_report() {
    # Single quotes: PHP code, not shell code.
    # shellcheck disable=SC2016
    "php${RECORD_PHP_VERSION}" -r '
$xml = stream_get_contents(STDIN);
if (strpos($xml, "<checkstyle") === false) { exit(3); }
$root = rtrim($argv[1], "/") . "/";
$projects = []; $custom = []; $e = 0; $w = 0;
foreach (preg_split("/<file\s/", $xml) as $i => $chunk) {
    if ($i === 0 || !preg_match("/^name=\"([^\"]*)\"/", $chunk, $m)) { continue; }
    $file = html_entity_decode($m[1], ENT_QUOTES | ENT_XML1);
    $rel = strpos($file, $root) === 0 ? substr($file, strlen($root)) : $file;
    $type = "other"; $name = $rel;
    if (preg_match("#(?:^|/)(?:modules|themes|profiles)/(custom|contrib)/([^/]+)/#", $rel, $p)) { $type = $p[1]; $name = $p[2]; }
    preg_match_all("/<error\b([^>]*)>/", $chunk, $errs);
    foreach ($errs[1] as $attrs) {
        $a = [];
        preg_match_all("/(\w+)=\"([^\"]*)\"/", $attrs, $kv, PREG_SET_ORDER);
        foreach ($kv as $x) { $a[$x[1]] = html_entity_decode($x[2], ENT_QUOTES | ENT_XML1); }
        $sev = strtolower($a["severity"] ?? "error") === "warning" ? 1 : 0;
        // Twig deprecations ("Since twig/twig 3.12: ...") still work with
        // Twig 3, which the next major uses too: a warning, not an error.
        if (preg_match("#^Since twig/twig 3\\.#", $a["message"] ?? "")) { $sev = 1; }
        $key = "$type|$name";
        $projects[$key] = $projects[$key] ?? [0, 0];
        $projects[$key][$sev]++;
        if ($sev) { $w++; } else { $e++; }
        if ($type === "custom" && count($custom) < 8) {
            $custom[] = $rel . ":" . ($a["line"] ?? "?") . " " . ($sev ? "WARNING" : "ERROR") . ": " . mb_substr(preg_replace("/\s+/", " ", $a["message"] ?? ""), 0, 160);
        }
    }
}
echo $e, " ", $w, "\n";
ksort($projects);
foreach ($projects as $k => [$pe, $pw]) { echo $k, "|", $pe, "|", $pw, "\n"; }
foreach ($custom as $c) { echo $c, "\n"; }
$customErrors = 0;
foreach ($projects as $k => [$pe, $pw]) { if (strpos($k, "custom|") === 0) { $customErrors += $pe; } }
exit($customErrors > 0 ? 1 : ($e + $w > 0 ? 2 : 0));
' "$RECORD_PROJECT_PATH"
}

# Prints the scan as check lines; sets UPGRADE_STATUS_RESULT and
# UPGRADE_STATUS_SUMMARY.
print_upgrade_status_report() {
    local report="$1"
    local to_major="$2"
    local counts
    local errors
    local warnings
    local line
    local type
    local project
    local pe
    local pw

    counts="$(head -n 1 <<< "$report")"
    errors="${counts%% *}"
    warnings="${counts##* }"

    if [[ "$UPGRADE_STATUS_RESULT" -eq 0 ]]; then
        echo "  [OK]      Upgrade Status: nothing found in the enabled modules and themes"
        UPGRADE_STATUS_SUMMARY="nothing found"
        return 0
    fi

    echo "  [WARNING] Upgrade Status: $errors error(s), $warnings warning(s) for Drupal $to_major:"
    UPGRADE_STATUS_SUMMARY="$errors error(s), $warnings warning(s)"

    while IFS= read -r line; do
        if [[ "$line" == *"|"*"|"*"|"* ]]; then
            IFS='|' read -r type project pe pw <<< "$line"
            echo "              $type: $project: $pe error(s), $pw warning(s)"
        elif [[ -n "$line" ]]; then
            echo "              $line"
        fi
    done < <(tail -n +2 <<< "$report")

    echo "            Contrib: newer releases usually fix this; Composer is asked below."
    echo "            Custom code: fix it (drupal-rector fixes many of these automatically)."
    print_info_yml_fixes "$report" "$to_major"

    if grep -q 'WARNING: Since twig/twig 3\.' <<< "$report"; then
        echo "            Twig deprecations (warnings): they still work with Twig 3, which Drupal"
        echo "            $to_major uses; fix them at leisure (they break only with Twig 4)."
    fi

    echo "            Full report: ./drush upgrade_status:analyze --all (while it is installed)."
}

# The most common finding in custom code: an .info.yml that allows only
# the current major. The fix is one line; it is shown exactly (rector does
# not change .info.yml files).
print_info_yml_fixes() {
    local report="$1"
    local to_major="$2"
    local line
    local file
    local value
    local web_rel
    local -a commands=()

    web_rel="${UPDATE_WEB_ROOT#"$RECORD_PROJECT_PATH"}"
    web_rel="${web_rel#/}"

    while IFS= read -r line; do
        if [[ "$line" =~ ^(.+\.info\.yml):[0-9]+\ ERROR:\ Value\ of\ core_version_requirement:\ (.+)\ is\ not\ compatible ]]; then
            file="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"

            if [[ ! -f "$RECORD_PROJECT_PATH/$file" && -n "$web_rel" && -f "$RECORD_PROJECT_PATH/$web_rel/$file" ]]; then
                file="$web_rel/$file"
            fi

            commands+=("sed -i 's/^core_version_requirement:.*/core_version_requirement: $value || ^$to_major/' $file")
        fi
    done <<< "$report"

    [[ "${#commands[@]}" -gt 0 ]] || return 0

    echo "            .info.yml files that allow only the current major: allow Drupal $to_major too"
    echo "            (in $RECORD_PROJECT_PATH, then commit; the site keeps working on the current major):"
    printf '              %s\n' "${commands[@]}"
}

# The whole Upgrade Status step. Returns 1 only when a temporary Upgrade
# Status could not be removed again (the upgrade must stop then).
run_upgrade_status_check() {
    local to_major="$1"
    local constraint="$2"
    local state
    local report_file
    local report

    UPGRADE_STATUS_RESULT=3
    UPGRADE_STATUS_SUMMARY="skipped"
    UPGRADE_STATUS_MODE=""
    UPGRADE_STATUS_SAVED_DIR=""

    state="$(get_upgrade_status_state)"

    if [[ "$state" == "enabled" ]]; then
        UPGRADE_STATUS_MODE="installed"
        echo
        echo "Upgrade Status is installed and enabled: scanning with it."
    else
        choose_upgrade_status_mode "$to_major" "$state"

        if [[ "$UPGRADE_STATUS_MODE" == "skip" ]]; then
            echo "  [SKIPPED] Upgrade Status scan (your choice)"
            return 0
        fi

        trap 'interrupt_upgrade_status' INT TERM

        if ! add_upgrade_status "$constraint" "$state"; then
            echo "  [SKIPPED] Upgrade Status could not be added (see above)."
            remove_temporary_upgrade_status || { trap - INT TERM; return 1; }
            trap - INT TERM
            return 0
        fi
    fi

    trap 'interrupt_upgrade_status' INT TERM
    report_file="$(mktemp)"
    printf 'Scanning with Upgrade Status (a few minutes) ... '
    run_project_drush "$RECORD_PROJECT_PATH" "$RECORD_PHP_VERSION" \
        upgrade_status:analyze --all --ignore-uninstalled --format=checkstyle > "$report_file" 2>> "${LOG_FILE:-/dev/null}" || true
    echo "done"

    UPGRADE_STATUS_RESULT=0
    report="$(summarize_upgrade_status_report < "$report_file")" || UPGRADE_STATUS_RESULT=$?
    [[ -n "${LOG_FILE:-}" ]] && { echo "Upgrade Status report:"; cat "$report_file"; } >> "$LOG_FILE"
    rm -f "$report_file"

    if [[ "$UPGRADE_STATUS_RESULT" -eq 3 ]]; then
        echo "  [SKIPPED] Upgrade Status gave no report (see the log)"
        # Read in lib/upgrade/upgrade.sh (the plan).
        # shellcheck disable=SC2034
        UPGRADE_STATUS_SUMMARY="no report"
    else
        print_upgrade_status_report "$report" "$to_major"
    fi

    if ! remove_temporary_upgrade_status; then
        trap - INT TERM
        return 1
    fi

    trap - INT TERM

    if [[ "$UPGRADE_STATUS_MODE" == "keep" ]]; then
        echo "[NOTE] Upgrade Status stays installed (your choice). To remove it later:"
        echo "         ./drush pm:uninstall upgrade_status && composer remove --dev drupal/upgrade_status"

        if [[ -d "$RECORD_PROJECT_PATH/.git" ]]; then
            echo "       composer.json and composer.lock changed: commit them before the real"
            echo "       upgrade (it refuses uncommitted changes, so it never mixes with them)."
        fi
    fi

    return 0
}
