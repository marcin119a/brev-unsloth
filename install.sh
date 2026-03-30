#!/bin/bash
set -euo pipefail

# ── Unsloth installer — macOS · Linux · WSL ──────────────────────────────────
UNSLOTH_ENV="${UNSLOTH_ENV:-unsloth}"
PYTHON_VERSION="${PYTHON_VERSION:-3.11}"
HOST="127.0.0.1"
PORT="${UNSLOTH_PORT:-8888}"
NGINX_PORT="${NGINX_PORT:-443}"
DOMAIN="${DOMAIN:-}"           # set to enable Let's Encrypt, e.g. DOMAIN=example.com
ACME_EMAIL="${ACME_EMAIL:-}"   # required for Let's Encrypt

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLUE}[unsloth]${NC} $*"; }
ok()    { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
die()   { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

# ── Detect OS / environment ───────────────────────────────────────────────────
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

# ── Detect CUDA ───────────────────────────────────────────────────────────────
CUDA_VERSION=""
if command -v nvcc &>/dev/null; then
    CUDA_VERSION=$(nvcc --version | grep -oP 'release \K[0-9]+\.[0-9]+')
elif command -v nvidia-smi &>/dev/null; then
    CUDA_VERSION=$(nvidia-smi | grep -oP 'CUDA Version: \K[0-9]+\.[0-9]+' || true)
fi

if [[ -n "$CUDA_VERSION" ]]; then
    CUDA_MAJOR=$(echo "$CUDA_VERSION" | cut -d. -f1)
    ok "NVIDIA GPU detected — CUDA $CUDA_VERSION"
else
    warn "No NVIDIA GPU detected — installing CPU-only build"
    CUDA_MAJOR=""
fi

# ── Ensure conda / mamba ──────────────────────────────────────────────────────
ensure_conda() {
    if command -v mamba &>/dev/null; then
        CONDA_CMD="mamba"; return
    fi
    if command -v conda &>/dev/null; then
        CONDA_CMD="conda"; return
    fi

    info "Installing Miniforge3..."
    local installer
    case "$OS" in
        macos)
            local arch
            arch=$(uname -m)
            installer="Miniforge3-MacOSX-${arch}.sh"
            ;;
        linux|wsl)
            installer="Miniforge3-Linux-x86_64.sh"
            ;;
    esac

    curl -fsSL "https://github.com/conda-forge/miniforge/releases/latest/download/${installer}" \
        -o /tmp/miniforge.sh
    bash /tmp/miniforge.sh -b -p "$HOME/miniforge3"
    rm /tmp/miniforge.sh

    export PATH="$HOME/miniforge3/bin:$PATH"
    conda init bash 2>/dev/null || true
    [[ -f "$HOME/.zshrc" ]] && conda init zsh 2>/dev/null || true

    CONDA_CMD="mamba"
    ok "Miniforge3 installed"
}

ensure_conda

# ── Create / activate conda env ───────────────────────────────────────────────
if $CONDA_CMD env list | awk '{print $1}' | grep -qx "$UNSLOTH_ENV"; then
    info "Conda env '$UNSLOTH_ENV' already exists — skipping creation"
else
    info "Creating conda env '$UNSLOTH_ENV' (Python $PYTHON_VERSION)..."
    $CONDA_CMD create -n "$UNSLOTH_ENV" python="$PYTHON_VERSION" -y
fi

# Activate env
eval "$($CONDA_CMD shell.bash hook 2>/dev/null || conda shell.bash hook)"
conda activate "$UNSLOTH_ENV"

# ── Install PyTorch ───────────────────────────────────────────────────────────
info "Installing PyTorch..."
if [[ -n "$CUDA_MAJOR" ]]; then
    case "$CUDA_MAJOR" in
        12) TORCH_INDEX="https://download.pytorch.org/whl/cu124" ;;
        11) TORCH_INDEX="https://download.pytorch.org/whl/cu118" ;;
        *)  TORCH_INDEX="https://download.pytorch.org/whl/cu124" ;;
    esac
    pip install torch torchvision torchaudio --index-url "$TORCH_INDEX" -q
else
    pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu -q
fi
ok "PyTorch installed"

# ── Install Unsloth ───────────────────────────────────────────────────────────
info "Installing Unsloth..."
if [[ -n "$CUDA_MAJOR" ]]; then
    pip install "unsloth[cu${CUDA_MAJOR}xx-torch260]" -q 2>/dev/null \
        || pip install "unsloth[colab-new]" -q
else
    pip install "unsloth[cpu]" -q 2>/dev/null \
        || pip install unsloth -q
fi
ok "Unsloth installed"

# ── Install Unsloth Studio (Jupyter + UI) ────────────────────────────────────
info "Installing Unsloth Studio..."
pip install unsloth-studio -q 2>/dev/null || pip install jupyterlab ipywidgets -q
ok "Unsloth Studio installed"

# ── TLS certificate ───────────────────────────────────────────────────────────
CERT_DIR="${HOME}/.unsloth/tls"
CERT_FILE="${CERT_DIR}/cert.pem"
KEY_FILE="${CERT_DIR}/key.pem"

install_certbot() {
    if command -v certbot &>/dev/null; then return; fi
    info "Installing certbot..."
    case "$OS" in
        macos) brew install certbot -q ;;
        linux|wsl)
            if command -v apt-get &>/dev/null; then
                sudo apt-get install -y -qq certbot python3-certbot-nginx
            elif command -v dnf &>/dev/null; then
                sudo dnf install -y -q certbot python3-certbot-nginx
            elif command -v yum &>/dev/null; then
                sudo yum install -y -q certbot python3-certbot-nginx
            else
                # Universal fallback via pip
                pip install certbot certbot-nginx -q
            fi
            ;;
    esac
    ok "certbot installed"
}

obtain_letsencrypt_cert() {
    [[ -z "$DOMAIN" ]] && return 1
    [[ -z "$ACME_EMAIL" ]] && die "ACME_EMAIL is required for Let's Encrypt (e.g. ACME_EMAIL=you@example.com)"

    install_certbot

    info "Obtaining Let's Encrypt certificate for ${DOMAIN}..."

    # Temporarily allow port 80 through nginx for HTTP-01 challenge
    local le_cert_dir="/etc/letsencrypt/live/${DOMAIN}"
    sudo certbot certonly \
        --nginx \
        --non-interactive \
        --agree-tos \
        --email "$ACME_EMAIL" \
        -d "$DOMAIN" \
        2>/dev/null \
    || sudo certbot certonly \
        --standalone \
        --non-interactive \
        --agree-tos \
        --email "$ACME_EMAIL" \
        -d "$DOMAIN"

    CERT_FILE="${le_cert_dir}/fullchain.pem"
    KEY_FILE="${le_cert_dir}/privkey.pem"

    # Auto-renewal via cron (idempotent)
    (crontab -l 2>/dev/null | grep -q 'certbot renew') \
        || (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet --post-hook 'nginx -s reload'") \
            | crontab -

    ok "Let's Encrypt certificate obtained: ${CERT_FILE}"
    ok "Auto-renewal cron job configured"
}

obtain_selfsigned_cert() {
    if [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]]; then
        ok "Reusing existing self-signed certificate: ${CERT_FILE}"
        return
    fi
    info "Generating self-signed TLS certificate..."
    mkdir -p "$CERT_DIR"
    local san="IP:127.0.0.1,DNS:localhost"
    [[ -n "$DOMAIN" ]] && san="${san},DNS:${DOMAIN}"
    openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 \
        -nodes \
        -keyout "$KEY_FILE" \
        -out "$CERT_FILE" \
        -subj "/CN=${DOMAIN:-unsloth-local}" \
        -addext "subjectAltName=${san}" \
        2>/dev/null
    chmod 600 "$KEY_FILE"
    ok "Self-signed certificate generated: ${CERT_FILE}"
}

if [[ -n "$DOMAIN" ]]; then
    obtain_letsencrypt_cert || obtain_selfsigned_cert
else
    warn "No DOMAIN set — using self-signed certificate (fine for local use)"
    warn "For a trusted cert run: DOMAIN=yourdomain.com ACME_EMAIL=you@example.com ./install.sh"
    obtain_selfsigned_cert
fi

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

    local conf_file="${conf_dir}/unsloth.conf"
    info "Writing nginx config to ${conf_file}..."

    sudo tee "$conf_file" > /dev/null <<NGINX
server {
    listen ${NGINX_PORT} ssl;
    listen [::]:${NGINX_PORT} ssl;

    ssl_certificate     ${CERT_FILE};
    ssl_certificate_key ${KEY_FILE};
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    # WebSocket support (required by Jupyter)
    location / {
        proxy_pass         http://${HOST}:${PORT};
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_read_timeout 86400;
    }
}
NGINX

    ok "nginx config written"
}

start_nginx() {
    info "Starting nginx..."
    case "$OS" in
        macos)
            brew services restart nginx 2>/dev/null \
                || nginx -s reload 2>/dev/null \
                || nginx
            ;;
        linux|wsl)
            sudo nginx -t && sudo systemctl restart nginx 2>/dev/null \
                || sudo nginx -t && sudo service nginx restart
            ;;
    esac
    ok "nginx running on port ${NGINX_PORT}"
}

install_nginx
configure_nginx
start_nginx

# ── Launch ────────────────────────────────────────────────────────────────────
echo ""
ok "Installation complete!"
echo ""
info "Unsloth Studio available at https://localhost:${NGINX_PORT}"
warn "Self-signed certificate — your browser will show a security warning. That is expected."
echo ""

if command -v unsloth &>/dev/null && unsloth --help 2>&1 | grep -q studio; then
    exec unsloth studio -H "$HOST" -p "$PORT"
else
    exec jupyter lab \
        --ip="$HOST" \
        --port="$PORT" \
        --no-browser \
        --NotebookApp.token='' \
        --NotebookApp.password=''
fi
