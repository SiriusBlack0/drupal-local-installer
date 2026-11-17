#!/usr/bin/env bash

# Releases known to break projects (config/known-bad-packages.conf): the
# composer.lock reader, the ranges and conditions, the conflict written
# into composer.json (with PHP and with python3), the diagnosis when Drush
# does not start, --check-updates' warning, and that an installation's
# screen output reaches the log with a RESULT line.

set -euo pipefail

cd "$(dirname "$0")/.."

source lib/output.sh
source lib/compatibility.sh
source lib/system.sh
source lib/registry.sh
source lib/project.sh
source lib/known_bad.sh

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; exit 1; }

PROJECT_USER="$(id -un)"
LOG_FILE="$work_dir/install.log"
: > "$LOG_FILE"
today="$(date +%F)"

# A composer.lock as Composer writes it (4 spaces per level; authors have
# a "name" too, deeper).
write_lock() {
    local file="$1"
    local console="$2"
    local robo="$3"

    cat > "$file" <<LOCK
{
    "_readme": [
        "This file locks the dependencies of your project to a known state"
    ],
    "content-hash": "abc",
    "packages": [
        {
            "name": "consolidation/robo",
            "version": "$robo",
            "authors": [
                {
                    "name": "Davert",
                    "email": "davert.php@resend.cc"
                }
            ],
            "time": "${today}T10:00:00+00:00"
        },
        {
            "name": "drush/drush",
            "version": "13.8.1",
            "time": "2026-09-30T08:00:00+00:00"
        },
        {
            "name": "symfony/console",
            "version": "$console",
            "authors": [
                {
                    "name": "Fabien Potencier",
                    "email": "fabien@symfony.com"
                }
            ],
            "time": "2026-10-28T12:00:00+00:00"
        }
    ],
    "packages-dev": []
}
LOCK
}

# Test 1: The lock is read by package (not by the authors' names).

write_lock "$work_dir/old.lock" "v6.4.41" "5.2.3"

if [[ "$(list_locked_packages "$work_dir/old.lock")" == "consolidation/robo|5.2.3|$today"$'\n'"drush/drush|13.8.1|2026-09-30"$'\n'"symfony/console|6.4.41|2026-10-28" &&
      "$(get_locked_version "$work_dir/old.lock" symfony/console)" == "6.4.41" &&
      -z "$(get_locked_version "$work_dir/old.lock" Fabien)" ]]; then
    pass "composer.lock read with awk: name, version (no v), release date; authors ignored"
else
    fail "lock: $(list_locked_packages "$work_dir/old.lock")"
fi

# Test 2: Ranges and conditions.

if version_matches_range 5.2.3 ">=5.2.0 <5.3" && version_matches_range 5.2.0 ">=5.2.0 <5.3" &&
   ! version_matches_range 5.3 ">=5.2.0 <5.3" && ! version_matches_range 5.1.1 ">=5.2.0 <5.3" &&
   version_matches_range 5.2.2 "5.2.2" && ! version_matches_range 5.2.3 "=5.2.2" &&
   version_matches_range 6.4.41 "<7.4" && ! version_matches_range 7.4.0 "<7.4" &&
   version_matches_range 7.4.1 ">7.4" && ! version_matches_range 7.4 ">7.4" &&
   version_matches_range 7.4 "<=7.4" && ! version_matches_range "dev-main" ">=1"; then
    pass "Ranges: >= > <= < = and bare versions, all tokens must hold"
else
    fail "ranges"
fi

write_lock "$work_dir/new.lock" "v7.4.1" "5.2.3"

if [[ "$(find_known_bad_conflicts "$work_dir/old.lock" | cut -d'|' -f1,2)" == "consolidation/robo|>=5.2.0 <5.3"$'\n'"consolidation/robo|5.2.2" &&
      "$(find_known_bad_conflicts "$work_dir/new.lock" | cut -d'|' -f1,2)" == "consolidation/robo|5.2.2" ]]; then
    pass "Conditions on the installed packages: Console 6.4 -> Robo 5.2 kept out; Console 7.4 -> only the broken 5.2.2"
else
    fail "conditions: $(find_known_bad_conflicts "$work_dir/old.lock")"
fi

# Test 3: The conflict in composer.json: added, joined with an existing
# one, not repeated; {} stays {}; with PHP and with python3.

for tool in php python3; do
    project="$work_dir/project-$tool"
    mkdir -p "$project"
    cp "$work_dir/old.lock" "$project/composer.lock"
    printf '{\n    "name": "drupal/recommended-project",\n    "require-dev": {},\n    "conflict": {\n        "drupal/drupal": "*"\n    },\n    "extra": {\n        "installer-paths": {\n            "web/core": ["type:drupal-core"]\n        }\n    }\n}\n' > "$project/composer.json"

    if [[ "$tool" == "php" ]]; then
        output="$(apply_known_bad_packages "$project" php)"
        apply_known_bad_packages "$project" php > /dev/null
    else
        output="$(apply_known_bad_packages "$project")"
        apply_known_bad_packages "$project" > /dev/null
    fi

    # Single quotes: PHP code, not shell code.
    # shellcheck disable=SC2016
    if [[ "$output" == *"[WORKAROUND] consolidation/robo >=5.2.0 <5.3 kept out: Robo 5.2 needs Symfony Console 7.4+"*"(here: symfony/console 6.4.41)."* &&
          "$output" == *"remove it once a fixed release is out."* ]] &&
       php -r '
$d = json_decode(file_get_contents($argv[1]));
exit(
    $d->conflict->{"consolidation/robo"} === ">=5.2.0 <5.3 || 5.2.2"
    && $d->conflict->{"drupal/drupal"} === "*"
    && is_object($d->{"require-dev"})
    && $d->extra->{"installer-paths"}->{"web/core"}[0] === "type:drupal-core" ? 0 : 1);' "$project/composer.json" &&
       grep -q '"require-dev": {}' "$project/composer.json" && grep -q '"web/core"' "$project/composer.json" &&
       grep -q "WORKAROUND" "$LOG_FILE"; then
        pass "Conflict with $tool: added once (again: not repeated), existing conflicts kept, {} stays {}, logged"
    else
        fail "conflict $tool: $output / $(cat "$project/composer.json")"
    fi
done

# Test 4: Installed releases from the file (--check-updates).

if [[ "$(find_known_bad_installed "$work_dir/old.lock")" == "consolidation/robo|5.2.3|Robo 5.2 needs Symfony Console 7.4+ (Application::addCommand) but declares ^6; Drush does not start" &&
      -z "$(find_known_bad_installed "$work_dir/new.lock")" ]]; then
    pass "Installed known bad release found (Robo 5.2.3 with Console 6.4); none with Console 7.4"
else
    fail "installed: $(find_known_bad_installed "$work_dir/old.lock")"
fi

# Test 5: Drush does not start: the full output and versions in the
# log, the packages released in the last 14 days on the screen.

project="$work_dir/broken"
mkdir -p "$project"
cp "$work_dir/old.lock" "$project/composer.lock"
printf '#!/usr/bin/env bash\necho "PHP Fatal error:  Uncaught Error: Call to undefined method Drush\\\\Application::addCommand() in vendor/consolidation/robo/src/Robo.php:558"\nexit 255\n' > "$project/drush"
chmod +x "$project/drush"
: > "$LOG_FILE"

if output="$(verify_drush "$project" "$PROJECT_USER")"; then
    fail "Broken Drush accepted"
elif [[ "$output" == *"[ERROR] Drush does not run correctly. Output:"* &&
        "$output" == *"undefined method Drush\\Application::addCommand()"* &&
        "$output" == *"Released in the last 14 days"* && "$output" == *"- consolidation/robo 5.2.3 ($today)"* &&
        "$output" != *"drush/drush 13.8.1 (2026-09-30)"* &&
        "$output" == *"config/known-bad-packages.conf"* ]] &&
     grep -q "Drush output (full):" "$LOG_FILE" && grep -q "addCommand" "$LOG_FILE" &&
     grep -q "  symfony/console 6.4.41 (2026-10-28)" "$LOG_FILE" &&
     grep -q "  drush/drush 13.8.1 (2026-09-30)" "$LOG_FILE"; then
    pass "Drush failure: full output and versions in the log; packages released in the last 14 days shown"
else
    fail "diagnosis: $output / $(cat "$LOG_FILE")"
fi

# Test 6: Screen output of an installation reaches the log once, then
# RESULT; say inside does not write twice.

: > "$LOG_FILE"
STEP_TOTAL=3
STEP_INDEX=0

fake_workflow() {
    step "Downloading Drupal"
    echo "[ERROR] Drush could not be added."
    say "[OK] Rollback completed."
    return 1
}

status=0
run_shown_and_logged fake_workflow > /dev/null || status=$?
log_result "$status"

if [[ "$status" -eq 1 ]] &&
   [[ "$(grep -c "\[ERROR\] Drush could not be added." "$LOG_FILE")" -eq 1 ]] &&
   [[ "$(grep -c "\[OK\] Rollback completed." "$LOG_FILE")" -eq 1 ]] &&
   [[ "$(tail -n 1 "$LOG_FILE")" == "RESULT: FAILED at step 1/3 (Downloading Drupal)" ]]; then
    pass "Installation output in the log once (echo and say), last line RESULT: FAILED at step 1/3 (Downloading Drupal)"
else
    fail "result: $(cat "$LOG_FILE")"
fi

: > "$LOG_FILE"
run_shown_and_logged true > /dev/null
log_result 0

if [[ "$(tail -n 1 "$LOG_FILE")" == "RESULT: OK" ]]; then
    pass "Success: RESULT: OK"
else
    fail "result ok: $(cat "$LOG_FILE")"
fi

echo "[SUCCESS] Known bad packages tests passed."
