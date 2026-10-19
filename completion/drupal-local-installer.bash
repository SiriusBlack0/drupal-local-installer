# Bash completion (Tab) for drupal-local-installer: ./install.sh
#
# Installed for the current user by: ./install.sh --install-completion
# Completes the options, the registered projects (--update, --upgrade, --php,
# --remove, --unregister), the PHP versions the project's Drupal release
# supports (--php NAME <Tab>) and --dry-run.

# The installer folder; filled in when the file is installed.
_dli_installer_dir="__DLI_DIR__"

# Used straight from the repository (tests, or "source" by hand).
if [[ ! -f "$_dli_installer_dir/config/compatibility.conf" ]]; then
    _dli_installer_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

_dli_registry_dir() {
    printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/drupal-local-installer/projects"
}

# Registered project names.
_dli_projects() {
    local record

    for record in "$(_dli_registry_dir)"/*.conf; do
        [[ -f "$record" ]] && basename "$record" .conf
    done
}

# PHP versions the project's Drupal release supports
# (config/compatibility.conf).
_dli_php_versions() {
    local record
    local version
    local minor

    record="$(_dli_registry_dir)/$1.conf"
    [[ "$1" =~ ^[a-z0-9_]+$ && -f "$record" ]] || return 0

    version="$(sed -n 's/^drupal_version=//p' "$record" | head -n 1)"
    minor="$(echo "$version" | cut -d. -f1,2)"
    [[ "$minor" =~ ^[0-9]+\.[0-9]+$ ]] || return 0

    awk -F'|' -v minor="$minor" '$1 == minor { gsub(",", " ", $2); print $2 }' \
        "$_dli_installer_dir/config/compatibility.conf" 2>/dev/null
}

_drupal_local_installer() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local prev="${COMP_WORDS[COMP_CWORD - 1]:-}"
    local command_dir
    local action=""
    local action_index=0
    local name=""
    local word
    local i
    local options="--list --scan --check-updates --update --upgrade --php --php-source --remove --unregister --install-completion --verbose --step --help"

    COMPREPLY=()

    # Only for this installer: another program called install.sh keeps the
    # normal file name completion.
    command_dir="$(dirname -- "${COMP_WORDS[0]}")"
    if [[ "${COMP_WORDS[0]}" != */* ]]; then
        command_dir="$(dirname -- "$(type -P "${COMP_WORDS[0]}" 2>/dev/null || echo .)")"
    fi

    if [[ ! -f "$command_dir/lib/update.sh" || ! -f "$command_dir/config/compatibility.conf" ]]; then
        compopt -o default 2>/dev/null
        return 0
    fi

    for (( i = 1; i < COMP_CWORD; i++ )); do
        case "${COMP_WORDS[i]}" in
            --update|--upgrade|--remove|--unregister|--php)
                action="${COMP_WORDS[i]}"
                action_index="$i"
                name="${COMP_WORDS[i + 1]:-}"
                ;;
            --list|--scan|--check-updates|--php-source|--install-completion|--help)
                action="${COMP_WORDS[i]}"
                action_index="$i"
                ;;
        esac
    done

    case "$prev" in
        --update|--upgrade|--remove|--unregister|--php)
            mapfile -t COMPREPLY < <(compgen -W "$(_dli_projects)" -- "$cur")
            return 0
            ;;
    esac

    if [[ "$action" == "--php" && $(( COMP_CWORD - action_index )) -eq 2 ]]; then
        mapfile -t COMPREPLY < <(compgen -W "$(_dli_php_versions "$name")" -- "$cur")
        return 0
    fi

    case "$action" in
        --update|--upgrade|--remove|--php)
            for word in "${COMP_WORDS[@]}"; do
                [[ "$word" == "--dry-run" ]] && return 0
            done
            mapfile -t COMPREPLY < <(compgen -W "--dry-run" -- "$cur")
            ;;
        "")
            mapfile -t COMPREPLY < <(compgen -W "$options" -- "$cur")
            ;;
    esac

    return 0
}

# Registered for "./install.sh" and the full path too, not only for
# "install.sh": bash prefers a spec for the exact word typed, and
# bash-completion leaves a minimal one on "./install.sh" when Tab was
# pressed before this file existed (then nothing would be completed).
complete -F _drupal_local_installer install.sh ./install.sh "$_dli_installer_dir/install.sh"
