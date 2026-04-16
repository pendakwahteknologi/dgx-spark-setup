#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# DGX Spark Setup Script
# Configures a fresh DGX Spark (Ubuntu 24.04, aarch64) as an AI workstation.
# ==============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
info() { echo -e "${CYAN}[i]${NC} $*"; }
err()  { echo -e "${RED}[!]${NC} $*" >&2; }

# --- Parse arguments ---

HOSTNAME_VAL=""
DOMAIN=""
CF_TOKEN=""
TS_KEY=""
USER_VAL=""

usage() {
    echo "Usage: $0 --hostname NAME --domain DOMAIN --cloudflare-token TOKEN --tailscale-key KEY --user USER"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --hostname)         HOSTNAME_VAL="$2"; shift 2 ;;
        --domain)           DOMAIN="$2"; shift 2 ;;
        --cloudflare-token) CF_TOKEN="$2"; shift 2 ;;
        --tailscale-key)    TS_KEY="$2"; shift 2 ;;
        --user)             USER_VAL="$2"; shift 2 ;;
        -h|--help)          usage ;;
        *)                  err "Unknown option: $1"; usage ;;
    esac
done

[[ -z "$HOSTNAME_VAL" ]] && { err "--hostname is required"; usage; }
[[ -z "$DOMAIN" ]]       && { err "--domain is required"; usage; }
[[ -z "$USER_VAL" ]]     && { err "--user is required"; usage; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Helper: replace placeholders in a file ---

render_template() {
    local src="$1"
    local dst="$2"
    sed \
        -e "s|{{HOSTNAME}}|${HOSTNAME_VAL}|g" \
        -e "s|{{DOMAIN}}|${DOMAIN}|g" \
        -e "s|{{USER}}|${USER_VAL}|g" \
        "$src" > "$dst"
}

# ==============================================================================
# STEP 1: System basics
# ==============================================================================

log "Step 1: Setting hostname to '${HOSTNAME_VAL}'"
hostnamectl set-hostname "$HOSTNAME_VAL"

log "Step 1: Updating system packages"
apt-get update -qq
apt-get upgrade -y -qq

log "Step 1: Installing base packages"
apt-get install -y -qq \
    nginx \
    python3-venv python3-pip \
    curl wget git jq htop tmux \
    build-essential

# ==============================================================================
# STEP 2: Tailscale
# ==============================================================================

log "Step 2: Installing Tailscale"
if ! command -v tailscale &>/dev/null; then
    curl -fsSL https://tailscale.com/install.sh | sh
fi

if [[ -n "$TS_KEY" ]]; then
    log "Step 2: Connecting to Tailscale"
    tailscale up --authkey="$TS_KEY" --hostname="$HOSTNAME_VAL"
else
    info "Step 2: No Tailscale key provided, skipping auto-join. Run: tailscale up"
fi

# ==============================================================================
# STEP 3: Ollama
# ==============================================================================

log "Step 3: Installing Ollama"
if ! command -v ollama &>/dev/null; then
    curl -fsSL https://ollama.com/install.sh | sh
fi

log "Step 3: Applying Ollama GPU overrides"
mkdir -p /etc/systemd/system/ollama.service.d
render_template "$SCRIPT_DIR/configs/ollama/override.conf" \
    /etc/systemd/system/ollama.service.d/override.conf

systemctl daemon-reload
systemctl enable --now ollama
log "Step 3: Ollama running"

# ==============================================================================
# STEP 4: code-server
# ==============================================================================

log "Step 4: Installing code-server"
if ! command -v code-server &>/dev/null; then
    curl -fsSL https://code-server.dev/install.sh | sh
fi

sudo -u "$USER_VAL" mkdir -p "/home/${USER_VAL}/.config/code-server"
render_template "$SCRIPT_DIR/configs/code-server/config.yaml" \
    "/home/${USER_VAL}/.config/code-server/config.yaml"
chown "$USER_VAL:$USER_VAL" "/home/${USER_VAL}/.config/code-server/config.yaml"

systemctl enable --now "code-server@${USER_VAL}"
log "Step 4: code-server running"

# ==============================================================================
# STEP 5: ComfyUI
# ==============================================================================

log "Step 5: Setting up ComfyUI"
COMFYUI_DIR="/home/${USER_VAL}/ComfyUI"

if [[ ! -d "$COMFYUI_DIR" ]]; then
    sudo -u "$USER_VAL" git clone https://github.com/comfyanonymous/ComfyUI.git "$COMFYUI_DIR"
fi

# Create conda env if conda is available
if command -v conda &>/dev/null; then
    if ! conda env list | grep -q comfyui; then
        log "Step 5: Creating comfyui conda environment"
        sudo -u "$USER_VAL" conda create -n comfyui python=3.11 -y
    fi
    log "Step 5: Installing ComfyUI dependencies"
    sudo -u "$USER_VAL" bash -c "source activate comfyui && cd $COMFYUI_DIR && pip install -r requirements.txt"
else
    info "Step 5: conda not found. Install miniconda, create a 'comfyui' env, and install ComfyUI deps manually."
fi

render_template "$SCRIPT_DIR/configs/systemd/comfyui.service" \
    /etc/systemd/system/comfyui.service
systemctl daemon-reload
systemctl enable comfyui
# Only start if conda env exists
if [[ -d "/home/${USER_VAL}/.conda/envs/comfyui" ]]; then
    systemctl start comfyui
    log "Step 5: ComfyUI running"
else
    info "Step 5: ComfyUI service installed but not started (conda env missing)"
fi

# ==============================================================================
# STEP 6: {{HOSTNAME}}-manager (System Manager API)
# ==============================================================================

log "Step 6: Setting up ${HOSTNAME_VAL}-manager"
mkdir -p "/opt/${HOSTNAME_VAL}-manager"
render_template "$SCRIPT_DIR/atom-manager/app.py" "/opt/${HOSTNAME_VAL}-manager/app.py"

if [[ ! -d "/opt/${HOSTNAME_VAL}-manager/venv" ]]; then
    python3 -m venv "/opt/${HOSTNAME_VAL}-manager/venv"
fi
"/opt/${HOSTNAME_VAL}-manager/venv/bin/pip" install -q fastapi 'uvicorn[standard]'

render_template "$SCRIPT_DIR/configs/systemd/atom-manager.service" \
    "/etc/systemd/system/${HOSTNAME_VAL}-manager.service"
systemctl daemon-reload
systemctl enable --now "${HOSTNAME_VAL}-manager"
log "Step 6: ${HOSTNAME_VAL}-manager running on :9000"

# ==============================================================================
# STEP 7: Dashboard
# ==============================================================================

log "Step 7: Installing dashboard"
DASHBOARD_DIR="/var/www/${HOSTNAME_VAL}-main"
mkdir -p "$DASHBOARD_DIR"
render_template "$SCRIPT_DIR/dashboard/index.html" "$DASHBOARD_DIR/index.html"
log "Step 7: Dashboard at $DASHBOARD_DIR"

# ==============================================================================
# STEP 8: Nginx
# ==============================================================================

log "Step 8: Configuring nginx"
render_template "$SCRIPT_DIR/configs/nginx/site.conf" \
    "/etc/nginx/sites-available/${HOSTNAME_VAL}.conf"
ln -sf "/etc/nginx/sites-available/${HOSTNAME_VAL}.conf" /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl reload nginx
log "Step 8: Nginx configured and reloaded"

# ==============================================================================
# STEP 9: Cloudflare Tunnel
# ==============================================================================

log "Step 9: Setting up Cloudflare Tunnel"
if ! command -v cloudflared &>/dev/null; then
    curl -fsSL https://pkg.cloudflare.com/cloudflared-linux-arm64.deb -o /tmp/cloudflared.deb
    dpkg -i /tmp/cloudflared.deb
    rm /tmp/cloudflared.deb
fi

if [[ -n "$CF_TOKEN" ]]; then
    # Token-based tunnel setup (managed tunnel from Cloudflare dashboard)
    mkdir -p /etc/cloudflared

    cat > /etc/systemd/system/cloudflared.service <<CFSVC
[Unit]
Description=cloudflared
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/cloudflared --no-autoupdate tunnel run --token ${CF_TOKEN}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
CFSVC

    systemctl daemon-reload
    systemctl enable --now cloudflared
    log "Step 9: Cloudflare tunnel running"
else
    info "Step 9: No Cloudflare token provided. Set up manually:"
    info "  cloudflared tunnel login"
    info "  cloudflared tunnel create <name>"
    info "  cloudflared tunnel route dns <name> ${HOSTNAME_VAL}.${DOMAIN}"
    info "  Then edit /etc/cloudflared/config.yml and start the service"
fi

# ==============================================================================
# DONE
# ==============================================================================

echo ""
log "============================================"
log "  Setup complete!"
log "============================================"
echo ""
info "Services:"
info "  Dashboard:     http://localhost:8080/"
info "  Ollama API:    http://localhost:8080/ollama/"
info "  ComfyUI:       http://localhost:8080/comfyui/"
info "  code-server:   http://localhost:8080/code/"
info "  System API:    http://localhost:8080/${HOSTNAME_VAL}-api/stats"
echo ""
info "Public URL:      https://${HOSTNAME_VAL}.${DOMAIN}"
info "Tailscale IP:    $(tailscale ip -4 2>/dev/null || echo 'not connected')"
echo ""
info "Check status:    systemctl status ollama comfyui code-server@${USER_VAL} ${HOSTNAME_VAL}-manager nginx cloudflared"
