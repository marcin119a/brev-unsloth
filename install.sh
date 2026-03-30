#!/usr/bin/env bash
set -euo pipefail

# ── Unsloth installer — macOS · Linux · WSL ──────────────────────────────────
UNSLOTH_ENV="${UNSLOTH_ENV:-unsloth}"
PYTHON_VERSION="${PYTHON_VERSION:-3.11}"
HOST="${UNSLOTH_HOST:-0.0.0.0}"
PORT="${UNSLOTH_PORT:-8888}"

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

# ── Launch ────────────────────────────────────────────────────────────────────
echo ""
ok "Installation complete!"
echo ""
info "Launching Unsloth Studio on http://${HOST}:${PORT} ..."
echo ""

if command -v unsloth &>/dev/null && unsloth --help 2>&1 | grep -q studio; then
    exec unsloth studio -H "$HOST" -p "$PORT"
else
    # Fallback: launch Jupyter Lab with unsloth pre-loaded
    exec jupyter lab \
        --ip="$HOST" \
        --port="$PORT" \
        --no-browser \
        --NotebookApp.token='' \
        --NotebookApp.password=''
fi
