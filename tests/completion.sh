#!/usr/bin/env bash

# Tab completion: options, project names, PHP versions, --dry-run, and
# --install-completion. The registry lives in a temporary directory.

set -euo pipefail

cd "$(dirname "$0")/.."

source lib/output.sh
source lib/completion.sh
source completion/drupal-local-installer.bash

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

export XDG_DATA_HOME="$work_dir/data"
registry="$XDG_DATA_HOME/drupal-local-installer/projects"
mkdir -p "$registry"
printf 'machine_name=alpha\ndrupal_version=11.3.10\n' > "$registry/alpha.conf"
printf 'machine_name=beta\ndrupal_version=10.5.9\n' > "$registry/beta.conf"

pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; exit 1; }

# Completes a command line ("|" marks the end of the word being typed)
# and prints the suggestions on one line.
complete_line() {
    local line="$1"

    read -r -a COMP_WORDS <<< "${line% |}"
    if [[ "$line" == *" |" ]]; then
        COMP_WORDS+=("")
    fi
    COMP_CWORD=$(( ${#COMP_WORDS[@]} - 1 ))
    COMPREPLY=()
    _drupal_local_installer
    printf '%s ' "${COMPREPLY[@]}" | sed 's/ $//'
}

# Test 1: Options, the same as in --help.

usage_options="$(print_usage | grep -oE '^  --[a-z-]+' | tr -d ' ' | sort | paste -sd' ' -)"
completion_options="$(complete_line './install.sh --' | tr ' ' '\n' | sort | paste -sd' ' -)"

if [[ "$completion_options" == "$usage_options" ]]; then
    pass "Every option of --help is completed, and nothing else"
else
    fail "options: completion '$completion_options' vs help '$usage_options'"
fi

if [[ "$(complete_line './install.sh --up')" == "--update --upgrade" &&
      "$(complete_line './install.sh --upg')" == "--upgrade" &&
      "$(complete_line './install.sh --php-s')" == "--php-source" ]]; then
    pass "A started option is completed"
else
    fail "partial option: $(complete_line './install.sh --up')"
fi

# Test 2: Project names after --update, --php, --remove, --unregister.

if [[ "$(complete_line './install.sh --update |')" == "alpha beta" &&
      "$(complete_line './install.sh --php a')" == "alpha" &&
      "$(complete_line './install.sh --remove |')" == "alpha beta" &&
      "$(complete_line './install.sh --unregister b')" == "beta" &&
      "$(complete_line './install.sh --upgrade |')" == "alpha beta" ]]; then
    pass "Registered projects are completed"
else
    fail "projects: $(complete_line './install.sh --update |')"
fi

# Test 3: PHP versions the project's Drupal release supports.

if [[ "$(complete_line './install.sh --php alpha |')" == "8.3 8.4 8.5" &&
      "$(complete_line './install.sh --php beta 8.')" == "8.1 8.2 8.3 8.4" &&
      -z "$(complete_line './install.sh --php nosuch |')" ]]; then
    pass "PHP versions from the compatibility table of each project's Drupal release"
else
    fail "php versions: '$(complete_line './install.sh --php alpha |')' / '$(complete_line './install.sh --php beta 8.')'"
fi

# Test 4: --dry-run where it exists, once.

if [[ "$(complete_line './install.sh --update alpha |')" == "--dry-run" &&
      "$(complete_line './install.sh --php alpha 8.4 |')" == "--dry-run" &&
      "$(complete_line './install.sh --upgrade beta |')" == "--dry-run" &&
      -z "$(complete_line './install.sh --update alpha --dry-run |')" &&
      -z "$(complete_line './install.sh --unregister alpha |')" &&
      -z "$(complete_line './install.sh --list |')" ]]; then
    pass "--dry-run offered after --update/--upgrade/--php/--remove, only once"
else
    fail "dry-run: '$(complete_line './install.sh --update alpha |')'"
fi

# Test 5: Another program called install.sh keeps file name completion.

mkdir -p "$work_dir/other"
if [[ -z "$(complete_line "$work_dir/other/install.sh --|")" ]]; then
    pass "Another install.sh is left alone"
else
    fail "other install.sh completed"
fi

# Test 6: --install-completion writes the file for the user, with the
# installer folder filled in; root is refused.

export BASH_COMPLETION_USER_DIR="$work_dir/bash-completion"
export BASH_COMPLETION_SCRIPT="$work_dir/none"
SCRIPT_DIR="$PWD"

id() { if [[ "${1:-}" == "-u" ]]; then echo 1000; else command id "$@"; fi; }

if output="$(run_install_completion)" &&
   target="$BASH_COMPLETION_USER_DIR/completions/install.sh" &&
   [[ -f "$target" && "$(stat -c '%a' "$target")" == "644" ]] &&
   grep -qxF "_dli_installer_dir=\"$PWD\"" "$target" &&
   [[ "$output" == *"[OK] Tab completion installed: $target"* &&
      "$output" == *"bash-completion is not installed"* ]]; then
    pass "--install-completion: file for the user, installer folder filled in"
else
    fail "install: $output"
fi

repo_dir="$PWD"
installed_result="$(cd "$work_dir" && bash -c "source '$target'; COMP_WORDS=('$repo_dir/install.sh' '--php' 'alpha' ''); COMP_CWORD=3; _drupal_local_installer; echo \"\${COMPREPLY[*]}\"")"

if [[ "$installed_result" == "8.3 8.4 8.5" ]]; then
    pass "The installed file works from any folder"
else
    fail "installed file: '$installed_result'"
fi

# bash-completion leaves a minimal spec on "./install.sh" when Tab was
# pressed before the file existed; sourcing the file must replace it.
registered="$(bash -c "complete -F _comp_complete_minimal ./install.sh; source '$target'; complete -p ./install.sh; complete -p '$repo_dir/install.sh'; complete -p install.sh")"

if [[ "$registered" == *"_drupal_local_installer ./install.sh"* &&
      "$registered" == *"_drupal_local_installer $repo_dir/install.sh"* &&
      "$registered" == *"_drupal_local_installer install.sh"* ]]; then
    pass "Registered for ./install.sh, the full path and install.sh (replaces a minimal spec)"
else
    fail "registration: $registered"
fi

id() { if [[ "${1:-}" == "-u" ]]; then echo 0; else command id "$@"; fi; }

if output="$(run_install_completion)"; then
    fail "Installed as root"
elif [[ "$output" == *"as your normal user"* ]]; then
    pass "Refused as root (completion is per user)"
else
    fail "root: $output"
fi

echo "[SUCCESS] Completion tests passed."
