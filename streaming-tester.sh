#!/usr/bin/env bash
#
# RomM emulator-streaming test stack installer.
#
# Sets up an ISOLATED RomM + webstation + Caddy stack in the current directory
# so you can try the new streaming feature without touching an existing RomM
# install. Your ROM library is the only thing mounted from outside, read-only.
#
#   mkdir romm-streaming && cd romm-streaming
#   curl -fsSL https://raw.githubusercontent.com/romm-streaming/streaming-tester/main/streaming-tester.sh | bash
#
# Remove everything again (ROMs are never touched):
#   curl -fsSL https://raw.githubusercontent.com/romm-streaming/streaming-tester/main/streaming-tester.sh | bash -s -- remove
#
# This is a testing aid. It is not maintained as a product and targets a plain
# Linux server running Docker + Compose v2 with a supported GPU.

set -euo pipefail

RAW_BASE="${STREAMING_TESTER_RAW:-https://raw.githubusercontent.com/romm-streaming/streaming-tester/main}"
# Rolling tags: this repo's CI rebuilds both images from upstream RomM master
# and linuxserver/docker-webstation's romm branch, and moves streaming-v2 to
# each new build, so fixes reach testers without a new release of this script.
ROMM_IMAGE="ghcr.io/romm-streaming/romm:streaming-v2"
WEBSTATION_IMAGE="ghcr.io/romm-streaming/webstation:streaming-v2"
DB_IMAGE="mariadb:11"
PROXY_IMAGE="caddy:2"
PROJECT="streaming-test"
MARKER=".streaming-tester"
DEFAULT_PORT=8443
NVIDIA_MIN_DRIVER=595
ISSUES_URL="https://github.com/romm-streaming/romm-broker/issues"

STACK_DIR="$(pwd)"

# Record who is really running this before any sudo happens; the containers
# run as this user (PUID/PGID). If the whole script was launched via sudo,
# SUDO_UID/SUDO_GID point back at the real account. Never hand uid 0 to the
# containers; fall back to 1000 in that case.
PUID="${SUDO_UID:-$(id -u)}"
PGID="${SUDO_GID:-$(id -g)}"
if [ "$PUID" = "0" ]; then PUID=1000; PGID=1000; fi
RUN_USER="${SUDO_USER:-$(id -un 2>/dev/null || echo "$PUID")}"

# Everything the installer creates inside STACK_DIR. `remove` deletes exactly this list.
GENERATED_DIRS=(romm-resources romm-redis-data romm-assets romm-config romm-db webstation-home caddy-data caddy-ssl)
GENERATED_FILES=(docker-compose.yml Caddyfile .env "$MARKER")

# ---------------------------------------------------------------- output ----

if [ -t 1 ]; then
  C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_YEL=$'\033[1;33m'; C_BLU=$'\033[1;34m'; C_BLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BLD=""; C_RST=""
fi

info() { printf '%s==>%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()   { printf '%s   %s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%sWARNING:%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
die()  { printf '%sERROR:%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }
hr()   { printf '%s\n' "------------------------------------------------------------------"; }

# Prompts read from the terminal directly so `curl | bash` still works.
ask() { # ask VAR "prompt" "default"
  local __var="$1" prompt="$2" default="${3:-}" reply
  if [ -n "$default" ]; then
    printf '%s [%s]: ' "$prompt" "$default"
  else
    printf '%s: ' "$prompt"
  fi
  IFS= read -r reply </dev/tty || die "Could not read from the terminal."
  [ -z "$reply" ] && reply="$default"
  printf -v "$__var" '%s' "$reply"
}

ask_yn() { # ask_yn "prompt" y|n  -> returns 0 for yes
  local prompt="$1" default="${2:-n}" reply hint
  [ "$default" = "y" ] && hint="Y/n" || hint="y/N"
  while true; do
    printf '%s [%s]: ' "$prompt" "$hint"
    IFS= read -r reply </dev/tty || die "Could not read from the terminal."
    [ -z "$reply" ] && reply="$default"
    case "$reply" in
      [Yy]|[Yy][Ee][Ss]) return 0 ;;
      [Nn]|[Nn][Oo]) return 1 ;;
    esac
  done
}

choose() { # choose VAR "prompt" "opt1" "opt2" ... -> VAR = 1-based index
  local __var="$1" prompt="$2"; shift 2
  local i=1 reply
  for opt in "$@"; do printf '  %s%d)%s %s\n' "$C_BLD" "$i" "$C_RST" "$opt"; i=$((i + 1)); done
  while true; do
    printf '%s [1-%d]: ' "$prompt" "$#"
    IFS= read -r reply </dev/tty || die "Could not read from the terminal."
    if [[ "$reply" =~ ^[0-9]+$ ]] && [ "$reply" -ge 1 ] && [ "$reply" -le "$#" ]; then
      printf -v "$__var" '%s' "$reply"
      return
    fi
  done
}

# --------------------------------------------------------------- helpers ----

marker_get() { # marker_get KEY
  [ -f "$MARKER" ] || return 0
  grep -m1 "^$1=" "$MARKER" 2>/dev/null | cut -d= -f2- || true
}

# The settings write_stack needs, from the last install instead of the prompts.
load_marker_settings() {
  PORT="$(marker_get PORT)"; ROMS_PATH="$(marker_get ROMS_PATH)"; GPU_MODE="$(marker_get GPU_MODE)"
  SELECTED_GPU_NAME="$(marker_get GPU_NAME)"; SELECTED_GPU_INDEX="$(marker_get GPU_INDEX)"
  if [ "$GPU_MODE" = "nvidia" ]; then
    NVIDIA_MODESET_DEV=""
    if [ -e /dev/nvidia-modeset ]; then
      NVIDIA_MODESET_DEV=/dev/nvidia-modeset
    else
      NVIDIA_MODESET_WARN=1
    fi
  fi
}

env_get() { # env_get KEY (from existing .env)
  [ -f .env ] || return 0
  grep -m1 "^$1=" .env 2>/dev/null | cut -d= -f2- || true
}

rand_hex() { # rand_hex BYTES
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$1"
  else
    od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'
  fi
}

# Reuse a secret from an existing .env so a reconfigure keeps working against
# the database that was initialised with it; otherwise generate a new one.
secret() { # secret KEY BYTES
  local v
  v="$(env_get "$1")"
  if [ -n "$v" ]; then printf '%s' "$v"; else rand_hex "$2"; fi
}

detect_tz() {
  local tz=""
  [ -r /etc/timezone ] && tz="$(tr -d '[:space:]' </etc/timezone)"
  [ -z "$tz" ] && command -v timedatectl >/dev/null 2>&1 && tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  if [ -z "$tz" ] && [ -L /etc/localtime ]; then
    tz="$(readlink -f /etc/localtime)"; tz="${tz#*/zoneinfo/}"
  fi
  [ -z "$tz" ] && tz="UTC"
  printf '%s' "$tz"
}

host_ip() {
  local ip=""
  if command -v ip >/dev/null 2>&1; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  fi
  [ -z "$ip" ] && command -v hostname >/dev/null 2>&1 && ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [ -z "$ip" ] && ip="localhost"
  printf '%s' "$ip"
}

port_in_use() { # port_in_use PORT -> 0 if something is listening
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -Hltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$" && return 0
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$" && return 0
  fi
  "${DOCKER[@]}" ps --format '{{.Ports}}' 2>/dev/null | grep -qE ":${port}->" && return 0
  return 1
}

fetch() { # fetch URL DEST
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$1" -o "$2"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$2" "$1"
  else
    die "Need curl or wget to download $1"
  fi
}

# ---------------------------------------------------------- docker checks ----

DOCKER=()
COMPOSE=()
SUDO_HINT=""

check_docker() {
  info "Checking for Docker and Compose"
  command -v docker >/dev/null 2>&1 || die "docker is not installed. See https://docs.docker.com/engine/install/"

  if docker info >/dev/null 2>&1; then
    DOCKER=(docker)
  else
    command -v sudo >/dev/null 2>&1 || die "Cannot talk to the Docker daemon as this user and sudo is not available."
    warn "Docker needs sudo on this system; you may be asked for your password."
    if sudo docker info >/dev/null 2>&1; then
      DOCKER=(sudo docker)
      SUDO_HINT="sudo "
    else
      die "Cannot talk to the Docker daemon, even with sudo. Is it running?"
    fi
  fi

  if "${DOCKER[@]}" compose version >/dev/null 2>&1; then
    COMPOSE=("${DOCKER[@]}" compose)
    COMPOSE_CMD="${SUDO_HINT}docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    warn "Using legacy docker-compose. Compose v2 (docker compose) is what this stack is tested with."
    if [ -n "$SUDO_HINT" ]; then COMPOSE=(sudo docker-compose); else COMPOSE=(docker-compose); fi
    COMPOSE_CMD="${SUDO_HINT}docker-compose"
  else
    die "Docker Compose is not installed. See https://docs.docker.com/compose/install/"
  fi
  ok "docker: $(docker --version 2>/dev/null | head -1)"
  ok "compose: $("${COMPOSE[@]}" version 2>/dev/null | head -1)"
}

nvidia_runtime_present() {
  "${DOCKER[@]}" info --format '{{json .Runtimes}}' 2>/dev/null | grep -q '"nvidia"' && return 0
  command -v nvidia-container-runtime >/dev/null 2>&1 && return 0
  command -v nvidia-ctk >/dev/null 2>&1 && return 0
  return 1
}

# ---------------------------------------------------------- gpu detection ----

GPU_TYPE=()   # intel | amd | nvidia
GPU_NAME=()
GPU_PCI=()
GPU_NODE=()   # renderD* node for the card, when known
GPU_MODE=""   # dri | nvidia  (how the compose file will expose the GPU)

gpu_seen() { local p; for p in "${GPU_PCI[@]:-}"; do [ "$p" = "$1" ] && return 0; done; return 1; }

gpu_name_for() { # gpu_name_for TYPE PCI
  local type="$1" pci="$2" name=""
  if [ "$type" = "nvidia" ] && [ -r "/proc/driver/nvidia/gpus/$pci/information" ]; then
    name="$(sed -n 's/^Model:[[:space:]]*//p' "/proc/driver/nvidia/gpus/$pci/information" | head -1)"
  fi
  if [ -z "$name" ] && command -v lspci >/dev/null 2>&1; then
    name="$(lspci -s "$pci" 2>/dev/null | head -1 | sed 's/^[^ ]* [^:]*: //')"
  fi
  if [ -z "$name" ]; then
    case "$type" in
      intel)  name="Intel GPU" ;;
      amd)    name="AMD GPU" ;;
      nvidia) name="NVIDIA GPU" ;;
    esac
  fi
  printf '%s' "$name"
}

add_gpu() { # add_gpu TYPE PCI NODE
  gpu_seen "$2" && return 0
  GPU_TYPE+=("$1"); GPU_PCI+=("$2"); GPU_NODE+=("$3"); GPU_NAME+=("$(gpu_name_for "$1" "$2")")
}

detect_gpus() {
  local card vendor pci type node g n
  for card in /sys/class/drm/card*; do
    [[ "$(basename "$card")" =~ ^card[0-9]+$ ]] || continue
    [ -r "$card/device/vendor" ] || continue
    vendor="$(tr -d '[:space:]' <"$card/device/vendor")"
    pci="$(basename "$(readlink -f "$card/device")")"
    case "$vendor" in
      0x8086) type=intel ;;
      0x1002|0x1022) type=amd ;;
      0x10de) type=nvidia ;;
      *) continue ;;
    esac
    node=""
    for n in "$card"/device/drm/renderD*; do
      [ -e "$n" ] && { node="$(basename "$n")"; break; }
    done
    add_gpu "$type" "$pci" "$node"
  done
  # NVIDIA cards show up here even when nvidia-drm is not loaded (no /dev/dri node).
  for g in /proc/driver/nvidia/gpus/*/; do
    [ -d "$g" ] || continue
    pci="$(basename "$g")"
    add_gpu nvidia "$pci" ""
  done
}

select_gpu() {
  info "Looking for a GPU"
  detect_gpus

  if [ "${#GPU_TYPE[@]}" -eq 0 ]; then
    hr
    printf '%sNo supported GPU found.%s\n' "$C_RED" "$C_RST"
    printf 'Streaming needs hardware video encoding, so this test stack requires an\n'
    printf 'Intel, AMD, or NVIDIA GPU with its kernel driver loaded (/dev/dri or\n'
    printf '/dev/nvidia*). Nothing was found in /sys/class/drm or /proc/driver/nvidia.\n'
    hr
    exit 1
  fi

  local i choice=1 label
  for i in "${!GPU_TYPE[@]}"; do
    label="${GPU_NAME[$i]} [${GPU_TYPE[$i]}, ${GPU_PCI[$i]}${GPU_NODE[$i]:+, /dev/dri/${GPU_NODE[$i]}}]"
    ok "found: $label"
  done

  if [ "${#GPU_TYPE[@]}" -gt 1 ]; then
    echo
    echo "More than one GPU was found. Pick the one the streaming container should use:"
    local opts=()
    for i in "${!GPU_TYPE[@]}"; do
      opts+=("${GPU_NAME[$i]} (${GPU_TYPE[$i]})")
    done
    choose choice "GPU" "${opts[@]}"
  fi
  local idx=$((choice - 1))
  SELECTED_GPU_INDEX="$choice"
  SELECTED_GPU_NAME="${GPU_NAME[$idx]}"
  SELECTED_GPU_TYPE="${GPU_TYPE[$idx]}"

  case "$SELECTED_GPU_TYPE" in
    intel|amd)
      GPU_MODE=dri
      [ -d /dev/dri ] || die "/dev/dri does not exist, so the GPU cannot be passed to the container. Is the graphics driver loaded?"
      ;;
    nvidia)
      GPU_MODE=nvidia
      [ -e /dev/nvidiactl ] || die "/dev/nvidiactl does not exist. Install the proprietary NVIDIA driver and make sure it is loaded."
      if ! nvidia_runtime_present; then
        hr
        printf '%sNVIDIA Container Toolkit not found.%s\n' "$C_RED" "$C_RST"
        printf 'Passing an NVIDIA GPU into Docker requires the toolkit and the nvidia runtime\n'
        printf 'registered with Docker. Install it, then re-run this script:\n'
        printf '  https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html\n'
        printf '  sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker\n'
        hr
        exit 1
      fi
      if [ -r /sys/module/nvidia/version ]; then
        local ver major
        ver="$(tr -d '[:space:]' </sys/module/nvidia/version)"
        major="${ver%%.*}"
        if [[ "$major" =~ ^[0-9]+$ ]] && [ "$major" -lt "$NVIDIA_MIN_DRIVER" ]; then
          warn "NVIDIA driver $ver detected. Current drivers (${NVIDIA_MIN_DRIVER}+) are recommended; older ones may not encode correctly."
        else
          ok "NVIDIA driver $ver"
        fi
      fi
      # Streaming needs /dev/nvidia-modeset in the container. It is only
      # mounted when present so compose does not fail on a missing device.
      NVIDIA_MODESET_DEV=""
      if [ -e /dev/nvidia-modeset ]; then
        NVIDIA_MODESET_DEV=/dev/nvidia-modeset
      else
        NVIDIA_MODESET_WARN=1
        warn "/dev/nvidia-modeset was not found on this system. It is normally required for streaming; continuing without it, but streaming may not work properly."
      fi
      ;;
  esac
  ok "using: $SELECTED_GPU_NAME ($GPU_MODE mode)"
}

# ----------------------------------------------------------- user prompts ----

select_roms() {
  echo
  info "ROM library"
  echo "Point at the folder that contains your platform folders, the one that has"
  echo "e.g. an 'nes' or 'snes' folder directly inside it. It is mounted read-only."
  local default; default="$(marker_get ROMS_PATH)"
  while true; do
    ask ROMS_PATH "ROM library path" "$default"
    [ -z "$ROMS_PATH" ] && continue
    ROMS_PATH="${ROMS_PATH/#\~/$HOME}"
    if [ ! -d "$ROMS_PATH" ]; then
      echo "  '$ROMS_PATH' is not a directory."
      continue
    fi
    ROMS_PATH="$(cd "$ROMS_PATH" && pwd -P)"
    local subs
    subs="$(find "$ROMS_PATH" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort | head -12 | tr '\n' ' ')"
    if [ -z "$subs" ]; then
      warn "No sub-folders found in $ROMS_PATH; RomM will not find any platforms there."
      ask_yn "Use it anyway?" n && break
      continue
    fi
    echo "  Platform folders seen: $subs"
    ask_yn "Use $ROMS_PATH?" y && break
  done
}

select_port() {
  echo
  info "Web port"
  echo "The test stack is served over https on its own port so it cannot collide"
  echo "with an existing RomM install."
  local default; default="$(marker_get PORT)"; default="${default:-$DEFAULT_PORT}"
  while true; do
    ask PORT "Port" "$default"
    if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
      echo "  Enter a number between 1 and 65535."
      continue
    fi
    if port_in_use "$PORT" && [ "$PORT" != "$(marker_get PORT)" ]; then
      warn "Something is already listening on port $PORT."
      ask_yn "Use it anyway?" n && break
      continue
    fi
    break
  done
}

# ---------------------------------------------------------- file writing ----

write_stack() {
  info "Writing the stack into $STACK_DIR"

  local d
  for d in "${GENERATED_DIRS[@]}"; do mkdir -p "$d"; done

  local tz
  tz="$(detect_tz)"
  # Dirs the containers write to as PUID/PGID must belong to that user; this
  # only matters when the script itself is running as root.
  if [ "$(id -u)" = "0" ]; then
    chown -R "$PUID:$PGID" webstation-home romm-db caddy-ssl 2>/dev/null || true
  fi

  local db_passwd db_root auth_key broker_secret
  db_passwd="$(secret DB_PASSWD 16)"
  db_root="$(secret MARIADB_ROOT_PASSWORD 16)"
  auth_key="$(secret ROMM_AUTH_SECRET_KEY 32)"
  broker_secret="$(secret BROKER_SECRET 24)"

  cat >.env <<ENV
# Generated by streaming-tester.sh. Secrets are reused on reconfigure.
COMPOSE_PROJECT_NAME=${PROJECT}
TZ=${tz}
PUID=${PUID}
PGID=${PGID}
PORT=${PORT}
ROMS_PATH=${ROMS_PATH}
DB_PASSWD=${db_passwd}
MARIADB_ROOT_PASSWORD=${db_root}
ROMM_AUTH_SECRET_KEY=${auth_key}
BROKER_SECRET=${broker_secret}
ENV
  chmod 600 .env
  ok ".env"

  # RomM config: fetched from the repo, broker secret filled in.
  fetch "${RAW_BASE}/config.yml" romm-config/config.yml || die "Could not download config.yml from ${RAW_BASE}"
  sed -i "s|__BROKER_SECRET__|${broker_secret}|" romm-config/config.yml
  ok "romm-config/config.yml (streaming enabled for every supported platform)"

  # TLS: self-signed cert for Caddy; fall back to Caddy's own internal CA.
  local tls_line
  if [ -s caddy-ssl/cert.pem ] && [ -s caddy-ssl/cert.key ]; then
    tls_line="tls /ssl/cert.pem /ssl/cert.key"
    ok "caddy-ssl/ (keeping existing certificate)"
  elif command -v openssl >/dev/null 2>&1; then
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
      -keyout caddy-ssl/cert.key -out caddy-ssl/cert.pem \
      -subj "/CN=romm-streaming-test" >/dev/null 2>&1
    chmod 600 caddy-ssl/cert.key
    tls_line="tls /ssl/cert.pem /ssl/cert.key"
    ok "caddy-ssl/ (self-signed certificate, 10 years)"
  else
    tls_line="tls internal"
    warn "openssl not found; Caddy will generate its own self-signed certificate instead."
  fi

  cat >Caddyfile <<CADDY
{
	auto_https off
}

:443 {
	${tls_line}

	redir /streaming /streaming/ 301

	# handle, never handle_path: the /streaming prefix must reach the
	# container intact. Caddy forwards websocket upgrades on its own.
	handle /streaming/* {
		reverse_proxy webstation:3000
	}

	handle {
		reverse_proxy romm:8080
	}
}
CADDY
  ok "Caddyfile"

  local gpu_block
  if [ "$GPU_MODE" = "dri" ]; then
    gpu_block="    devices:
      - /dev/dri:/dev/dri"
  else
    gpu_block=""
    if [ -n "${NVIDIA_MODESET_DEV:-}" ]; then
      gpu_block="    devices:
      - ${NVIDIA_MODESET_DEV}:${NVIDIA_MODESET_DEV}
"
    fi
    gpu_block="${gpu_block}    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [compute,video,graphics,utility]"
  fi

  cat >docker-compose.yml <<COMPOSE
# Generated by streaming-tester.sh for GPU: ${SELECTED_GPU_NAME} (${GPU_MODE})
#
# Isolated RomM streaming test stack. Container names, project name and
# network are all prefixed "${PROJECT}" so nothing collides with a real
# RomM install. Only ROMS_PATH (from .env) is mounted from outside, read-only.
#
#   ${COMPOSE_CMD} up -d      start
#   ${COMPOSE_CMD} down       stop
#   ${COMPOSE_CMD} pull && ${COMPOSE_CMD} up -d   update to the newest build
#
# The streaming-v2 images below follow upstream. Re-running the installer and
# choosing "Start it" also updates, and regenerates this file.

services:
  romm:
    image: ${ROMM_IMAGE}
    container_name: ${PROJECT}-romm
    restart: unless-stopped
    depends_on:
      romm-db:
        condition: service_healthy
    environment:
      - TZ=\${TZ}
      - DB_HOST=romm-db
      - DB_NAME=romm
      - DB_USER=romm
      - DB_PASSWD=\${DB_PASSWD}
      - ROMM_AUTH_SECRET_KEY=\${ROMM_AUTH_SECRET_KEY}
      - SCAN_WORKERS=2
      - WEB_SERVER_CONCURRENCY=3
    volumes:
      - ./romm-resources:/romm/resources
      - ./romm-redis-data:/redis-data
      - ./romm-assets:/romm/assets
      - ./romm-config:/romm/config
      # <platform>/<games> folders mounted at library/roms = RomM "structure A".
      - type: bind
        source: \${ROMS_PATH}
        target: /romm/library/roms
        read_only: true

  romm-db:
    image: ${DB_IMAGE}
    container_name: ${PROJECT}-db
    restart: unless-stopped
    user: "\${PUID}:\${PGID}"
    environment:
      - TZ=\${TZ}
      - MARIADB_ROOT_PASSWORD=\${MARIADB_ROOT_PASSWORD}
      - MARIADB_DATABASE=romm
      - MARIADB_USER=romm
      - MARIADB_PASSWORD=\${DB_PASSWD}
    volumes:
      - ./romm-db:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 30s
      start_interval: 5s
      interval: 10s
      timeout: 5s
      retries: 5

  webstation:
    image: ${WEBSTATION_IMAGE}
    container_name: ${PROJECT}-webstation
    restart: unless-stopped
    environment:
      - PUID=\${PUID}
      - PGID=\${PGID}
      - TZ=\${TZ}
      - BROKER_SECRET=\${BROKER_SECRET}
    shm_size: 1gb
    volumes:
      - ./webstation-home:/config
      - type: bind
        source: \${ROMS_PATH}
        target: /romm/roms
        read_only: true
${gpu_block}

  caddy:
    image: ${PROXY_IMAGE}
    container_name: ${PROJECT}-proxy
    restart: unless-stopped
    ports:
      - "\${PORT}:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./caddy-ssl:/ssl:ro
      - ./caddy-data:/data
COMPOSE
  ok "docker-compose.yml"

  cat >"$MARKER" <<MARK
# Written by streaming-tester.sh; used to offer defaults on re-run and to
# recognise this directory as a test stack for 'remove'.
CREATED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
GPU_MODE=${GPU_MODE}
GPU_NAME=${SELECTED_GPU_NAME}
GPU_INDEX=${SELECTED_GPU_INDEX}
ROMS_PATH=${ROMS_PATH}
PORT=${PORT}
MARK
}

# --------------------------------------------------------------- actions ----

start_stack() {
  echo
  info "Pulling images (this can take a while, the webstation image is large)"
  "${COMPOSE[@]}" pull
  info "Starting the stack"
  "${COMPOSE[@]}" up -d
}

wait_for_romm() {
  local url="$1" i
  command -v curl >/dev/null 2>&1 || return 0
  printf 'Waiting for RomM to come up'
  for i in $(seq 1 45); do
    if curl -ksf -o /dev/null --max-time 3 "$url/api/heartbeat" 2>/dev/null; then
      echo; return 0
    fi
    printf '.'; sleep 2
  done
  echo
  warn "RomM has not answered yet; it may still be starting. Check: ${COMPOSE_CMD} logs -f romm"
}

print_summary() {
  local ip url
  ip="$(host_ip)"
  url="https://${ip}:${PORT}"
  echo
  hr
  printf '%sRomM streaming test stack is up.%s\n' "$C_GRN" "$C_RST"
  hr
  printf '\n  %s%s%s\n\n' "$C_BLD" "$url" "$C_RST"
  cat <<TXT
  The certificate is self-signed, so your browser will warn once; accept it.

  First run:
    1. Create the admin user in the setup wizard.
    2. Scan the library (Library -> Scan). The ROM folder is read-only; only
       this stack's own data (in $STACK_DIR) is written.
    3. Open a game; platforms served by the webstation container show a
       streaming play option.

  Managing the stack (run from $STACK_DIR):
    ${COMPOSE_CMD} up -d             start
    ${COMPOSE_CMD} down              stop
    ${COMPOSE_CMD} logs -f           watch logs

  Something broken? Re-running the installer here offers a one-command reset
  that wipes this stack's database and config but keeps your GPU/ROM/port
  settings, in case a bad state (not a real bug) is the cause:
    curl -fsSL ${RAW_BASE}/streaming-tester.sh | bash

  Remove everything except your ROMs:
    curl -fsSL ${RAW_BASE}/streaming-tester.sh | bash -s -- remove

  GPU: ${SELECTED_GPU_NAME} (${GPU_MODE})
  ROMs: ${ROMS_PATH} (read-only)
  RomM image: ${ROMM_IMAGE}
  Webstation image: ${WEBSTATION_IMAGE}

  To update to the newest build, re-run the installer here and choose
  "Start it". Both images follow upstream as it changes.

  Found a bug? Please report it (not in core RomM support channels):
    ${ISSUES_URL}
  Include the two image lines above, when you last installed or updated, and
  your GPU/driver info exactly as printed here.
TXT
  if [ -n "${NVIDIA_MODESET_WARN:-}" ]; then
    warn "/dev/nvidia-modeset was not present when this stack was generated; streaming may not work properly."
  fi
  hr
}

reset_stack() {
  [ -f "$MARKER" ] || die "$STACK_DIR does not look like a streaming test stack (no $MARKER file). Run this from the folder you installed into."
  echo
  hr
  printf '%sThis resets RomM'"'"'s database and config in:%s %s\n' "$C_YEL" "$C_RST" "$STACK_DIR"
  hr
  echo "A broken database migration or stale config is almost always fixed by"
  echo "starting RomM's data fresh. This clears the RomM database, config, and"
  echo "library metadata/cache. It keeps:"
  echo "  - your GPU / ROM path / port settings"
  echo "  - the webstation home folder and TLS certificate"
  echo "  - your ROM library (never touched)"
  echo
  ask_yn "Reset RomM's database and config?" n || { echo "Nothing reset."; return 0; }

  if [ -f docker-compose.yml ]; then
    info "Stopping containers"
    "${COMPOSE[@]}" down --remove-orphans || warn "compose down failed; continuing with reset"
  fi

  info "Clearing RomM database and config"
  rm -rf romm-db romm-config romm-resources romm-assets romm-redis-data

  load_marker_settings
  write_stack
  start_stack
  wait_for_romm "https://localhost:${PORT}"
  print_summary
}

remove_stack() {
  [ -f "$MARKER" ] || die "$STACK_DIR does not look like a streaming test stack (no $MARKER file). Run this from the folder you installed into."
  echo
  hr
  printf '%sThis removes the streaming test stack in:%s %s\n' "$C_YEL" "$C_RST" "$STACK_DIR"
  hr
  echo "Containers, database, RomM metadata, saves/states made in this test stack and"
  echo "the generated config are deleted. Your ROM library is not touched:"
  echo "  $(marker_get ROMS_PATH)"
  echo
  ask_yn "Remove the test stack?" n || { echo "Nothing removed."; exit 0; }

  if [ -f docker-compose.yml ]; then
    info "Stopping containers"
    "${COMPOSE[@]}" down --remove-orphans --volumes || warn "compose down failed; continuing with cleanup"
  fi

  info "Deleting generated files"
  local failed=() item
  for item in "${GENERATED_DIRS[@]}"; do
    [ -e "$item" ] || continue
    rm -rf "$item" 2>/dev/null || failed+=("$item")
  done
  if [ "${#failed[@]}" -gt 0 ]; then
    # Files written by root inside the containers; delete them the same way.
    info "Cleaning root-owned data via a helper container"
    "${DOCKER[@]}" run --rm -v "$STACK_DIR:/stack" alpine:3 sh -c 'cd /stack && rm -rf "$@"' sh "${failed[@]}" \
      || warn "Could not delete: ${failed[*]} (try: sudo rm -rf ${failed[*]})"
  fi
  for item in "${GENERATED_FILES[@]}"; do rm -f "$item"; done

  if ask_yn "Also delete the downloaded images (RomM, webstation, mariadb, caddy)?" n; then
    "${DOCKER[@]}" rmi "$ROMM_IMAGE" "$WEBSTATION_IMAGE" "$DB_IMAGE" "$PROXY_IMAGE" 2>/dev/null || true
  fi
  echo
  ok "Test stack removed. $STACK_DIR can be deleted if it is empty."
}

install_stack() {
  select_gpu
  select_roms
  select_port
  echo
  write_stack
  start_stack
  wait_for_romm "https://localhost:${PORT}"
  print_summary
}

# ------------------------------------------------------------------ main ----

main() {
  [ -r /dev/tty ] || die "This installer is interactive and needs a terminal."
  [ "$(uname -s)" = "Linux" ] || die "This test stack only supports Linux."

  echo
  printf '%sRomM emulator-streaming test stack%s\n' "$C_BLD" "$C_RST"
  echo "Testing aid only: isolated from any existing RomM install, easy to remove."
  echo "Directory: $STACK_DIR"
  echo "User: $RUN_USER (uid $PUID, gid $PGID) - containers will run as this user"
  echo

  check_docker

  case "${1:-}" in
    remove|--remove|uninstall) remove_stack; exit 0 ;;
    ""|install|--install) ;;
    *) die "Unknown argument '$1'. Use no argument to install, or 'remove'." ;;
  esac

  if [ -f "$MARKER" ]; then
    echo
    echo "A streaming test stack already exists here (created $(marker_get CREATED))."
    local action
    choose action "What do you want to do?" \
      "Start it (update to the newest build, keep data)" \
      "Reset RomM's database and config (fixes a broken/stale state, keep GPU/ROM/port)" \
      "Reconfigure it (GPU / ROM path / port, keep data)" \
      "Remove it" \
      "Quit"
    case "$action" in
      # Regenerating the stack files moves an install made by an older version
      # of this script onto the current image tags.
      1) load_marker_settings; write_stack
         start_stack; wait_for_romm "https://localhost:${PORT}"; print_summary; exit 0 ;;
      2) reset_stack; exit 0 ;;
      3) install_stack; exit 0 ;;
      4) remove_stack; exit 0 ;;
      5) exit 0 ;;
    esac
  fi

  if [ -n "$(ls -A "$STACK_DIR" 2>/dev/null)" ]; then
    warn "$STACK_DIR is not empty. The stack should live in its own folder (e.g. mkdir romm-streaming && cd romm-streaming)."
    ask_yn "Continue here anyway?" n || exit 0
  fi

  install_stack
}

main "$@"
