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

# The upgrade, tried on copies of composer.json and composer.lock.
# Prints Composer's output and returns its status; changes nothing.
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
            --with-all-dependencies --dry-run "${UPDATE_EXTRA_ARGS[@]}"
    } 2>&1 || status=$?

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
