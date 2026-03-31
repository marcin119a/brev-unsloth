#!/bin/bash
set -euo pipefail

PORT=8888
NGINX_PORT=80

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { echo -e "${BLUE}[unsloth]${NC} $*"; }
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
die()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

# ── Fix ollama CUDA library permissions (needed for llama.cpp prebuilt) ───────
if [[ -d /usr/local/lib/ollama ]]; then
    info "Fixing ollama CUDA library permissions..."
    sudo chmod -R a+r /usr/local/lib/ollama
    sudo find /usr/local/lib/ollama -type d -exec chmod a+x {} \;
    ok "Permissions fixed"
fi

# ── Install Unsloth ───────────────────────────────────────────────────────────
info "Installing Unsloth..."
curl -fsSL https://unsloth.ai/install.sh | sh
ok "Unsloth installed"

# ── Install nginx ─────────────────────────────────────────────────────────────
if ! command -v nginx &>/dev/null; then
    info "Installing nginx..."
    if command -v apt-get &>/dev/null; then
        sudo apt-get install -y -qq nginx
    elif command -v yum &>/dev/null; then
        sudo yum install -y -q nginx
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y -q nginx
    else
        die "Cannot install nginx — unknown package manager"
    fi
    ok "nginx installed"
else
    ok "nginx already installed"
fi

# ── Configure nginx proxy ─────────────────────────────────────────────────────
info "Configuring nginx..."

if [[ -f /etc/nginx/sites-enabled/default ]]; then
    sudo rm -f /etc/nginx/sites-enabled/default
fi

sudo tee /etc/nginx/conf.d/unsloth.conf > /dev/null <<NGINX
server {
    listen ${NGINX_PORT};
    listen [::]:${NGINX_PORT};

    location / {
        proxy_pass         http://127.0.0.1:${PORT};
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 86400;
    }
}
NGINX

sudo nginx -t || die "nginx config test failed"

if sudo systemctl restart nginx 2>/dev/null; then
    :
elif sudo service nginx restart 2>/dev/null; then
    :
else
    sudo nginx
fi
ok "nginx running on port ${NGINX_PORT}"

# ── Start Unsloth Studio ──────────────────────────────────────────────────────
ok "Installation complete!"
info "Starting Unsloth Studio on 0.0.0.0:${PORT} (proxied via port ${NGINX_PORT})..."
echo ""

unsloth studio -H 0.0.0.0 -p "$PORT"
