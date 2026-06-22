#!/usr/bin/env bash
# ==============================================================================
# install_deps.sh — Full setup: Python venv, deps, ComfyUI-Manager, Frontend
# Run from root project: bash scripts/install_deps.sh
# ==============================================================================
set -e

# Load nvm if available (for Node.js version management)
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
nvm use 25 2>/dev/null || true
export PATH="$NVM_DIR/versions/node/v25.9.0/bin:$PATH"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_DIR="$ROOT_DIR/venv"
REQ_FILE="$ROOT_DIR/requirements.txt"

echo "========================================"
echo " ComfyUI Desktop — Full Installer"
echo "========================================"
echo ""

# 1. Check if python3.12 is installed (or installable via uv/apt)
echo "[1/5] Checking for Python 3.12..."
NEEDS_PY312_INSTALL=0
if command -v python3.12 &>/dev/null; then
    echo "  ✅ Python 3.12 is available: $(python3.12 --version)"
elif command -v uv &>/dev/null; then
    echo "  Python 3.12 not on PATH, but uv is available — will install via uv."
    NEEDS_PY312_INSTALL=1
elif command -v apt-get &>/dev/null; then
    echo "  Python 3.12 not on PATH, but apt-get is available — will install via apt."
    NEEDS_PY312_INSTALL=1
    PKG_MANAGER="apt"
else
    echo "❌ Error: Python 3.12 is not installed and no package manager (uv/apt) found."
    echo "This project requires Python 3.12 specifically for ROCm compatibility."
    echo "Install it using one of:"
    echo "  - uv (recommended): curl -LsSf https://astral.sh/uv/install.sh | sh"
    echo "  - apt (Debian/Ubuntu): sudo apt install -y python3.12 python3.12-venv python3.12-dev"
    echo "  - dnf (Fedora):       sudo dnf install -y python3.12 python3.12-devel"
    exit 1
fi

# 2. Check and initialize virtual environment
echo "[2/5] Setting up Python virtual environment..."
if [ ! -d "$VENV_DIR" ]; then
    echo "  Virtual environment not found. Creating one at $VENV_DIR..."
    if [ "$NEEDS_PY312_INSTALL" -eq 1 ] && command -v uv &>/dev/null; then
        # uv can install Python 3.12 and create the venv in one step
        uv venv "$VENV_DIR" --python 3.12 --seed
    elif [ "$NEEDS_PY312_INSTALL" -eq 1 ] && [ "${PKG_MANAGER:-}" = "apt" ]; then
        # apt: install system Python 3.12 then create venv
        SUDO=""
        [ "$(id -u)" -ne 0 ] && SUDO="sudo"
        $SUDO apt-get update -y >/dev/null
        $SUDO apt-get install -y python3.12 python3.12-venv python3.12-dev
        python3.12 -m venv "$VENV_DIR"
    else
        python3.12 -m venv "$VENV_DIR"
    fi
    echo "  ✅ Virtual environment created."
else
    echo "  ✅ Virtual environment already exists at $VENV_DIR."
fi

# Activate venv for the remaining commands
# shellcheck source=/dev/null
source "$VENV_DIR/bin/activate"

# Upgrade pip and toolchain inside the venv
echo "  Upgrading pip, setuptools, and wheel..."
pip install --upgrade pip setuptools wheel

# 3. Install requirements.txt
echo "[3/5] Installing Python dependencies from requirements.txt..."
if [ ! -f "$REQ_FILE" ]; then
    echo "❌ Error: requirements.txt not found at $REQ_FILE"
    exit 1
fi

echo "  This may take a few minutes as it downloads PyTorch ROCm wheels..."
pip install -r "$REQ_FILE"

echo ""
echo "✅ Python dependencies installed successfully."

# 4. Setup ComfyUI-Manager (forked version)
echo ""
echo "[4/5] Setting up ComfyUI-Manager..."
CUSTOM_NODES_DIR="$ROOT_DIR/ComfyUI/custom_nodes"
FORKED_MANAGER="$ROOT_DIR/ComfyUI-Manager"
MANAGER_CONFIG="$ROOT_DIR/ComfyUI/user/__manager/config.ini"

if [ -d "$FORKED_MANAGER" ]; then
    if [ -d "$CUSTOM_NODES_DIR/ComfyUI-Manager" ]; then
        rm -rf "$CUSTOM_NODES_DIR/ComfyUI-Manager"
    fi
    cp -r "$FORKED_MANAGER" "$CUSTOM_NODES_DIR/ComfyUI-Manager"
    echo "  ✅ Using forked ComfyUI-Manager from $FORKED_MANAGER"
else
    echo "  ⚠️  Forked ComfyUI-Manager not found at $FORKED_MANAGER"
    echo "     Using existing ComfyUI-Manager in custom_nodes/"
fi

# Disable network fetch in ComfyUI-Manager
if [ -f "$MANAGER_CONFIG" ]; then
    sed -i 's/^network_mode = .*/network_mode = offline/' "$MANAGER_CONFIG"
    echo "  ✅ ComfyUI-Manager network_mode set to offline"
else
    mkdir -p "$(dirname "$MANAGER_CONFIG")"
    echo -e "[default]\nnetwork_mode = offline" > "$MANAGER_CONFIG"
    echo "  ✅ ComfyUI-Manager config created with network_mode=offline"
fi

# Copy Desktop Logs extension to ComfyUI custom_nodes
EXTENSIONS_SRC="$ROOT_DIR/extensions"
EXTENSIONS_DST="$ROOT_DIR/ComfyUI/custom_nodes"
if [ -d "$EXTENSIONS_SRC/ComfyUI-Desktop-Logs" ]; then
    echo "  Copying ComfyUI-Desktop-Logs extension..."
    cp -r "$EXTENSIONS_SRC/ComfyUI-Desktop-Logs" "$EXTENSIONS_DST/"
    echo "  ✅ Desktop Logs extension installed."
fi

echo ""
echo "✅ ComfyUI-Manager setup complete."

# 5. Build ComfyUI Frontend (forked version)
echo ""
echo "[5/5] Building ComfyUI Frontend..."
FRONTEND_DIR="$ROOT_DIR/ComfyUI_frontend"

if [ -d "$FRONTEND_DIR" ]; then
    echo "  Installing frontend dependencies..."
    cd "$FRONTEND_DIR"
    
    # Check if pnpm is available
    if command -v pnpm &>/dev/null; then
        pnpm install --frozen-lockfile 2>/dev/null || pnpm install --ignore-engines
        echo "  Building frontend..."
        pnpm build
        echo "  ✅ Frontend built successfully."
    elif command -v npm &>/dev/null; then
        echo "  ⚠️  pnpm not found, using npm instead."
        npm install
        npm run build
        echo "  ✅ Frontend built successfully."
    else
        echo "  ❌ Error: Neither pnpm nor npm found."
        echo "     Please install Node.js and pnpm/npm."
        exit 1
    fi
    cd "$ROOT_DIR"
else
    echo "  ⚠️  ComfyUI_frontend not found at $FRONTEND_DIR"
    echo "     Skipping frontend build."
fi

echo ""
echo "========================================"
echo "✅ FULL SETUP COMPLETE!"
echo "========================================"
echo ""
echo "Next steps:"
echo "  1. Run: bash scripts/run_comfyui.sh"
echo "  2. Or use menu: ./comfyui-arwaky"
