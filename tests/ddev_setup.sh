#!/usr/bin/env bash

# ./install.sh --ddev-setup: the readiness checks and the setup of Docker,
# DDEV, the docker group, mkcert and the router ports. Everything runs
# in a temporary directory: docker, ddev, mkcert, apt-get, apt-cache,
# curl, sudo, systemctl, ss, id and dpkg are stubs, and the PATH holds
# no real docker, ddev or mkcert. The signing key is a real throw-away
# key made here.

set -euo pipefail

cd "$(dirname "$0")/.."

source lib/output.sh
source lib/system.sh
source lib/project.sh
source lib/packages.sh
source lib/php_source.sh
source lib/ddev.sh

work_dir="$(mktemp -d)"
trap 'gpgconf --kill gpg-agent > /dev/null 2>&1 || true; rm -rf "$work_dir"' EXIT

pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; exit 1; }

export APT_ETC_DIR="$work_dir/apt"
export CALLS_FILE="$work_dir/calls"
export STATE_DIR="$work_dir/state"
export DDEV_HOME="$work_dir/home"
export PROC_VERSION_FILE="$work_dir/proc-version"
stub_bin="$work_dir/bin"
sys_bin="$work_dir/sysbin"
mkdir -p "$APT_ETC_DIR/sources.list.d" "$stub_bin" "$sys_bin" "$STATE_DIR" "$DDEV_HOME"
PROJECT_USER="$(id -un)"
REMOVE_DRY_RUN=0
LOG_FILE=""

# The system's commands, without docker, ddev and mkcert.
for tool in /usr/local/bin/* /usr/bin/* /bin/* /usr/sbin/* /sbin/*; do
    name="$(basename "$tool")"
    case "$name" in docker|ddev|mkcert|ss|id|curl|sudo|systemctl|dpkg|dpkg-query|apt-get|apt-cache) continue ;; esac
    [[ -e "$sys_bin/$name" ]] || ln -s "$tool" "$sys_bin/$name"
done

real_id="$(command -v id)"
export REAL_ID="$real_id"

get_ubuntu_codename() { echo "noble"; }
get_ubuntu_version() { echo "24.04"; }
require_sudo() { echo "sudo-asked" >> "$CALLS_FILE"; }
has_systemd() { [[ "${HAS_SYSTEMD:-1}" == "1" ]]; }

# A real (throw-away) signing key, so that its fingerprint can be checked.
export GNUPGHOME="$work_dir/gnupg"
mkdir -m 700 "$GNUPGHOME"
gpg --batch --quiet --passphrase '' --quick-gen-key "Test Key <test@example.invalid>" ed25519 sign never 2> /dev/null
gpg --batch --armor --export > "$work_dir/key.asc" 2> /dev/null
DOCKER_KEY_FINGERPRINT="$(gpg --batch --with-colons --list-keys 2> /dev/null | awk -F: '$1 == "fpr" { print $10; exit }')"
export KEY_FILE="$work_dir/key.asc"

# What is installed: a file per tool in $STATE_DIR; docker's state in
# $STATE_DIR/docker (ok, stopped, noaccess, desktop).
# docker, ddev and mkcert are templates in $TOOL_DIR, put into the PATH
# when "installed" (reset_state, or the apt-get stub).
export TOOL_DIR="$work_dir/tools"
export STUB_BIN="$stub_bin"
mkdir -p "$TOOL_DIR"

write_stub() {
    local dir="$stub_bin"

    case "$1" in docker|ddev|mkcert) dir="$TOOL_DIR" ;; esac
    cat > "$dir/$1"
    chmod +x "$dir/$1"
}

write_stub docker <<'STUB'
#!/usr/bin/env bash
state="$(cat "$STATE_DIR/docker")"
case "$1" in
    info)
        case "$state" in
            ok) echo "29.0.1|Ubuntu 24.04.3 LTS" ;;
            desktop) echo "28.5.1|Docker Desktop" ;;
            noaccess) echo "permission denied while trying to connect to the Docker daemon socket" >&2; exit 1 ;;
            *) echo "Cannot connect to the Docker daemon" >&2; exit 1 ;;
        esac
        ;;
    compose) [[ -f "$STATE_DIR/compose" ]] && echo "2.40.3" || { echo "unknown command: docker compose" >&2; exit 1; } ;;
esac
STUB

write_stub ddev <<'STUB'
#!/usr/bin/env bash
echo "ddev $*" >> "$CALLS_FILE"
case "$1" in
    --version) echo "ddev version v1.24.10" ;;
    config)
        mkdir -p "$HOME/.ddev"
        http="" https=""
        for a in "$@"; do
            case "$a" in
                --router-http-port=*) http="${a#*=}" ;;
                --router-https-port=*) https="${a#*=}" ;;
            esac
        done
        printf 'router_http_port: "%s"\nrouter_https_port: "%s"\n' "$http" "$https" >> "$HOME/.ddev/global_config.yaml"
        ;;
esac
STUB

write_stub mkcert <<'STUB'
#!/usr/bin/env bash
echo "mkcert $*" >> "$CALLS_FILE"
case "$1" in
    -CAROOT) echo "$STATE_DIR/caroot" ;;
    -install) mkdir -p "$STATE_DIR/caroot" && touch "$STATE_DIR/caroot/rootCA.pem" ;;
esac
STUB

# Listening ports: one per line in $STATE_DIR/ports.
write_stub ss <<'STUB'
#!/usr/bin/env bash
[[ -f "$STATE_DIR/ports" ]] || exit 0
while read -r port; do
    printf 'LISTEN 0 511 0.0.0.0:%s 0.0.0.0:*\n' "$port"
done < "$STATE_DIR/ports"
STUB

write_stub id <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "-nG" ]]; then
    echo "$("$REAL_ID" -un) adm sudo $(cat "$STATE_DIR/groups" 2>/dev/null)"
    exit 0
fi
exec "$REAL_ID" "$@"
STUB

write_stub curl <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$CALLS_FILE"
out=""
while [[ "$#" -gt 0 ]]; do
    [[ "$1" == "-o" ]] && { out="$2"; shift; }
    shift
done
[[ -n "$out" ]] && cp "$KEY_FILE" "$out"
exit 0
STUB

write_stub sudo <<'STUB'
#!/usr/bin/env bash
echo "sudo $*" >> "$CALLS_FILE"
[[ "$1" == "-u" ]] && shift 2
case "$1" in
    install)
        # install -o root -g root needs root: drop the owner options here.
        shift
        args=()
        while [[ "$#" -gt 0 ]]; do
            case "$1" in -o|-g) shift ;; *) args+=("$1") ;; esac
            shift
        done
        exec install "${args[@]}"
        ;;
    usermod) echo "docker" > "$STATE_DIR/groups"; exit 0 ;;
esac
exec "$@"
STUB

write_stub systemctl <<'STUB'
#!/usr/bin/env bash
[[ "$1" == "is-active" ]] || echo "systemctl $*" >> "$CALLS_FILE"
case "$1" in
    is-active) [[ "$(cat "$STATE_DIR/docker" 2>/dev/null)" != "stopped" ]] ;;
    start) echo "noaccess" > "$STATE_DIR/docker" ;;
esac
STUB

write_stub dpkg <<'STUB'
#!/usr/bin/env bash
[[ "$1" == "--print-architecture" ]] && echo "amd64"
STUB

write_stub dpkg-query <<'STUB'
#!/usr/bin/env bash
[[ "${*: -1}" == "docker.io" && -f "$STATE_DIR/docker.io" ]] && echo "install ok installed"
exit 0
STUB

# apt-get: the simulation lists the packages; the installation "installs"
# them (state files). docker-ce: Docker answers only with sudo until the
# next login (noaccess). The ddev package brings mkcert unless
# DDEV_NO_MKCERT=1.
write_stub apt-get <<'STUB'
#!/usr/bin/env bash
echo "apt-get $*" >> "$CALLS_FILE"
args=("$@")
simulate=0
packages=()
for a in "${args[@]}"; do
    case "$a" in
        --simulate) simulate=1 ;;
        -*|install|update) ;;
        *) packages+=("$a") ;;
    esac
done
[[ " ${args[*]} " == *" update "* ]] && exit 0
for p in "${packages[@]}"; do
    if [[ "$simulate" -eq 1 ]]; then
        echo "Inst $p (1.0 test [amd64])"
        [[ -n "${APT_REMOVES:-}" ]] && echo "Remv $APT_REMOVES [1.0]"
        continue
    fi
    case "$p" in
        docker-ce) echo "noaccess" > "$STATE_DIR/docker"; cp "$TOOL_DIR/docker" "$STUB_BIN/" ;;
        docker-compose-plugin|docker-compose-v2) touch "$STATE_DIR/compose" ;;
        ddev) cp "$TOOL_DIR/ddev" "$STUB_BIN/"; [[ "${DDEV_NO_MKCERT:-0}" == "1" ]] || cp "$TOOL_DIR/mkcert" "$STUB_BIN/" ;;
        mkcert) cp "$TOOL_DIR/mkcert" "$STUB_BIN/" ;;
    esac
done
exit 0
STUB

write_stub apt-cache <<'STUB'
#!/usr/bin/env bash
for f in "$APT_ETC_DIR"/sources.list.d/*.sources; do
    [[ -f "$f" ]] || continue
    url="$(awk '/^URIs:/ { print $2 }' "$f")"
    [[ "${APT_IGNORES:-}" == *"$(basename "$f" .sources)"* ]] && continue
    echo " 500 $url stable/main amd64 Packages"
done
exit 0
STUB

PATH="$stub_bin:$sys_bin"

# A computer as described: reset_state "docker=ok compose ddev mkcert-ca ports=80,443 groups=docker".
reset_state() {
    local item

    rm -rf "${STATE_DIR:?}"/* "$DDEV_HOME/.ddev" "$APT_ETC_DIR/sources.list.d"/* "$APT_ETC_DIR/keyrings" \
        "$stub_bin/docker" "$stub_bin/ddev" "$stub_bin/mkcert"
    : > "$CALLS_FILE"
    echo "Linux version 6.8.0-generic" > "$PROC_VERSION_FILE"

    for item in $1; do
        case "$item" in
            docker=*) echo "${item#docker=}" > "$STATE_DIR/docker"; cp "$TOOL_DIR/docker" "$stub_bin/" ;;
            compose) touch "$STATE_DIR/compose" ;;
            ddev) cp "$TOOL_DIR/ddev" "$stub_bin/" ;;
            mkcert) cp "$TOOL_DIR/mkcert" "$stub_bin/" ;;
            mkcert-ca) cp "$TOOL_DIR/mkcert" "$stub_bin/"; mkdir -p "$STATE_DIR/caroot"; touch "$STATE_DIR/caroot/rootCA.pem" ;;
            ports=*) tr ',' '\n' <<< "${item#ports=}" > "$STATE_DIR/ports" ;;
            groups=*) echo "${item#groups=}" > "$STATE_DIR/groups" ;;
            docker.io) touch "$STATE_DIR/docker.io" ;;
            wsl) echo "Linux version 6.6.87.2-microsoft-standard-WSL2" > "$PROC_VERSION_FILE" ;;
            router) mkdir -p "$DDEV_HOME/.ddev"; printf 'router_http_port: "8080"\nrouter_https_port: "8443"\n' > "$DDEV_HOME/.ddev/global_config.yaml" ;;
        esac
    done
}

line_of() {
    grep -n -m 1 -F "$1" "$CALLS_FILE" | cut -d: -f1
}

# Test 1: A computer without Docker and DDEV, Nginx on 80/443: everything
# is shown and planned; the dry run changes nothing.

reset_state "ports=80,443"

if output="$(REMOVE_DRY_RUN=1 run_ddev_setup < /dev/null)" &&
   [[ "$output" == *"Docker:       [MISSING] no Docker engine"* &&
      "$output" == *"DDEV:         [MISSING]"* &&
      "$output" == *"Router ports: [TO SET] 8080/8443 (80/443 stay with the system's Nginx)"* &&
      "$output" == *"Docker's package source: $APT_ETC_DIR/sources.list.d/docker.sources"* &&
      "$output" == *"DDEV's package source: $APT_ETC_DIR/sources.list.d/ddev.sources"* &&
      "$output" == *"Packages: docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin ddev"* &&
      "$output" == *"Add $PROJECT_USER to the docker group"*"as much as sudo"* &&
      "$output" == *"DDEV's router on ports 8080 (http) and 8443 (https)"* &&
      "$output" == *"mkcert -install: a local certificate authority"* &&
      "$output" == *"Not changed: Nginx, PHP-FPM, the databases and the projects."* &&
      "$output" == *"[DRY RUN] Nothing was changed."* ]] &&
   [[ -z "$(ls "$APT_ETC_DIR/sources.list.d")" && ! -s "$CALLS_FILE" ]]; then
    pass "Nothing installed: readiness and plan shown; the dry run changes nothing"
else
    fail "plan: $output / $(cat "$CALLS_FILE")"
fi

if output="$(run_ddev_setup <<< "n")"; then
    fail "'n' went on"
elif [[ "$output" == *"Nothing was changed."* && -z "$(ls "$APT_ETC_DIR/sources.list.d")" && ! -s "$CALLS_FILE" ]]; then
    pass "'n' (the default) changes nothing"
else
    fail "n: $output"
fi

# Test 2: 'y': sources with their own keys, packages (simulated, no
# removals), the group, mkcert, the router ports; sudo steps first.

if output="$(run_ddev_setup <<< "y")" &&
   [[ "$output" == *"[OK] Docker key: $DOCKER_KEY_FINGERPRINT"* &&
      "$output" == *"[OK] Package source added: $APT_ETC_DIR/sources.list.d/docker.sources"* &&
      "$output" == *"[OK] Package source added: $APT_ETC_DIR/sources.list.d/ddev.sources"* &&
      "$output" == *"[OK] apt: 6 packages with their dependencies; nothing is removed"* &&
      "$output" == *"[OK] $PROJECT_USER added to the docker group (after logging in again)"* &&
      "$output" == *"docker group: [LOG IN AGAIN]"* &&
      "$output" == *"Router ports: [OK] 8080/8443 (DDEV's global configuration)"* &&
      "$output" == *"mkcert:       [OK]"* &&
      "$output" == *"[LOG IN AGAIN] The docker group takes effect in a new login session"* ]] &&
   grep -qx "Signed-By: $APT_ETC_DIR/keyrings/docker.asc" "$APT_ETC_DIR/sources.list.d/docker.sources" &&
   grep -qx "Architectures: amd64" "$APT_ETC_DIR/sources.list.d/docker.sources" &&
   grep -qx "Suites: noble" "$APT_ETC_DIR/sources.list.d/docker.sources" &&
   grep -qx "URIs: https://packages.ddev.com/public/deb/ubuntu" "$APT_ETC_DIR/sources.list.d/ddev.sources" &&
   grep -qx "Signed-By: $APT_ETC_DIR/keyrings/ddev.asc" "$APT_ETC_DIR/sources.list.d/ddev.sources" &&
   [[ "$(stat -c '%a' "$APT_ETC_DIR/keyrings/docker.asc")" == "644" ]] &&
   grep -q "apt-get install -y --no-remove -- docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin ddev" "$CALLS_FILE" &&
   [[ "$(line_of sudo-asked)" -lt "$(line_of "curl ")" ]] &&
   [[ "$(line_of "sudo usermod -aG docker $PROJECT_USER")" -lt "$(line_of "ddev config global --router-http-port=8080 --router-https-port=8443")" ]] &&
   [[ "$(line_of "apt-get --simulate")" -lt "$(line_of "apt-get install -y")" ]]; then
    pass "'y': own keyrings (fingerprint checked), packages without removals, group, mkcert, router 8080/8443; sudo steps first"
else
    fail "setup: $output / $(cat "$CALLS_FILE")"
fi

# After logging in again: ready; nothing asked or written.

echo "ok" > "$STATE_DIR/docker"
: > "$CALLS_FILE"

if output="$(run_ddev_setup < /dev/null)" &&
   [[ "$output" == *"Docker:       [OK] 29.0.1 (Docker Engine)"* &&
      "$output" == *"Compose:      [OK] 2.40.3"* && "$output" == *"DDEV:         [OK] v1.24.10"* &&
      "$output" == *"[OK] Ready for DDEV projects."* && "$output" != *"What will change"* ]] &&
   ! grep -q "sudo\|apt-get" "$CALLS_FILE"; then
    pass "Again after logging in: ready, nothing to do"
else
    fail "ready: $output / $(cat "$CALLS_FILE")"
fi

# Test 3: Docker's key with another fingerprint: refused; no source, no
# package.

reset_state "ports=80,443"
saved_fingerprint="$DOCKER_KEY_FINGERPRINT"
DOCKER_KEY_FINGERPRINT="0000000000000000000000000000000000000000"

if output="$(run_ddev_setup <<< "y")"; then
    fail "Wrong key accepted"
elif [[ "$output" == *"[ERROR] The Docker key is not the one Docker publishes:"* &&
        "$output" == *"Stopped; no package was installed."* ]] &&
     [[ -z "$(ls "$APT_ETC_DIR/sources.list.d")" ]] && ! grep -q "apt-get install" "$CALLS_FILE"; then
    pass "Docker key with another fingerprint: refused, nothing added or installed"
else
    fail "wrong key: $output"
fi

DOCKER_KEY_FINGERPRINT="$saved_fingerprint"

# A source that apt cannot use is removed again, with its key.

reset_state "docker=ok compose groups=docker mkcert-ca router"

if output="$(APT_IGNORES=ddev run_ddev_setup <<< "y")"; then
    fail "Unusable source accepted"
elif [[ "$output" == *"[ERROR] The ddev package source was removed again (apt could not use it)."* ]] &&
     [[ ! -e "$APT_ETC_DIR/sources.list.d/ddev.sources" && ! -e "$APT_ETC_DIR/keyrings/ddev.asc" ]]; then
    pass "Unusable package source: removed again with its key"
else
    fail "unusable source: $output"
fi

# Test 4: Docker installed as in docs.docker.com (its own docker.sources):
# only DDEV is planned; no second Docker source.

reset_state "docker=ok compose groups=docker ports=80,443"
printf 'Types: deb\nURIs: https://download.docker.com/linux/ubuntu\nSuites: noble\nComponents: stable\nSigned-By: /etc/apt/keyrings/docker.asc\n' > "$APT_ETC_DIR/sources.list.d/docker.sources"

if output="$(REMOVE_DRY_RUN=1 run_ddev_setup < /dev/null)" &&
   [[ "$output" == *"Docker:       [OK] 29.0.1 (Docker Engine)"* &&
      "$output" == *"docker group: [OK] Docker without sudo"* &&
      "$output" == *"DDEV's package source"* && "$output" != *"Docker's package source"* &&
      "$output" == *"Packages: ddev"* && "$output" != *"docker-ce"* &&
      "$output" != *"to the docker group"* ]]; then
    pass "Docker from docs.docker.com: its source and group kept; only DDEV planned"
else
    fail "docker present: $output"
fi

# DDEV without mkcert in its package: mkcert is installed after it.

reset_state "docker=ok compose groups=docker router"

if output="$(DDEV_NO_MKCERT=1 run_ddev_setup <<< "y")" &&
   [[ "$output" == *"[OK] Ready for DDEV projects."* ]] &&
   grep -q "apt-get install -y --no-remove -- mkcert" "$CALLS_FILE" && grep -q "mkcert -install" "$CALLS_FILE"; then
    pass "mkcert missing after DDEV: its package installed, then mkcert -install"
else
    fail "mkcert after ddev: $output / $(cat "$CALLS_FILE")"
fi

# Test 5: Router ports: 8080 taken -> 8081/8444; set already -> kept.

reset_state "docker=ok compose ddev mkcert-ca groups=docker ports=80,443,8080"

if output="$(REMOVE_DRY_RUN=1 run_ddev_setup < /dev/null)" &&
   [[ "$output" == *"Router ports: [TO SET] 8081/8444"* && "$output" == *"DDEV's router on ports 8081 (http) and 8444 (https)"* ]]; then
    pass "Port 8080 in use: the next free pair (8081/8444)"
else
    fail "ports: $output"
fi

reset_state "docker=ok compose ddev mkcert-ca groups=docker ports=80,443,8080,8443,8081,8880"

if output="$(run_ddev_setup < /dev/null)"; then
    fail "No free ports accepted"
elif [[ "$output" == *"[BLOCKED] No free pair of router ports."* ]]; then
    pass "No free pair of ports: blocked, with the command to choose them"
else
    fail "busy ports: $output"
fi

# Test 6: WSL without systemd: Docker cannot start there; the way out is
# shown, DDEV itself is still planned.

reset_state "wsl ports=80,443"

if output="$(HAS_SYSTEMD=0 REMOVE_DRY_RUN=1 run_ddev_setup < /dev/null)" &&
   [[ "$output" == *"System:       Ubuntu 24.04 (WSL)"* &&
      "$output" == *"systemd:      [MISSING] WSL without systemd"* &&
      "$output" == *"[BLOCKED] WSL without systemd: the Docker engine needs it."*"systemd=true"*"wsl --shutdown"* &&
      "$output" == *"Packages: ddev"* && "$output" != *"docker-ce"* && "$output" != *"to the docker group"* ]]; then
    pass "WSL without systemd: blocked with the /etc/wsl.conf fix; DDEV still planned"
else
    fail "wsl: $output"
fi

# Test 7: Docker installed but stopped: started (never restarted).

reset_state "docker=stopped compose ddev mkcert-ca groups=docker router"

if output="$(run_ddev_setup <<< "y")" &&
   [[ "$output" == *"Docker:       [STOPPED]"* && "$output" == *"[OK] docker service started"* ]] &&
   grep -q "systemctl start docker" "$CALLS_FILE" && ! grep -q "restart" "$CALLS_FILE"; then
    pass "Stopped docker service: started, never restarted"
else
    fail "stopped: $output / $(cat "$CALLS_FILE")"
fi

# Test 8: Ubuntu's docker.io without compose: docker-compose-v2, no
# Docker source.

reset_state "docker=ok docker.io ddev mkcert-ca groups=docker router"

if output="$(REMOVE_DRY_RUN=1 run_ddev_setup < /dev/null)" &&
   [[ "$output" == *"Compose:      [MISSING] docker compose"* && "$output" == *"Packages: docker-compose-v2"* &&
      "$output" != *"Docker's package source"* ]]; then
    pass "Ubuntu's docker.io without compose: docker-compose-v2 from Ubuntu, no second source"
else
    fail "docker.io: $output"
fi

# Test 9: Docker Desktop (WSL integration): no group, no systemd needed.

reset_state "docker=desktop compose ddev mkcert-ca wsl router"

if output="$(HAS_SYSTEMD=0 run_ddev_setup < /dev/null)" &&
   [[ "$output" == *"Docker:       [OK] 28.5.1 (Docker Desktop)"* && "$output" == *"[OK] Ready for DDEV projects."* ]]; then
    pass "Docker Desktop in WSL: accepted as it is"
else
    fail "desktop: $output"
fi

# In the docker group, but this login session started before.

reset_state "docker=noaccess compose ddev mkcert-ca groups=docker router"

if output="$(run_ddev_setup < /dev/null)"; then
    fail "No access counted as ready"
elif [[ "$output" == *"docker group: [LOG IN AGAIN]"* && "$output" == *"[LOG IN AGAIN] $PROJECT_USER is in the docker group"* &&
        "$output" != *"What will change"* ]]; then
    pass "In the group, old session: told to log in again; nothing planned"
else
    fail "relogin: $output"
fi

echo "[SUCCESS] DDEV setup tests passed."
