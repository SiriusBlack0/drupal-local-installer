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

# drupal.org projects without a release for the new major that the
# constraints in composer.json allow: the developer decides. Returns 0
# when the upgrade goes on with the lenient plugin (UPGRADE_LENIENT set),
# 1 to stop.
choose_blocking_projects_handling() {
    local blockers="$1"
    local to_major="$2"
    local project
    local answer

    echo
    echo "[BLOCKED] Composer cannot install Drupal $UPDATE_TARGET: these drupal.org projects"
    echo "          have no release for Drupal $to_major that composer.json allows:"

    while IFS= read -r project; do
        echo "            - $project   (https://www.drupal.org/project/${project#drupal/})"
    done <<< "$blockers"

    echo
    echo "1) Stop here; nothing is changed. Then, for each of them, one of:"
    echo "   - a newer release supports Drupal $to_major: allow it in composer.json, e.g."
    echo "     composer require '${blockers%%$'\n'*}:^NEW' --no-update (see its project page)"
    echo "   - not needed any more: ./drush pm:uninstall <module>, then composer remove <package>"
    echo "   - a patch for Drupal $to_major from its issue queue (cweagans/composer-patches)"
    echo "2) Install them anyway with the \"lenient\" Composer plugin ($LENIENT_PLUGIN):"
    echo "   Composer then ignores their drupal/core requirement. Their code was not"
    echo "   released for Drupal $to_major, so pages or the whole site may break; the"
    echo "   Upgrade Status findings above show what is known. The plugin and the list"
    echo "   are added to composer.json (remove them once real releases exist). If the"
    echo "   upgrade fails anyway, everything is restored."

    if [[ "$REMOVE_DRY_RUN" -eq 1 ]]; then
        echo
        echo "(Dry run: a real run asks here.)"
        return 1
    fi

    while true; do
        if ! read -r -p "Select [1-2]: " answer; then
            echo
            return 1
        fi

        case "$answer" in
            1) return 1 ;;
            2) mapfile -t UPGRADE_LENIENT <<< "$blockers"; return 0 ;;
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
