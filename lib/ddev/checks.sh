#!/usr/bin/env bash

# ==================================================
# Is this computer ready for DDEV?
#
# DDEV runs on a Docker engine: docker-ce from Docker's own package
# source (what DDEV recommends, also inside WSL2), or Docker Desktop with
# its WSL integration. It needs "docker compose", Docker without sudo
# (the docker group), and, in WSL, systemd so that the engine starts.
# Its router answers on ports of its own: 80/443 belong to the system's
# Nginx (native projects), so DDEV gets 8080/8443 (global setting).
# Only reads; check_ddev_readiness fills the DDEV_* values below.
# ==================================================

DDEV_ROUTER_PORT_PAIRS=("8080/8443" "8081/8444" "8880/8843")

DDEV_STATE_DOCKER=""      # ok | missing | stopped | no-access
DDEV_DOCKER_VERSION=""
DDEV_DOCKER_PROVIDER=""   # docker-ce | docker-desktop | other
DDEV_STATE_COMPOSE=""     # ok | missing
DDEV_COMPOSE_VERSION=""
DDEV_STATE_GROUP=""       # ok | missing | relogin
DDEV_STATE_SYSTEMD=""     # ok | missing (WSL without systemd)
DDEV_STATE_DDEV=""        # ok | missing
DDEV_VERSION=""
DDEV_STATE_MKCERT=""      # ok | missing | no-ca
DDEV_STATE_PORTS=""       # set | planned | busy
DDEV_ROUTER_PORTS=""      # "8080/8443"

# The developer's home folder (also when the installer runs with sudo).
get_project_user_home() {
    local home

    home="$(getent passwd "$PROJECT_USER" 2>/dev/null | cut -d: -f6)"
    printf '%s\n' "${home:-$HOME}"
}

# Runs a command as the developer, with the developer's home: Docker,
# DDEV and mkcert keep their settings there.
run_as_developer() {
    run_as_project_user "$PROJECT_USER" env HOME="${DDEV_HOME:-$(get_project_user_home)}" "$@"
}

# WSL (Windows Subsystem for Linux).
is_wsl() {
    grep -qi microsoft "${PROC_VERSION_FILE:-/proc/version}" 2>/dev/null
}

get_ddev_global_config() {
    printf '%s/.ddev/global_config.yaml\n' "${DDEV_HOME:-$(get_project_user_home)}"
}

# A value of DDEV's global configuration (empty when not set).
get_ddev_global_value() {
    local file

    file="$(get_ddev_global_config)"
    [[ -f "$file" ]] || return 0
    awk -v key="$1" '
        $1 == key ":" { v = $2; gsub(/["\047]/, "", v); print v; exit }' "$file"
}

# Is something listening on TCP port $1 (any address)?
is_port_in_use() {
    ss -ltnH 2>/dev/null | awk -v p="$1" '{ n = split($4, a, ":"); if (a[n] == p) { found = 1 } } END { exit !found }'
}

# The router ports: the ones set in DDEV's global configuration, or the
# first free pair of DDEV_ROUTER_PORT_PAIRS.
check_ddev_router_ports() {
    local http
    local https
    local pair

    http="$(get_ddev_global_value router_http_port)"
    https="$(get_ddev_global_value router_https_port)"

    if [[ "$http" =~ ^[0-9]+$ && "$https" =~ ^[0-9]+$ ]]; then
        DDEV_STATE_PORTS="set"
        DDEV_ROUTER_PORTS="$http/$https"
        return 0
    fi

    for pair in "${DDEV_ROUTER_PORT_PAIRS[@]}"; do
        if ! is_port_in_use "${pair%/*}" && ! is_port_in_use "${pair#*/}"; then
            DDEV_STATE_PORTS="planned"
            DDEV_ROUTER_PORTS="$pair"
            return 0
        fi
    done

    DDEV_STATE_PORTS="busy"
    DDEV_ROUTER_PORTS=""
}

check_ddev_docker() {
    local info

    DDEV_DOCKER_VERSION=""
    DDEV_DOCKER_PROVIDER=""
    DDEV_STATE_GROUP="missing"

    if ! command -v docker > /dev/null 2>&1; then
        DDEV_STATE_DOCKER="missing"
    elif info="$(run_as_developer docker info --format '{{.ServerVersion}}|{{.OperatingSystem}}' 2>/dev/null)" && [[ "$info" == *"|"* ]]; then
        DDEV_STATE_DOCKER="ok"
        DDEV_DOCKER_VERSION="${info%%|*}"

        case "${info#*|}" in
            *"Docker Desktop"*) DDEV_DOCKER_PROVIDER="docker-desktop" ;;
            *) DDEV_DOCKER_PROVIDER="docker-ce" ;;
        esac

        # Docker answers without sudo: nothing more to do for access.
        DDEV_STATE_GROUP="ok"
    elif ! is_service_active docker; then
        DDEV_STATE_DOCKER="stopped"
    else
        DDEV_STATE_DOCKER="no-access"
    fi

    if [[ "$DDEV_STATE_GROUP" != "ok" ]] && grep -qx docker <<< "$(id -nG "$PROJECT_USER" 2>/dev/null | tr ' ' '\n')"; then
        # In the group, but this login session started before that.
        if [[ "$DDEV_STATE_DOCKER" == "no-access" ]]; then
            DDEV_STATE_GROUP="relogin"
        else
            DDEV_STATE_GROUP="ok"
        fi
    fi

    if command -v docker > /dev/null 2>&1 &&
       DDEV_COMPOSE_VERSION="$(run_as_developer docker compose version --short 2>/dev/null)" && [[ -n "$DDEV_COMPOSE_VERSION" ]]; then
        DDEV_STATE_COMPOSE="ok"
    else
        DDEV_COMPOSE_VERSION=""
        DDEV_STATE_COMPOSE="missing"
    fi

    if is_wsl && ! has_systemd && [[ "$DDEV_DOCKER_PROVIDER" != "docker-desktop" ]]; then
        DDEV_STATE_SYSTEMD="missing"
    else
        DDEV_STATE_SYSTEMD="ok"
    fi
}

check_ddev_tools() {
    local caroot

    if command -v ddev > /dev/null 2>&1; then
        DDEV_STATE_DDEV="ok"
        DDEV_VERSION="$(run_as_developer ddev --version 2>/dev/null | awk '{ print $NF; exit }')"
    else
        DDEV_STATE_DDEV="missing"
        DDEV_VERSION=""
    fi

    if ! command -v mkcert > /dev/null 2>&1; then
        DDEV_STATE_MKCERT="missing"
    elif caroot="$(run_as_developer mkcert -CAROOT 2>/dev/null)" && [[ -n "$caroot" && -f "$caroot/rootCA.pem" ]]; then
        DDEV_STATE_MKCERT="ok"
    else
        DDEV_STATE_MKCERT="no-ca"
    fi
}

check_ddev_readiness() {
    check_ddev_docker
    check_ddev_tools
    check_ddev_router_ports
}

# Everything in place for DDEV projects.
is_ddev_ready() {
    [[ "$DDEV_STATE_DOCKER" == "ok" && "$DDEV_STATE_COMPOSE" == "ok" && "$DDEV_STATE_GROUP" == "ok" &&
       "$DDEV_STATE_SYSTEMD" == "ok" && "$DDEV_STATE_DDEV" == "ok" && "$DDEV_STATE_MKCERT" == "ok" &&
       "$DDEV_STATE_PORTS" == "set" ]]
}

print_ddev_readiness() {
    local docker_line
    local ports_line

    case "$DDEV_STATE_DOCKER" in
        ok) docker_line="[OK] $DDEV_DOCKER_VERSION ($([[ "$DDEV_DOCKER_PROVIDER" == "docker-desktop" ]] && echo "Docker Desktop" || echo "Docker Engine"))" ;;
        missing) docker_line="[MISSING] no Docker engine" ;;
        stopped) docker_line="[STOPPED] installed, the docker service is not running" ;;
        no-access) docker_line="[NO ACCESS] running, but not usable without sudo" ;;
    esac

    case "$DDEV_STATE_PORTS" in
        set) ports_line="[OK] $DDEV_ROUTER_PORTS (DDEV's global configuration)" ;;
        planned) ports_line="[TO SET] $DDEV_ROUTER_PORTS (80/443 stay with the system's Nginx)" ;;
        busy) ports_line="[BLOCKED] 8080/8443, 8081/8444 and 8880/8843 are all in use" ;;
    esac

    echo "System:       $(get_ubuntu_version 2>/dev/null | sed 's/^/Ubuntu /')$(is_wsl && echo " (WSL)")"
    echo "Docker:       $docker_line"
    [[ "$DDEV_STATE_SYSTEMD" == "missing" ]] && echo "systemd:      [MISSING] WSL without systemd: the Docker engine cannot start"
    echo "Compose:      $([[ "$DDEV_STATE_COMPOSE" == "ok" ]] && echo "[OK] $DDEV_COMPOSE_VERSION" || echo "[MISSING] docker compose")"

    case "$DDEV_STATE_GROUP" in
        ok) echo "docker group: [OK] Docker without sudo" ;;
        missing) echo "docker group: [MISSING] $PROJECT_USER is not in the docker group" ;;
        relogin) echo "docker group: [LOG IN AGAIN] $PROJECT_USER is in the group; this session started before" ;;
    esac

    echo "DDEV:         $([[ "$DDEV_STATE_DDEV" == "ok" ]] && echo "[OK] $DDEV_VERSION" || echo "[MISSING]")"

    case "$DDEV_STATE_MKCERT" in
        ok) echo "mkcert:       [OK] local certificate authority installed (https)" ;;
        missing) echo "mkcert:       [MISSING] (comes with DDEV, or the mkcert package)" ;;
        no-ca) echo "mkcert:       [TO SET] the local certificate authority (mkcert -install)" ;;
    esac

    echo "Router ports: $ports_line"
}
