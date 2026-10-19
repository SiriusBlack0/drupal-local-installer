#!/usr/bin/env bash

# Security advisories that make Composer refuse an update target.

# Composer 2.9+ refuses packages with published security advisories. The
# lines of its message that name the blocked packages, shortened.
get_blocking_advisories() {
    grep -oE 'found [A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\[[^]]*\] but these were not loaded, because they are affected by security advisories \([^)]*\)' <<< "$1" |
        sed -E 's/^found ([^[]+)\[([^]]*)\].*advisories \((.*)\)$/\1 \2: \3/' | tr -d '"' | sort -u
}

# Explains the block in plain words. In a real run the user may accept
# the advisories for this one update (typed "accept"); returns 0 then.
explain_blocking_advisories() {
    local blocked="$1"
    local answer

    echo
    echo "[SECURITY] Drupal $UPDATE_TARGET needs package versions that have published"
    echo "           security advisories, so Composer refuses to install them:"
    printf '%s\n' "$blocked" | sed 's/^/             - /'
    echo "           Details: https://packagist.org/security-advisories/"

    if grep -qE '^drupal/core(-recommended)? ' <<< "$blocked"; then
        echo
        echo "           Drupal core $UPDATE_TARGET itself has these advisories: its line"
        echo "           ($(echo "$UPDATE_TARGET" | cut -d. -f1,2)) has no release with them fixed (often because it"
        echo "           no longer gets security fixes)."
    fi

    if [[ -n "$UPDATE_ALTERNATIVE" ]]; then
        echo "           Try the other choice first: Drupal $UPDATE_ALTERNATIVE."
    fi
    echo
    echo "           Usually another target is the better choice (a newer minor"
    echo "           brings fixed versions). You may still install this one: the"
    echo "           advisories are then accepted for this update only; composer.json"
    echo "           is not changed and the registry notes what was accepted."

    if [[ "$REMOVE_DRY_RUN" -eq 1 ]]; then
        echo "           (Dry run: the plan below shows the update with them accepted.)"
        return 0
    fi

    echo
    if ! read -r -p "Type 'accept' to install it with these advisories, anything else to stop: " answer ||
       [[ "$answer" != "accept" ]]; then
        echo "Update cancelled; nothing was changed."
        return 1
    fi
}
