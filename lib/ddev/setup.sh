#!/usr/bin/env bash

# ==================================================
# Make this computer ready for DDEV (--ddev-setup [--dry-run])
#
# Shows what is there, plans what is missing, and does it after one "y":
# the package sources of Docker and DDEV, their packages (simulated
# first; nothing is ever removed), the docker service, the docker group,
# the router ports, mkcert's local certificate authority. Every sudo step
# comes first, then the steps as the developer. Nginx, PHP-FPM, the
# databases and the projects are not touched.
# ==================================================

DDEV_PLAN_SOURCES=()      # docker, ddev
DDEV_PLAN_START_DOCKER=0
DDEV_PLAN_GROUP=0
DDEV_PLAN_PORTS=""        # "8080/8443"
DDEV_PLAN_MKCERT=0
DDEV_PLAN_BLOCKED=()      # what the installer cannot do, with the way out

# Is apt's package $1 installed?
is_deb_installed() {
    [[ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" == *"install ok installed"* ]]
}

plan_ddev_setup() {
    DDEV_PLAN_SOURCES=()
    DDEV_PLAN_START_DOCKER=0
    DDEV_PLAN_GROUP=0
    DDEV_PLAN_PORTS=""
    DDEV_PLAN_MKCERT=0
    DDEV_PLAN_BLOCKED=()
    INSTALL_PACKAGES=()

    if [[ "$DDEV_STATE_SYSTEMD" == "missing" ]]; then
        DDEV_PLAN_BLOCKED+=("WSL without systemd: the Docker engine needs it. In WSL: add to /etc/wsl.conf
     [boot]
     systemd=true
   then in Windows (PowerShell): wsl --shutdown, open the terminal again, run --ddev-setup again.
   (Or Docker Desktop with its WSL integration for this distribution.)")
    fi

    case "$DDEV_STATE_DOCKER" in
        missing)
            if [[ "$DDEV_STATE_SYSTEMD" == "ok" ]]; then
                has_docker_apt_source || DDEV_PLAN_SOURCES+=(docker)
                INSTALL_PACKAGES+=("${DOCKER_PACKAGES[@]}")
            fi
            ;;
        stopped)
            [[ "$DDEV_STATE_SYSTEMD" == "ok" ]] && DDEV_PLAN_START_DOCKER=1
            ;;
    esac

    # Docker without compose: the plugin of the same source.
    if [[ "$DDEV_STATE_DOCKER" != "missing" && "$DDEV_STATE_COMPOSE" == "missing" ]]; then
        if is_deb_installed docker.io; then
            INSTALL_PACKAGES+=(docker-compose-v2)
        elif [[ "$DDEV_DOCKER_PROVIDER" != "docker-desktop" ]]; then
            has_docker_apt_source || DDEV_PLAN_SOURCES+=(docker)
            INSTALL_PACKAGES+=(docker-compose-plugin)
        else
            DDEV_PLAN_BLOCKED+=("Docker Desktop without \"docker compose\": update Docker Desktop.")
        fi
    fi

    if [[ "$DDEV_STATE_GROUP" == "missing" && "$DDEV_DOCKER_PROVIDER" != "docker-desktop" && "$DDEV_STATE_SYSTEMD" == "ok" ]]; then
        DDEV_PLAN_GROUP=1
    fi

    if [[ "$DDEV_STATE_DDEV" == "missing" ]]; then
        has_ddev_apt_source || DDEV_PLAN_SOURCES+=(ddev)
        INSTALL_PACKAGES+=(ddev)
    elif [[ "$DDEV_STATE_MKCERT" == "missing" ]]; then
        INSTALL_PACKAGES+=(mkcert)
    fi

    [[ "$DDEV_STATE_MKCERT" != "ok" ]] && DDEV_PLAN_MKCERT=1

    case "$DDEV_STATE_PORTS" in
        planned) DDEV_PLAN_PORTS="$DDEV_ROUTER_PORTS" ;;
        busy) DDEV_PLAN_BLOCKED+=("No free pair of router ports. Choose two free ports yourself:
     ddev config global --router-http-port=<port> --router-https-port=<port>") ;;
    esac
}

has_ddev_plan() {
    [[ "${#DDEV_PLAN_SOURCES[@]}" -gt 0 || "${#INSTALL_PACKAGES[@]}" -gt 0 || "$DDEV_PLAN_START_DOCKER" -eq 1 ||
       "$DDEV_PLAN_GROUP" -eq 1 || -n "$DDEV_PLAN_PORTS" || "$DDEV_PLAN_MKCERT" -eq 1 ]]
}

needs_ddev_sudo() {
    [[ "${#DDEV_PLAN_SOURCES[@]}" -gt 0 || "${#INSTALL_PACKAGES[@]}" -gt 0 || "$DDEV_PLAN_START_DOCKER" -eq 1 ||
       "$DDEV_PLAN_GROUP" -eq 1 || "$DDEV_PLAN_MKCERT" -eq 1 ]]
}

print_ddev_plan() {
    local step=1
    local name

    echo "What will change:"

    for name in "${DDEV_PLAN_SOURCES[@]}"; do
        case "$name" in
            docker)
                echo "  $step. Docker's package source: $(get_apt_etc_dir)/sources.list.d/docker.sources"
                echo "     ($DOCKER_APT_URL), key $(get_apt_keyrings_dir)/docker.asc, checked"
                echo "     against Docker's published fingerprint"
                ;;
            ddev)
                echo "  $step. DDEV's package source: $(get_apt_etc_dir)/sources.list.d/ddev.sources"
                echo "     ($DDEV_APT_URL), key $(get_apt_keyrings_dir)/ddev.asc"
                ;;
        esac
        step=$((step + 1))
    done

    if [[ "${#DDEV_PLAN_SOURCES[@]}" -gt 0 ]]; then
        echo "     apt trusts each key for its own source only (Signed-By); a source"
        echo "     that apt cannot use is removed again."
    fi

    if [[ "${#INSTALL_PACKAGES[@]}" -gt 0 ]]; then
        echo "  $step. Packages: ${INSTALL_PACKAGES[*]}"
        echo "     (simulated first; apt never removes anything for them)"
        step=$((step + 1))
    fi

    if [[ "$DDEV_PLAN_START_DOCKER" -eq 1 ]]; then
        echo "  $step. Start the docker service"
        step=$((step + 1))
    fi

    if [[ "$DDEV_PLAN_GROUP" -eq 1 ]]; then
        echo "  $step. Add $PROJECT_USER to the docker group: Docker without sudo, which DDEV"
        echo "     needs. Members can start any container as root, so the group is"
        echo "     as much as sudo; usual on a computer for development. It takes"
        echo "     effect after logging in again."
        step=$((step + 1))
    fi

    if [[ -n "$DDEV_PLAN_PORTS" ]]; then
        echo "  $step. DDEV's router on ports ${DDEV_PLAN_PORTS%/*} (http) and ${DDEV_PLAN_PORTS#*/} (https):"
        echo "     ddev config global (in ~/.ddev/global_config.yaml). 80/443 stay with"
        echo "     the system's Nginx; DDEV sites: https://<name>.ddev.site:${DDEV_PLAN_PORTS#*/}"
        step=$((step + 1))
    fi

    if [[ "$DDEV_PLAN_MKCERT" -eq 1 ]]; then
        echo "  $step. mkcert -install: a local certificate authority, so that the browser"
        echo "     trusts https://<name>.ddev.site (written to the system's store)."
        is_wsl && echo "     Browsers in Windows need it too: README, \"DDEV in WSL\"."
    fi

    echo "Not changed: Nginx, PHP-FPM, the databases and the projects."
}

# Adds the planned package sources and reads the package lists. Undoes
# a source (and its key) that apt cannot use.
add_ddev_package_sources() {
    local codename
    local architecture
    local work_dir
    local name
    local key_file
    local source_file
    local url
    local status=0
    local -a added=()

    [[ "${#DDEV_PLAN_SOURCES[@]}" -gt 0 ]] || return 0

    if ! command -v curl > /dev/null || ! command -v gpg > /dev/null; then
        echo "[ERROR] curl and gpg are needed: sudo apt-get install curl gnupg"
        return 1
    fi

    codename="$(get_ubuntu_codename)" || { echo "[ERROR] Could not read the Ubuntu release name."; return 1; }
    architecture="$(dpkg --print-architecture)"
    work_dir="$(mktemp -d)"

    for name in "${DDEV_PLAN_SOURCES[@]}"; do
        key_file="$(get_apt_keyrings_dir)/$name.asc"
        source_file="$(get_apt_etc_dir)/sources.list.d/$name.sources"

        case "$name" in
            docker)
                download_repository_key Docker "$DOCKER_KEY_URL" "$work_dir/$name.asc" "$DOCKER_KEY_FINGERPRINT" || status=1
                generate_repository_source "Docker Engine" "$DOCKER_APT_URL" "$codename" stable "$key_file" "$architecture" > "$work_dir/$name.sources"
                ;;
            ddev)
                download_repository_key DDEV "$DDEV_KEY_URL" "$work_dir/$name.asc" || status=1
                generate_repository_source DDEV "$DDEV_APT_URL" stable main "$key_file" > "$work_dir/$name.sources"
                ;;
        esac

        [[ "$status" -eq 0 ]] || break

        if ! install_repository_files "$work_dir/$name.asc" "$key_file" "$work_dir/$name.sources" "$source_file"; then
            echo "[ERROR] Could not write $source_file"
            status=1
            break
        fi

        added+=("$name")
        echo "[OK] Package source added: $source_file"
    done

    rm -rf "$work_dir"

    local policy=""

    if [[ "$status" -eq 0 ]]; then
        run_logged "Reading the package lists (apt-get update)" sudo apt-get update || true
        policy="$(apt-cache policy 2>/dev/null)" || true
    fi

    for name in "${added[@]}"; do
        case "$name" in
            docker) url="$DOCKER_APT_URL" ;;
            ddev) url="$DDEV_APT_URL" ;;
        esac

        if [[ "$status" -ne 0 ]] || ! grep -qF "$url" <<< "$policy"; then
            sudo rm -f -- "$(get_apt_etc_dir)/sources.list.d/$name.sources" "$(get_apt_keyrings_dir)/$name.asc"
            echo "[ERROR] The $name package source was removed again (apt could not use it)."
            status=1
        fi
    done

    return "$status"
}

# Simulates, then installs INSTALL_PACKAGES; a simulation that would
# remove anything stops here.
install_ddev_packages() {
    local simulation

    [[ "${#INSTALL_PACKAGES[@]}" -gt 0 ]] || return 0

    if ! simulation="$(simulate_apt_package_installation 2>&1)"; then
        printf '%s\n' "$simulation" | tail -n 12
        return 1
    fi

    echo "[OK] apt: $(count_simulated_installs) packages with their dependencies; nothing is removed"
    execute_apt_package_installation
}

# The docker group counts from the next login session. A new terminal of
# the same desktop session is not enough: it inherits the old groups.
print_relogin_advice() {
    echo "[LOG IN AGAIN] $PROJECT_USER is in the docker group, but this login session"
    echo "               started before that, and a new terminal of the same session"
    echo "               keeps its old groups. Either:"
    if is_wsl; then
        echo "               - close every WSL terminal, run \"wsl --shutdown\" in Windows,"
        echo "                 open the terminal again;"
    else
        echo "               - log out of the desktop and in again (or restart);"
    fi
    echo "               - or, for now, in this terminal: su - $PROJECT_USER"
    echo "                 (a new login with the new groups)."
    echo "               Then: ./install.sh --ddev-setup"
}

run_ddev_setup() {
    local answer

    echo
    echo "======================================"
    echo "  DDEV readiness"
    echo "======================================"
    echo

    check_ddev_readiness
    print_ddev_readiness
    plan_ddev_setup
    echo

    local blocked
    for blocked in "${DDEV_PLAN_BLOCKED[@]}"; do
        echo "[BLOCKED] $blocked"
    done

    if ! has_ddev_plan; then
        if is_ddev_ready; then
            echo "[OK] Ready for DDEV projects."
            return 0
        fi

        if [[ "$DDEV_STATE_GROUP" == "relogin" ]]; then
            print_relogin_advice
        fi

        return 1
    fi

    print_ddev_plan

    if [[ "$REMOVE_DRY_RUN" -eq 1 ]]; then
        echo
        echo "[DRY RUN] Nothing was changed."
        return 0
    fi

    echo
    if ! read -r -p "Make these changes? [y/N]: " answer || [[ ! "$answer" =~ ^[Yy]$ ]]; then
        echo "Nothing was changed."
        return 1
    fi

    # Every sudo step first.
    if needs_ddev_sudo; then
        require_sudo || return 1
    fi

    add_ddev_package_sources || { echo "Stopped; no package was installed."; return 1; }
    install_ddev_packages || { echo "Stopped: the packages were not installed."; return 1; }

    # mkcert may not come with the ddev package.
    if [[ " ${INSTALL_PACKAGES[*]} " == *" ddev "* ]] && ! command -v mkcert > /dev/null 2>&1; then
        INSTALL_PACKAGES=(mkcert)
        install_ddev_packages || echo "[WARNING] mkcert was not installed: https needs it (sudo apt-get install mkcert)."
    fi

    if [[ "$DDEV_PLAN_START_DOCKER" -eq 1 ]]; then
        if run_service_start docker; then
            echo "[OK] docker service started"
        else
            echo "[WARNING] The docker service did not start: sudo systemctl status docker"
        fi
    fi

    if [[ "$DDEV_PLAN_GROUP" -eq 1 ]]; then
        if sudo usermod -aG docker "$PROJECT_USER"; then
            echo "[OK] $PROJECT_USER added to the docker group (after logging in again)"
        else
            echo "[WARNING] Could not add $PROJECT_USER to the docker group: sudo usermod -aG docker $PROJECT_USER"
        fi
    fi

    if [[ "$DDEV_PLAN_MKCERT" -eq 1 ]]; then
        if command -v mkcert > /dev/null 2>&1 && run_logged "Local certificate authority (mkcert -install)" run_as_developer mkcert -install; then
            :
        else
            echo "[WARNING] mkcert -install did not run; later: mkcert -install"
        fi
    fi

    # As the developer: DDEV's own configuration.
    if [[ -n "$DDEV_PLAN_PORTS" ]]; then
        if command -v ddev > /dev/null 2>&1 &&
           run_logged "DDEV router on ports $DDEV_PLAN_PORTS (ddev config global)" run_as_developer \
               ddev config global --router-http-port="${DDEV_PLAN_PORTS%/*}" --router-https-port="${DDEV_PLAN_PORTS#*/}"; then
            :
        else
            echo "[WARNING] The router ports were not set: ddev config global --router-http-port=${DDEV_PLAN_PORTS%/*} --router-https-port=${DDEV_PLAN_PORTS#*/}"
        fi
    fi

    echo
    echo "Now:"
    check_ddev_readiness
    print_ddev_readiness
    echo

    if is_ddev_ready; then
        echo "[OK] Ready for DDEV projects."
        return 0
    fi

    if [[ "$DDEV_STATE_GROUP" == "relogin" || "$DDEV_PLAN_GROUP" -eq 1 ]]; then
        print_relogin_advice
        return 0
    fi

    echo "[NOT READY] See the lines above; ./install.sh --ddev-setup checks again."
    return 1
}
