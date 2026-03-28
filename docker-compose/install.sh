#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────
# OSIE Single-VM Installer (Docker Compose)
# ──────────────────────────────────────────────────────────────

INSTALL_DIR="/opt/osie"
REPO_URL="https://github.com/osie/deployment.git"

# ── Defaults ──────────────────────────────────────────────────
PUBLIC_HOSTNAME=""
CADDY_HTTP_PORT=""
CADDY_HTTPS_PORT=""
BRANCH="main"

# Resolved during setup
DEPLOY_MODE=""       # "prod" or "dev"
EXTERNAL_BASE_URL=""
SELECTED_IP=""

# ── Parse CLI arguments ──────────────────────────────────────
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --hostname DOMAIN       Public hostname — enables prod mode (Let's Encrypt)
  --http-port PORT        External HTTP port — dev mode only (default: 80)
  --https-port PORT       External HTTPS port — dev mode only (default: 443)
  --branch BRANCH         Git branch to clone (default: main)
  -h, --help              Show this help message

Prod mode (--hostname):
  Caddy obtains a Let's Encrypt certificate. Ports 80+443 are exposed.
  The script validates DNS before proceeding.

Dev mode (no --hostname):
  Caddy uses a self-signed certificate (tls internal). HTTP and HTTPS
  are both available. Docker maps external ports to Caddy's :80/:443.
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --hostname)    PUBLIC_HOSTNAME="$2"; shift 2 ;;
        --http-port)   CADDY_HTTP_PORT="$2"; shift 2 ;;
        --https-port)  CADDY_HTTPS_PORT="$2"; shift 2 ;;
        --branch)      BRANCH="$2"; shift 2 ;;
        -h|--help)     usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

# ── Helper functions ──────────────────────────────────────────

log()  { echo -e "\033[1;34m[OSIE]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

require_root() {
    if [[ $EUID -ne 0 ]]; then
        err "This script must be run as root (or with sudo)."
    fi
}

generate_secret() {
    openssl rand -base64 32 | tr -d '/+=' | head -c 32
}

get_public_ipv4s() {
    ip -4 addr show scope global 2>/dev/null \
        | grep -oP 'inet \K[0-9.]+' \
        || hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^$' \
        || true
}

# ── Interactive prompts ───────────────────────────────────────

prompt_mode() {
    if [[ -n "$PUBLIC_HOSTNAME" ]]; then
        DEPLOY_MODE="prod"
        log "Public hostname: $PUBLIC_HOSTNAME"
        return
    fi

    # --http-port or --https-port passed without --hostname → dev mode
    if [[ -n "$CADDY_HTTP_PORT" || -n "$CADDY_HTTPS_PORT" ]]; then
        DEPLOY_MODE="dev"
        prompt_dev_mode
        return
    fi

    echo ""
    log "How should OSIE be exposed?"
    echo ""
    echo "    1) Public domain with automatic HTTPS (Let's Encrypt)"
    echo "    2) IP address with self-signed certificate"
    echo ""
    read -rp "Choose [1/2]: " choice

    case "$choice" in
        1)
            DEPLOY_MODE="prod"
            read -rp "Public hostname (e.g. osie.example.com): " PUBLIC_HOSTNAME
            [[ -z "$PUBLIC_HOSTNAME" ]] && err "Public hostname is required."
            log "Public hostname: $PUBLIC_HOSTNAME"
            ;;
        2)
            DEPLOY_MODE="dev"
            prompt_dev_mode
            ;;
        *)
            err "Invalid choice."
            ;;
    esac
}

prompt_dev_mode() {
    local ips
    ips=$(get_public_ipv4s)

    if [[ -z "$ips" ]]; then
        warn "Could not detect any IPv4 addresses."
        read -rp "Enter the IPv4 address to use: " SELECTED_IP
    else
        echo ""
        log "Detected IPv4 addresses:"
        echo ""
        local i=1
        local ip_array=()
        while IFS= read -r ip; do
            echo "    ${i}) ${ip}"
            ip_array+=("$ip")
            ((i++))
        done <<< "$ips"
        echo ""

        if [[ ${#ip_array[@]} -eq 1 ]]; then
            SELECTED_IP="${ip_array[0]}"
            log "Using ${SELECTED_IP}"
        else
            read -rp "Select IP [1]: " ip_choice
            ip_choice="${ip_choice:-1}"
            SELECTED_IP="${ip_array[$((ip_choice - 1))]}"
        fi
    fi

    if [[ -z "$CADDY_HTTPS_PORT" ]]; then
        read -rp "HTTPS port [443]: " CADDY_HTTPS_PORT
    fi
    CADDY_HTTPS_PORT="${CADDY_HTTPS_PORT:-443}"

    if [[ -z "$CADDY_HTTP_PORT" ]]; then
        read -rp "HTTP port [80]: " CADDY_HTTP_PORT
    fi
    CADDY_HTTP_PORT="${CADDY_HTTP_PORT:-80}"

    if [[ "$CADDY_HTTPS_PORT" == "443" ]]; then
        EXTERNAL_BASE_URL="https://${SELECTED_IP}"
    else
        EXTERNAL_BASE_URL="https://${SELECTED_IP}:${CADDY_HTTPS_PORT}"
    fi

    log "OSIE will be available at ${EXTERNAL_BASE_URL} (self-signed certificate)"
}

# ── DNS verification (prod mode only) ────────────────────────

get_ns_for_domain() {
    local domain="$1"
    local zone="$domain"
    while [[ "$zone" == *.* ]]; do
        ns=$(dig +short NS "$zone" 2>/dev/null | head -1)
        if [[ -n "$ns" ]]; then
            echo "$ns"
            return
        fi
        zone="${zone#*.}"
    done
    echo ""
}

verify_dns() {
    [[ "$DEPLOY_MODE" != "prod" ]] && return 0

    local ips
    ips=$(get_public_ipv4s)

    echo ""
    log "Please create a DNS A record pointing to this server:"
    echo ""
    echo "    ${PUBLIC_HOSTNAME}  ->  one of the following IPs:"
    echo ""
    if [[ -n "$ips" ]]; then
        while IFS= read -r ip; do
            echo "        $ip"
        done <<< "$ips"
    else
        warn "Could not detect public IPs. Use your server's public IP address."
    fi
    echo ""
    read -rp "Press Enter once you have configured the DNS record..."

    log "Checking DNS propagation (querying authoritative nameserver)..."

    local ns
    ns=$(get_ns_for_domain "$PUBLIC_HOSTNAME")
    if [[ -z "$ns" ]]; then
        warn "Could not determine authoritative NS. Falling back to direct dig."
        ns=""
    fi

    local resolved=""
    local attempts=0
    local max_attempts=60

    while [[ $attempts -lt $max_attempts ]]; do
        if [[ -n "$ns" ]]; then
            resolved=$(dig +short A "$PUBLIC_HOSTNAME" "@${ns}" 2>/dev/null | head -1)
        else
            resolved=$(dig +short A "$PUBLIC_HOSTNAME" 2>/dev/null | head -1)
        fi

        if [[ -n "$resolved" ]]; then
            if [[ -n "$ips" ]] && echo "$ips" | grep -qF "$resolved"; then
                log "DNS verified: $PUBLIC_HOSTNAME -> $resolved"
                return 0
            elif [[ -n "$resolved" ]]; then
                warn "DNS resolves to $resolved (not matching detected server IPs)."
                read -rp "Continue anyway? [y/N]: " yn
                if [[ "${yn,,}" == "y" ]]; then
                    return 0
                fi
                read -rp "Press Enter to retry..."
                attempts=0
                continue
            fi
        fi

        ((attempts++))
        if (( attempts % 10 == 0 )); then
            log "Still waiting for DNS... ($attempts/$max_attempts attempts)"
        fi
        sleep 5
    done

    err "DNS verification timed out after $((max_attempts * 5)) seconds. Please verify your DNS configuration."
}

# ── Prerequisites ─────────────────────────────────────────────

install_prerequisites() {
    log "Checking required tools..."

    local required=(git curl openssl)
    [[ "$DEPLOY_MODE" == "prod" ]] && required+=(dig)

    local missing=()
    for cmd in "${required[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        log "All prerequisites available."
        return 0
    fi

    log "Installing missing tools: ${missing[*]}"

    local distro
    distro=$(detect_distro)

    case "$distro" in
        ubuntu|debian)
            apt-get update -y
            local pkgs=()
            for cmd in "${missing[@]}"; do
                case "$cmd" in
                    git)      pkgs+=("git") ;;
                    dig)      pkgs+=("dnsutils") ;;
                    curl)     pkgs+=("curl") ;;
                    openssl)  pkgs+=("openssl") ;;
                esac
            done
            apt-get install -y "${pkgs[@]}"
            ;;
        rhel|almalinux|rocky|centos)
            local pkgs=()
            for cmd in "${missing[@]}"; do
                case "$cmd" in
                    git)      pkgs+=("git") ;;
                    dig)      pkgs+=("bind-utils") ;;
                    curl)     pkgs+=("curl") ;;
                    openssl)  pkgs+=("openssl") ;;
                esac
            done
            dnf install -y "${pkgs[@]}"
            ;;
        *)
            err "Cannot install prerequisites on unsupported distro: $distro. Please install manually: ${missing[*]}"
            ;;
    esac

    log "Prerequisites installed."
}

# ── Docker installation ───────────────────────────────────────

detect_distro() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        echo "${ID}"
    else
        err "Cannot detect Linux distribution. /etc/os-release not found."
    fi
}

install_docker() {
    if command -v docker &>/dev/null; then
        log "Docker is already installed: $(docker --version)"
        return 0
    fi

    log "Installing Docker..."

    local distro
    distro=$(detect_distro)

    case "$distro" in
        ubuntu|debian)
            apt-get remove -y docker.io docker-doc docker-compose podman-docker containerd runc 2>/dev/null || true

            apt-get update -y
            apt-get install -y ca-certificates curl gnupg

            install -m 0755 -d /etc/apt/keyrings
            curl -fsSL "https://download.docker.com/linux/${distro}/gpg" -o /etc/apt/keyrings/docker.asc
            chmod a+r /etc/apt/keyrings/docker.asc

            echo \
                "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${distro} \
                $(. /etc/os-release && echo "${VERSION_CODENAME}") stable" \
                > /etc/apt/sources.list.d/docker.list

            apt-get update -y
            apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;

        rhel|almalinux|rocky|centos)
            dnf remove -y docker docker-client docker-client-latest docker-common \
                docker-latest docker-latest-logrotate docker-logrotate docker-engine 2>/dev/null || true

            dnf install -y dnf-plugins-core

            dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo 2>/dev/null \
                || dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo

            dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;

        *)
            err "Unsupported distribution: $distro. Supported: ubuntu, debian, rhel, almalinux, rocky, centos."
            ;;
    esac

    systemctl enable --now docker
    log "Docker installed successfully: $(docker --version)"
}

# ── Installation ──────────────────────────────────────────────

install_files() {
    log "Installing OSIE to ${INSTALL_DIR}..."

    mkdir -p "${INSTALL_DIR}"

    # Clone the repository (shallow, temporary)
    local tmp_repo
    tmp_repo=$(mktemp -d)
    trap 'rm -rf "${tmp_repo}"' EXIT

    log "Cloning osie/deployment (branch: ${BRANCH})..."
    git clone --depth 1 --branch "${BRANCH}" "${REPO_URL}" "${tmp_repo}"

    local src="${tmp_repo}/docker-compose"

    # Copy base compose and config
    cp "${src}/docker-compose.base.yml" "${INSTALL_DIR}/"
    rm -rf "${INSTALL_DIR}/config"
    cp -r "${src}/config" "${INSTALL_DIR}/"

    # Copy the right compose + Caddyfile for the chosen mode
    mkdir -p "${INSTALL_DIR}/caddy"
    if [[ "$DEPLOY_MODE" == "prod" ]]; then
        cp "${src}/docker-compose.caddy.prod.yml" "${INSTALL_DIR}/docker-compose.yml"
        cp "${src}/caddy/Caddyfile.prod"           "${INSTALL_DIR}/caddy/Caddyfile"
    else
        cp "${src}/docker-compose.caddy.dev.yml"  "${INSTALL_DIR}/docker-compose.yml"
        cp "${src}/caddy/Caddyfile.dev"            "${INSTALL_DIR}/caddy/Caddyfile"
    fi

    # Clean up clone
    rm -rf "${tmp_repo}"
    trap - EXIT

    # Generate .env (preserve secrets from previous install if present)
    generate_env

    # Set permissions
    chown -R root:root "${INSTALL_DIR}"
    chmod 755 "${INSTALL_DIR}"

    log "Files installed to ${INSTALL_DIR}"
}

generate_env() {
    local mongodb_password rabbitmq_password encryption_key

    # Reuse existing secrets on re-install
    if [[ -f "${INSTALL_DIR}/.env" ]]; then
        mongodb_password=$(grep -oP '^MONGODB_PASSWORD=\K.*' "${INSTALL_DIR}/.env" 2>/dev/null || true)
        rabbitmq_password=$(grep -oP '^RABBITMQ_PASSWORD=\K.*' "${INSTALL_DIR}/.env" 2>/dev/null || true)
        encryption_key=$(grep -oP '^OSIE_ENCRYPTION_KEY=\K.*' "${INSTALL_DIR}/.env" 2>/dev/null || true)
    fi

    mongodb_password="${mongodb_password:-$(generate_secret)}"
    rabbitmq_password="${rabbitmq_password:-$(generate_secret)}"
    encryption_key="${encryption_key:-$(openssl rand -base64 32)}"

    if [[ "$DEPLOY_MODE" == "prod" ]]; then
        EXTERNAL_BASE_URL="https://${PUBLIC_HOSTNAME}"
    fi

    cat > "${INSTALL_DIR}/.env" <<ENVEOF
# OSIE — generated by install.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")

EXTERNAL_BASE_URL=${EXTERNAL_BASE_URL}
ENVEOF

    # Mode-specific vars
    if [[ "$DEPLOY_MODE" == "prod" ]]; then
        cat >> "${INSTALL_DIR}/.env" <<ENVEOF
CADDY_DOMAIN=${PUBLIC_HOSTNAME}
ENVEOF
    else
        cat >> "${INSTALL_DIR}/.env" <<ENVEOF
CADDY_HTTP_PORT=${CADDY_HTTP_PORT}
CADDY_HTTPS_PORT=${CADDY_HTTPS_PORT}
ENVEOF
    fi

    cat >> "${INSTALL_DIR}/.env" <<ENVEOF

MONGODB_PASSWORD=${mongodb_password}
RABBITMQ_PASSWORD=${rabbitmq_password}
OSIE_ENCRYPTION_KEY=${encryption_key}

OSIE_API_VERSION=latest
OSIE_UI_VERSION=latest
OSIE_ADMIN_VERSION=latest
ENVEOF

    chmod 600 "${INSTALL_DIR}/.env"
}

start_services() {
    log "Starting OSIE services..."

    cd "${INSTALL_DIR}"

    docker compose up -d

    log "OSIE is starting up. It may take a minute for all services to become healthy."
    log ""
    log "  URL:  ${EXTERNAL_BASE_URL}"
    if [[ "$DEPLOY_MODE" == "dev" ]]; then
        log "  NOTE: Using a self-signed certificate. Your browser will show a security warning."
    fi
    log ""
    log "  Install directory:  ${INSTALL_DIR}"
    log "  Environment:        ${INSTALL_DIR}/.env"
    log "  Caddyfile:          ${INSTALL_DIR}/caddy/Caddyfile"
    log ""
    log "Useful commands:"
    log "  cd ${INSTALL_DIR} && docker compose logs -f"
    log "  cd ${INSTALL_DIR} && docker compose ps"
    log "  cd ${INSTALL_DIR} && docker compose down"
}

# ── Main ──────────────────────────────────────────────────────

main() {
    echo ""
    echo "  ╔═══════════════════════════════════════╗"
    echo "  ║        OSIE Installer (v1.0)          ║"
    echo "  ╚═══════════════════════════════════════╝"
    echo ""

    require_root
    prompt_mode
    install_prerequisites
    verify_dns
    install_docker
    install_files
    start_services

    log "Installation complete!"
}

main
