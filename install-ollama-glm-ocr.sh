#!/bin/bash
set -euo pipefail

# ── Ollama + glm-ocr installer — macOS · Linux · WSL ─────────────────────────
OLLAMA_HOST="${OLLAMA_HOST:-0.0.0.0}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
NGINX_PORT="${NGINX_PORT:-80}"
MODEL="${MODEL:-glm-ocr}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLUE}[ollama]${NC} $*"; }
ok()    { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
die()   { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

# ── Detect OS ─────────────────────────────────────────────────────────────────
detect_os() {
    case "$(uname -s)" in
        Darwin) echo "macos" ;;
        Linux)
            if grep -qi microsoft /proc/version 2>/dev/null; then
                echo "wsl"
            else
                echo "linux"
            fi
            ;;
        *) die "Unsupported OS: $(uname -s)" ;;
    esac
}

OS=$(detect_os)
info "Detected OS: $OS"

# ── Check GPU ─────────────────────────────────────────────────────────────────
if command -v nvidia-smi &>/dev/null; then
    CUDA_VERSION=$(nvidia-smi | grep -oP 'CUDA Version: \K[0-9]+\.[0-9]+' || true)
    ok "NVIDIA GPU detected — CUDA $CUDA_VERSION"
else
    warn "No NVIDIA GPU detected — Ollama will run on CPU"
fi

# ── Install Ollama ────────────────────────────────────────────────────────────
install_ollama() {
    if command -v ollama &>/dev/null; then
        ok "Ollama already installed ($(ollama --version 2>/dev/null || echo 'unknown version'))"
        return
    fi

    info "Installing Ollama..."
    case "$OS" in
        macos)
            if command -v brew &>/dev/null; then
                brew install ollama
            else
                curl -fsSL https://ollama.com/install.sh | sh
            fi
            ;;
        linux|wsl)
            curl -fsSL https://ollama.com/install.sh | sh
            ;;
    esac
    ok "Ollama installed"
}

install_ollama

# ── Start Ollama server ───────────────────────────────────────────────────────
start_ollama_server() {
    if curl -sf "http://127.0.0.1:${OLLAMA_PORT}/api/tags" &>/dev/null; then
        ok "Ollama server already running on port ${OLLAMA_PORT}"
        return
    fi

    info "Starting Ollama server (host=${OLLAMA_HOST} port=${OLLAMA_PORT})..."

    export OLLAMA_HOST="${OLLAMA_HOST}:${OLLAMA_PORT}"

    case "$OS" in
        macos)
            OLLAMA_HOST="${OLLAMA_HOST}" nohup ollama serve > /tmp/ollama.log 2>&1 &
            ;;
        linux|wsl)
            if systemctl is-active --quiet ollama 2>/dev/null; then
                ok "Ollama systemd service already running"
            elif systemctl list-unit-files ollama.service &>/dev/null 2>&1; then
                sudo systemctl enable --now ollama
                ok "Ollama systemd service started"
            else
                OLLAMA_HOST="${OLLAMA_HOST}" nohup ollama serve > /tmp/ollama.log 2>&1 &
            fi
            ;;
    esac

    # Wait for the server to come up
    info "Waiting for Ollama server to be ready..."
    for i in $(seq 1 30); do
        if curl -sf "http://127.0.0.1:${OLLAMA_PORT}/api/tags" &>/dev/null; then
            ok "Ollama server ready"
            return
        fi
        sleep 1
    done
    die "Ollama server did not start within 30 seconds — check /tmp/ollama.log"
}

start_ollama_server

# ── Pull model ────────────────────────────────────────────────────────────────
info "Pulling model: ${MODEL} (this may take a while)..."
ollama pull "$MODEL"
ok "Model '${MODEL}' ready"

# ── Install & configure nginx ─────────────────────────────────────────────────
install_nginx() {
    if command -v nginx &>/dev/null; then
        ok "nginx already installed"
        return
    fi
    info "Installing nginx..."
    case "$OS" in
        macos) brew install nginx -q ;;
        linux|wsl)
            if command -v apt-get &>/dev/null; then
                sudo apt-get install -y -qq nginx
            elif command -v yum &>/dev/null; then
                sudo yum install -y -q nginx
            elif command -v dnf &>/dev/null; then
                sudo dnf install -y -q nginx
            else
                die "Cannot install nginx — unknown package manager"
            fi
            ;;
    esac
    ok "nginx installed"
}

configure_nginx() {
    local conf_dir
    case "$OS" in
        macos) conf_dir="$(brew --prefix)/etc/nginx/servers" ;;
        *)     conf_dir="/etc/nginx/conf.d" ;;
    esac

    local conf_file="${conf_dir}/ollama.conf"
    info "Writing nginx config to ${conf_file}..."

    sudo tee "$conf_file" > /dev/null <<NGINX
server {
    listen ${NGINX_PORT};
    listen [::]:${NGINX_PORT};

    location / {
        proxy_pass         http://127.0.0.1:${OLLAMA_PORT};
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 300;
    }
}
NGINX

    ok "nginx config written"
}

start_nginx() {
    info "Starting nginx..."
    sudo nginx -t || die "nginx configuration test failed"
    case "$OS" in
        macos)
            brew services restart nginx 2>/dev/null \
                || nginx -s reload 2>/dev/null \
                || nginx
            ;;
        linux|wsl)
            if sudo systemctl restart nginx 2>/dev/null; then
                :
            elif sudo service nginx restart 2>/dev/null; then
                :
            else
                sudo nginx
            fi
            ;;
    esac
    ok "nginx running on port ${NGINX_PORT}"
}

install_nginx
configure_nginx
start_nginx

# ── Done ──────────────────────────────────────────────────────────────────────
if [[ "$NGINX_PORT" == "80" ]]; then
    ACCESS_URL="http://localhost"
else
    ACCESS_URL="http://localhost:${NGINX_PORT}"
fi

echo ""
ok "Installation complete!"
echo ""
info "Ollama API available at ${ACCESS_URL}"
info "Direct Ollama port:    http://127.0.0.1:${OLLAMA_PORT}"
echo ""
info "Run the model interactively:  ollama run ${MODEL}"
info "API example:"
echo "  curl ${ACCESS_URL}/api/generate -d '{\"model\":\"${MODEL}\",\"prompt\":\"Hello\"}'"
echo ""

# ── Start interactive session ─────────────────────────────────────────────────
exec ollama run "$MODEL"
