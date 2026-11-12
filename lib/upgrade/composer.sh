#!/usr/bin/env bash

# Composer for --upgrade: the new requirements, the trial run on a copy
# of composer.json/composer.lock, and the "lenient" plugin for drupal.org
# projects without a release for the new major.

# The trial runs on these copies, next to the real files (relative paths
# in composer.json keep working); the real files are never touched.
UPGRADE_COMPOSER_COPY="composer.dli-upgrade.json"

# "package:constraint" for "composer require --no-update" and --dev.
UPGRADE_REQUIRE=()
UPGRADE_REQUIRE_DEV=()
# What "composer update" may change, and the exact core version.
UPGRADE_UPDATE_PACKAGES=()
UPGRADE_WITH_ARGS=()
# drupal.org projects installed despite their drupal/core requirement.
UPGRADE_LENIENT=()
# Composer plugins the new release brings that composer.json does not
# mention in allow-plugins ("name|description"), and the decision for
# them: true (allowed) or false (installed, plugin part off).
UPGRADE_NEW_PLUGINS=()
UPGRADE_PLUGIN_DECISION=""

# Releases found for the blocking projects: "package<TAB>version<TAB>both|new".
UPGRADE_BLOCKER_RELEASES=""
LENIENT_PLUGIN="mglaman/composer-drupal-lenient"

# Fills UPGRADE_REQUIRE, UPGRADE_REQUIRE_DEV, UPGRADE_UPDATE_PACKAGES and
# UPGRADE_WITH_ARGS for the target release.
prepare_upgrade_requirements() {
    local target="$1"
    local drush_constraint="$2"
    local constraint
    local package
    local section
    local wanted

    constraint="^$(echo "$target" | cut -d. -f1,2)"
    UPGRADE_REQUIRE=()
    UPGRADE_REQUIRE_DEV=()
    UPGRADE_UPDATE_PACKAGES=("drupal/*")
    UPGRADE_WITH_ARGS=()

    for package in "${UPDATE_WITH_PACKAGES[@]}"; do
        UPGRADE_WITH_ARGS+=(--with "$package:$target")
    done

    while read -r package section; do
        [[ -n "$package" ]] || continue

        if [[ "$package" == "drush/drush" ]]; then
            UPGRADE_UPDATE_PACKAGES+=(drush/drush)
            [[ -n "$drush_constraint" ]] || continue
            wanted="$package:$drush_constraint"
        else
            wanted="$package:$constraint"
        fi

        if [[ "$section" == "require-dev" ]]; then
            UPGRADE_REQUIRE_DEV+=("$wanted")
        else
            UPGRADE_REQUIRE+=("$wanted")
        fi
    done < <(get_composer_sections "${UPDATE_WITH_PACKAGES[@]}" drush/drush)
}

# The requirements as shown in the plan: "drupal/core-recommended ^11.4, ...".
describe_upgrade_requirements() {
    printf '%s\n' "${UPGRADE_REQUIRE[@]}" "${UPGRADE_REQUIRE_DEV[@]}" | grep . | sed 's/:/ /' | paste -sd',' - | sed 's/,/, /g'
}

run_real_composer() {
    run_project_composer "$RECORD_PROJECT_PATH" "$RECORD_PHP_VERSION" "$@"
}

run_copy_composer() {
    run_as_project_user "$PROJECT_USER" env COMPOSER="$UPGRADE_COMPOSER_COPY" \
        "php${RECORD_PHP_VERSION}" "$(get_composer_path)" \
        --working-dir="$RECORD_PROJECT_PATH" --no-interaction "$@"
}

remove_upgrade_composer_copy() {
    rm -f -- "$RECORD_PROJECT_PATH/$UPGRADE_COMPOSER_COPY" "$RECORD_PROJECT_PATH/${UPGRADE_COMPOSER_COPY%.json}.lock"
}

# Writes the new requirements with the given runner (run_real_composer
# or run_copy_composer); nothing is installed yet.
write_upgrade_requirements() {
    local runner="$1"

    if [[ "${#UPGRADE_REQUIRE[@]}" -gt 0 ]]; then
        "$runner" require --no-update "${UPGRADE_REQUIRE[@]}" || return 1
    fi

    if [[ "${#UPGRADE_REQUIRE_DEV[@]}" -gt 0 ]]; then
        "$runner" require --dev --no-update "${UPGRADE_REQUIRE_DEV[@]}" || return 1
    fi
}

# Composer plugins in the new lock file ($1) that the allow-plugins
# setting of its composer.json ($2) does not mention and that the current
# lock file ($3) does not have yet: Composer stops at them during the
# install. Prints "DLI-NEW-PLUGIN: name|description" lines.
list_undecided_plugins() {
    # Single quotes: PHP code, not shell code.
    # shellcheck disable=SC2016
    "php${RECORD_PHP_VERSION}" -r '
$lock = json_decode((string) @file_get_contents($argv[1]), true) ?: [];
$json = json_decode((string) @file_get_contents($argv[2]), true) ?: [];
$old = json_decode((string) @file_get_contents($argv[3]), true) ?: [];
$installed = [];
foreach (array_merge($old["packages"] ?? [], $old["packages-dev"] ?? []) as $p) { $installed[$p["name"]] = true; }
$allow = $json["config"]["allow-plugins"] ?? [];
if (!is_array($allow)) { exit(0); }
foreach (array_merge($lock["packages"] ?? [], $lock["packages-dev"] ?? []) as $p) {
    if (($p["type"] ?? "") !== "composer-plugin" || isset($installed[$p["name"]])) { continue; }
    $name = $p["name"];
    $known = false;
    foreach (array_keys($allow) as $pattern) {
        $re = "{^" . str_replace("\\*", ".*", preg_quote($pattern)) . "$}i";
        if (preg_match($re, $name)) { $known = true; break; }
    }
    if (!$known) { echo "DLI-NEW-PLUGIN: ", $name, "|", str_replace(["|", "\n"], " ", (string) ($p["description"] ?? "")), "\n"; }
}
' "$1" "$2" "$3"
}

# The upgrade, tried on copies of composer.json and composer.lock: the
# copy of the lock file is written (--no-install: vendor/ and the real
# files are not touched; --no-scripts: no project scripts run). Prints
# Composer's output, then the plugins Composer would stop at; returns
# Composer's status.
try_upgrade_with_composer() {
    local status=0

    remove_upgrade_composer_copy

    if ! cp -p -- "$RECORD_PROJECT_PATH/composer.json" "$RECORD_PROJECT_PATH/$UPGRADE_COMPOSER_COPY" ||
       ! cp -p -- "$RECORD_PROJECT_PATH/composer.lock" "$RECORD_PROJECT_PATH/${UPGRADE_COMPOSER_COPY%.json}.lock"; then
        remove_upgrade_composer_copy
        echo "Could not copy composer.json and composer.lock for the trial run."
        return 1
    fi

    {
        write_upgrade_requirements run_copy_composer &&
        run_copy_composer update "${UPGRADE_UPDATE_PACKAGES[@]}" "${UPGRADE_WITH_ARGS[@]}" \
            --with-all-dependencies --no-install --no-scripts "${UPDATE_EXTRA_ARGS[@]}"
    } 2>&1 || status=$?

    if [[ "$status" -eq 0 ]]; then
        list_undecided_plugins "$RECORD_PROJECT_PATH/${UPGRADE_COMPOSER_COPY%.json}.lock" \
            "$RECORD_PROJECT_PATH/$UPGRADE_COMPOSER_COPY" "$RECORD_PROJECT_PATH/composer.lock"
    fi

    remove_upgrade_composer_copy
    return "$status"
}

# The newest stable release of drupal.org project $1 whose drupal/core
# requirement allows release $2 (the target): prints
# "version<TAB>both" when it allows the current release $3 too, else
# "version<TAB>new". Asks Composer (drupal.org's repository); looks at
# the 8 newest stable releases. Returns 1 when there is none or it
# cannot tell (network, no composer/semver).
find_release_for_new_core() {
    local package="$1"
    local target="$2"
    local current="$3"
    local json
    local version
    local requires
    local -a versions=()

    [[ -f "$RECORD_PROJECT_PATH/vendor/autoload.php" ]] || return 1
    json="$(run_real_composer show "$package" --all --format=json 2>/dev/null)" || return 1

    # Single quotes: PHP code, not shell code.
    # shellcheck disable=SC2016
    mapfile -t versions < <(printf '%s' "$json" | "php${RECORD_PHP_VERSION}" -r '
$d = json_decode(stream_get_contents(STDIN), true) ?: [];
$v = array_values(array_filter((array) ($d["versions"] ?? []), fn($x) => preg_match("/^[0-9]+\\.[0-9]+\\.[0-9]+$/", (string) $x)));
usort($v, fn($a, $b) => version_compare($b, $a));
echo implode("\n", array_slice($v, 0, 8)), "\n";
' 2>/dev/null)

    for version in "${versions[@]}"; do
        [[ -n "$version" ]] || continue

        # Single quotes: PHP code, not shell code.
        # shellcheck disable=SC2016
        requires="$(run_real_composer show "$package" "$version" --all --format=json 2>/dev/null |
            "php${RECORD_PHP_VERSION}" -r '
$d = json_decode(stream_get_contents(STDIN), true) ?: [];
echo (string) ($d["requires"]["drupal/core"] ?? ""), "\n";
' 2>/dev/null)"
        [[ -n "$requires" ]] || continue

        if project_semver_satisfies "$target" "$requires"; then
            if project_semver_satisfies "$current" "$requires"; then
                printf '%s\tboth\n' "$version"
            else
                printf '%s\tnew\n' "$version"
            fi
            return 0
        fi
    done

    return 1
}

# "^2.1" for release 2.1.3.
get_caret_constraint() {
    local major="${1%%.*}"
    local rest="${1#*.}"

    printf '^%s.%s\n' "$major" "${rest%%.*}"
}

# Option 3: the composer require commands for the releases found, run
# now. The ones that work on the current core first (-W installs them),
# then the ones that only allow the new release (--no-update): Composer
# could not resolve the others after those. Then the run stops, for a
# commit and a new --upgrade.
run_blocker_requires() {
    local machine_name="$1"
    local package
    local version
    local mode
    local m
    local -a done_packages=()

    for mode in both new; do
        while IFS=$'\t' read -r package version m; do
            [[ "$m" == "$mode" ]] || continue

            if [[ "$mode" == "both" ]]; then
                run_logged "Installing $package $(get_caret_constraint "$version") (composer require -W)" \
                    run_real_composer require "$package:$(get_caret_constraint "$version")" -W || {
                    echo "[FAILED] $package was not changed (Composer put composer.json back)."
                    break 2
                }
            else
                run_logged "Allowing $package $(get_caret_constraint "$version") (composer require --no-update)" \
                    run_real_composer require "$package:$(get_caret_constraint "$version")" --no-update || {
                    echo "[FAILED] $package was not changed."
                    break 2
                }
            fi

            done_packages+=("$package $(get_caret_constraint "$version")")
        done <<< "$UPGRADE_BLOCKER_RELEASES"
    done

    echo

    if [[ "${#done_packages[@]}" -eq 0 ]]; then
        echo "Upgrade stopped; nothing was changed."
        return 1
    fi

    echo "[OK] Changed: $(printf '%s, ' "${done_packages[@]}" | sed 's/, $//')"

    if grep -q $'\tboth$' <<< "$UPGRADE_BLOCKER_RELEASES"; then
        echo "     Releases installed now (-W) can bring database updates: run"
        echo "     $(get_project_drush_hint) updatedb, and check the site."
    fi

    echo "Upgrade stopped here, so these changes get their own commit. Then run the"
    echo "upgrade again: ./install.sh --upgrade $machine_name"
    print_git_commit_hint "Allow $(printf '%s, ' "${done_packages[@]}" | sed 's/, $//') for Drupal $(cut -d. -f1 <<< "$UPDATE_TARGET")"
    return 1
}

# drupal.org projects without a release for the new major that the
# constraints in composer.json allow: the developer decides. Returns 0
# when the upgrade goes on with the lenient plugin (UPGRADE_LENIENT set),
# 1 to stop.
choose_blocking_projects_handling() {
    local blockers="$1"
    local to_major="$2"
    local machine_name="${3:-}"
    local project
    local found
    local version
    local mode
    local answer
    local choices="1-2"

    UPGRADE_BLOCKER_RELEASES=""

    echo
    echo "[BLOCKED] Composer cannot install Drupal $UPDATE_TARGET: these drupal.org projects"
    echo "          have no release for Drupal $to_major that composer.json allows:"

    while IFS= read -r project; do
        echo "            - $project   (https://www.drupal.org/project/${project#drupal/})"

        if found="$(find_release_for_new_core "$project" "$UPDATE_TARGET" "$UPDATE_PREVIOUS_VERSION")"; then
            IFS=$'\t' read -r version mode <<< "$found"
            UPGRADE_BLOCKER_RELEASES+="$project"$'\t'"$version"$'\t'"$mode"$'\n'

            if [[ "$mode" == "both" ]]; then
                echo "              release $version supports Drupal $to_major and $UPDATE_PREVIOUS_VERSION:"
                echo "                composer require '$project:$(get_caret_constraint "$version")' -W"
            else
                echo "              release $version supports Drupal $to_major, not $UPDATE_PREVIOUS_VERSION:"
                echo "                composer require '$project:$(get_caret_constraint "$version")' --no-update"
            fi
        elif [[ -f "$RECORD_PROJECT_PATH/vendor/autoload.php" ]]; then
            echo "              no stable release for Drupal $to_major found (newest 8 looked at)"
        fi
    done <<< "$blockers"

    UPGRADE_BLOCKER_RELEASES="${UPGRADE_BLOCKER_RELEASES%$'\n'}"

    echo
    echo "1) Stop here; nothing is changed. Then, for each of them, one of:"
    echo "   - a newer release supports Drupal $to_major (see its project page):"
    echo "     if it supports the current core too, install it now, then commit:"
    echo "       $(get_project_composer_hint) require '${blockers%%$'\n'*}:^NEW' -W"
    echo "     if it needs the new core, only allow it, then commit; the upgrade installs it:"
    echo "       $(get_project_composer_hint) require '${blockers%%$'\n'*}:^NEW' --no-update"
    echo "     (The first keeps the backup of the upgrade installable on its own; after the"
    echo "     second, the backup needs the earlier composer.json from git, which the"
    echo "     installer looks up: so commit before and after.)"
    echo "   - not needed any more: $(get_project_drush_hint) pm:uninstall <module>, then $(get_project_composer_hint) remove <package>"
    echo "   - a patch for Drupal $to_major from its issue queue (cweagans/composer-patches)"
    echo "2) Install them anyway with the \"lenient\" Composer plugin ($LENIENT_PLUGIN):"
    echo "   Composer then ignores their drupal/core requirement. Their code was not"
    echo "   released for Drupal $to_major, so pages or the whole site may break; the"
    echo "   Upgrade Status findings above show what is known. The plugin and the list"
    echo "   are added to composer.json (remove them once real releases exist). If the"
    echo "   upgrade fails anyway, everything is restored."

    if [[ -n "$UPGRADE_BLOCKER_RELEASES" ]]; then
        choices="1-3"
        echo "3) Run the composer require commands shown above now, then stop: you check"
        echo "   the site and commit, and run --upgrade again. Composer changes composer.json"
        echo "   (and with -W composer.lock and the code, on the current core)."
    fi

    if [[ "$REMOVE_DRY_RUN" -eq 1 ]]; then
        echo
        echo "(Dry run: a real run asks here.)"
        return 1
    fi

    while true; do
        if ! read -r -p "Select [$choices]: " answer; then
            echo
            return 1
        fi

        case "$answer" in
            1) return 1 ;;
            2) mapfile -t UPGRADE_LENIENT <<< "$blockers"; return 0 ;;
            3)
                if [[ "$choices" == "1-3" ]]; then
                    run_blocker_requires "$machine_name"
                    return 2
                fi
                echo "Invalid selection."
                ;;
            *) echo "Invalid selection." ;;
        esac
    done
}

# Composer plugins that the new release brings and composer.json does not
# allow or refuse yet: Composer runs a plugin's code during its commands,
# so it wants a decision. The developer makes it. Returns 1 to stop.
choose_new_plugins_handling() {
    local to_major="$1"
    local entry
    local answer

    echo
    echo "[PLUGINS] Drupal $to_major brings Composer plugins that composer.json does not"
    echo "          mention yet. Composer runs a plugin's code during its commands, so"
    echo "          it stops at them until composer.json allows or refuses them:"

    for entry in "${UPGRADE_NEW_PLUGINS[@]}"; do
        echo "            - ${entry%%|*}: ${entry#*|}"
    done

    echo
    echo "1) Allow them (allow-plugins: true): the packages work as their authors"
    echo "   intended. Usual for well-known packages such as these."
    echo "2) Install them with the plugin part switched off (allow-plugins: false):"
    echo "   their PHP code is installed, but nothing of it runs during Composer"
    echo "   commands. Choose this if you do not know the package."
    echo "3) Stop here; nothing is changed."
    echo "   (You can decide by hand: composer config allow-plugins.NAME true|false)"

    if [[ "$REMOVE_DRY_RUN" -eq 1 ]]; then
        echo
        echo "(Dry run: a real run asks here.)"
        UPGRADE_PLUGIN_DECISION="ask"
        return 0
    fi

    while true; do
        if ! read -r -p "Select [1-3]: " answer; then
            echo
            return 1
        fi

        case "$answer" in
            1) UPGRADE_PLUGIN_DECISION="true"; return 0 ;;
            2) UPGRADE_PLUGIN_DECISION="false"; return 0 ;;
            3) return 1 ;;
            *) echo "Invalid selection." ;;
        esac
    done
}

# The drupal.org projects (not core) whose release the trial changes,
# "  webform 6.2.9 -> 6.3.1" lines for the plan (at most 10).
describe_contrib_changes() {
    local changes
    local count

    changes="$(sed -nE 's/^ *- Upgrading drupal\/([a-z0-9_]+) \(([^ ]+) => ([^ )]+)\).*/\1 \2 -> \3/p' <<< "$1" |
        grep -vE '^core(-[a-z-]+)? ' | sort -u)" || true
    [[ -n "$changes" ]] || return 0
    count="$(grep -c . <<< "$changes")"

    echo "Contrib:       new releases for Drupal ${UPDATE_TARGET%%.*} ($count):"
    head -n 10 <<< "$changes" | sed 's/^/                 /'
    [[ "$count" -gt 10 ]] && echo "                 ... ($((count - 10)) more in the log)"
    return 0
}

# "symfony/runtime, other/plugin" for the plan.
describe_new_plugins() {
    printf '%s\n' "${UPGRADE_NEW_PLUGINS[@]}" | cut -d'|' -f1 | paste -sd',' - | sed 's/,/, /g'
}

# After a failed "composer update": when Composer stopped at a plugin that
# composer.json neither allows nor refuses, say so in plain words.
explain_blocked_plugin_failure() {
    local plugin

    [[ -n "${LOG_FILE:-}" && -f "$LOG_FILE" ]] || return 0
    plugin="$(tail -n 60 "$LOG_FILE" | grep -oE '[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+ contains a Composer plugin which is blocked' | tail -n 1 | cut -d' ' -f1)" || true
    [[ -n "$plugin" ]] || return 0

    echo "[INFO] Composer stopped at the plugin $plugin: composer.json neither allows"
    echo "       nor refuses it. Decide, then run --upgrade again:"
    echo "         composer config allow-plugins.$plugin true    (or false)"
}

# Writes the decision about the new plugins into composer.json.
write_plugin_decisions() {
    local entry

    for entry in "${UPGRADE_NEW_PLUGINS[@]}"; do
        run_real_composer config --no-plugins "allow-plugins.${entry%%|*}" "$UPGRADE_PLUGIN_DECISION" || return 1
    done
}

# Adds the lenient plugin and the list of projects to composer.json and
# installs the plugin, so the next "composer update" uses it.
add_lenient_plugin() {
    local list

    # Single quotes: PHP code, not shell code.
    # shellcheck disable=SC2016
    list="$(printf '%s\n' "${UPGRADE_LENIENT[@]}" | "php${RECORD_PHP_VERSION}" -r '
echo json_encode(array_values(array_filter(array_map("trim", explode("\n", stream_get_contents(STDIN))))), JSON_UNESCAPED_SLASHES);
')" || return 1

    run_logged "Allowing the lenient plugin in composer.json" \
        run_real_composer config --no-plugins "allow-plugins.$LENIENT_PLUGIN" true &&
    run_logged "Listing $(printf '%s ' "${UPGRADE_LENIENT[@]}")for the lenient plugin" \
        run_real_composer config --no-plugins --json --merge extra.drupal-lenient.allowed-list "$list" &&
    run_logged_retrying_network "Adding the lenient plugin ($LENIENT_PLUGIN)" - \
        run_real_composer require "$LENIENT_PLUGIN"
}
