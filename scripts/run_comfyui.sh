#!/usr/bin/env bash
# ==============================================================================
# run_comfyui.sh — ComfyUI Server launcher with GPU detection, port guard, venv
#
# Usage:
#   bash scripts/run_comfyui.sh [options] [-- extra python args]
#
# Options:
#   --port PORT       Port to listen on (default: 8188)
#   --no-guard        Skip port-in-use check
#   --no-gpu-detect   Skip GPU detection, use device 0
#   --vram-mode MODE  VRAM mode: auto|high|normal|low|cpu (default: auto)
#   -h, --help        Show this help
#
# Examples:
#   bash scripts/run_comfyui.sh
#   bash scripts/run_comfyui.sh --port 8288
#   bash scripts/run_comfyui.sh --no-guard -- --force-fp16
#   bash scripts/run_comfyui.sh --vram-mode high
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Ensure ROCm tools (like rocm-smi) are in PATH even when launched from GUI environments (Tauri/Desktop)
export PATH="/opt/rocm/bin:/opt/rocm-7.2.4/bin:$PATH"

# Ensure ROCm runtime libraries (libroctx64.so.4, libhsa-runtime64.so.1, etc.) are
# discoverable by the dynamic linker. On Ubuntu, /opt/rocm/lib is NOT in the default
# ldconfig search path; the system .conf file only points to /opt/rocm-5.4.1/lib.
# Prepend rather than append so ROCm's libs win over any stale 5.4.1 versions.
if [ -d /opt/rocm/lib ]; then
    # Note: ${LD_LIBRARY_PATH:-} is needed because the script runs with 'set -u',
    # and LD_LIBRARY_PATH may be unset when launched from a minimal environment.
    case ":${LD_LIBRARY_PATH:-}:" in
        *:/opt/rocm/lib:*) ;;  # already present
        *) export LD_LIBRARY_PATH="/opt/rocm/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ;;
    esac
fi

PORT=8188
GUARD=true
GPU_DETECT=true
VRAM_MODE=""

usage() {
  sed -n '3,17p' "$0" | sed 's/^#//; s/^ //'
  exit 0
}

# Parse known options, pass rest to ComfyUI
EXTRA_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage ;;
    --port) PORT="$2"; shift 2 ;;
    --no-guard) GUARD=false; shift ;;
    --no-gpu-detect) GPU_DETECT=false; shift ;;
    --vram-mode)
      if [[ $# -lt 2 ]]; then
        echo "Error: --vram-mode requires a value (auto|high|normal|low|cpu)" >&2
        exit 1
      fi
      VRAM_MODE="$2"
      shift 2
      ;;
    --) shift; EXTRA_ARGS+=("$@"); break ;;
    *) EXTRA_ARGS+=("$1"); shift ;;
  esac
done

# ── Port guard ─────────────────────────────────────────────────────────────────
if $GUARD; then
  if ss -tlnp 2>/dev/null | grep -q ":${PORT} "; then
    echo "ComfyUI already running on port ${PORT}, skipping start."
    # Wait forever so systemd/service manager thinks process is healthy
    sleep infinity
  fi
fi

# ── GPU detection ──────────────────────────────────────────────────────────────
DETECTED_GPU="0"
if $GPU_DETECT; then
  DETECTED_GPU=$(rocm-smi --showmeminfo vram 2>/dev/null \
    | grep "VRAM Total Memory" \
    | awk -F'[][]' '{print $2, $NF}' \
    | awk '{print $1, $NF}' \
    | sort -k2 -rn \
    | head -n 1 \
    | awk '{print $1}')
  DETECTED_GPU="${DETECTED_GPU:-0}"
fi

echo "ComfyUI launcher — GPU $DETECTED_GPU | port $PORT | guard=$GUARD | vram_mode=${VRAM_MODE:-auto}"

export HIP_VISIBLE_DEVICES="$DETECTED_GPU"
export HSA_OVERRIDE_GFX_VERSION="10.3.0"

# Note: --normalvram was removed in ComfyUI v0.25 — default (no flag) is dynamic VRAM.
COMFYUI_VRAM_ARGS=()
if [[ "$VRAM_MODE" == "auto" || -z "$VRAM_MODE" ]]; then
  VRAM_BYTES=$(grep "GPU\[${DETECTED_GPU}\]" -A 20 <(rocm-smi --showmeminfo vram 2>/dev/null) \
    | grep "VRAM Total Memory" | head -n1 | grep -oE '[0-9]{5,}' | head -n1 || true)
  VRAM_BYTES="${VRAM_BYTES:-0}"
  if [[ "$VRAM_BYTES" -ge 12000000000 ]]; then
    COMFYUI_VRAM_ARGS=(--highvram)
  elif [[ "$VRAM_BYTES" -lt 6000000000 ]]; then
    COMFYUI_VRAM_ARGS=(--lowvram)
  fi
  # else: no flag = dynamic VRAM
elif [[ "$VRAM_MODE" == "high" ]]; then
  COMFYUI_VRAM_ARGS=(--highvram)
elif [[ "$VRAM_MODE" == "low" ]]; then
  COMFYUI_VRAM_ARGS=(--lowvram)
elif [[ "$VRAM_MODE" == "cpu" ]]; then
  COMFYUI_VRAM_ARGS=(--cpu)
elif [[ "$VRAM_MODE" == "normal" ]]; then
  : # no flag needed — default is dynamic VRAM
else
  echo "Warning: unknown --vram-mode '$VRAM_MODE', falling back to auto" >&2
fi

# ── Activate venv ──────────────────────────────────────────────────────────────
COMFYUI_PYTHON=""
if [ -f "$ROOT_DIR/venv/bin/python3.12" ]; then
  COMFYUI_PYTHON="$ROOT_DIR/venv/bin/python3.12"
elif [ -f "$ROOT_DIR/venv/bin/python" ]; then
  COMFYUI_PYTHON="$ROOT_DIR/venv/bin/python"
elif [[ -n "${VIRTUAL_ENV:-}" && -f "${VIRTUAL_ENV}/bin/python3.12" ]]; then
  COMFYUI_PYTHON="${VIRTUAL_ENV}/bin/python3.12"
elif [[ -n "${VIRTUAL_ENV:-}" && -f "${VIRTUAL_ENV}/bin/python" ]]; then
  COMFYUI_PYTHON="${VIRTUAL_ENV}/bin/python"
fi

if [[ -z "$COMFYUI_PYTHON" ]]; then
  echo "Warning: ComfyUI venv not found at $ROOT_DIR/venv — falling back to 'python'" >&2
  COMFYUI_PYTHON="python"
fi

if [[ "$COMFYUI_PYTHON" == "$ROOT_DIR/venv/bin/python"* || "$COMFYUI_PYTHON" == "${VIRTUAL_ENV:-}/bin/python"* ]]; then
  echo "Installing common missing dependencies into ComfyUI venv..." >&2
  "$COMFYUI_PYTHON" -m pip install --disable-pip-version-check --no-input --quiet \
    scikit-image opencv-python-headless || true
fi

# Use a stable per-user cache dir so ROCm/Torch/Triton caches survive project
# moves, reinstall, and ComfyUI backend changes.
COMFYUI_XDG_CACHE="${HOME}/.cache/comfyui-desktop"
COMFYUI_HIP_CACHE="${COMFYUI_XDG_CACHE}/hip"
mkdir -p "$COMFYUI_XDG_CACHE" "$COMFYUI_HIP_CACHE"
export XDG_CACHE_HOME="$COMFYUI_XDG_CACHE"
export HIP_CACHE_DIR="$COMFYUI_HIP_CACHE"
export PYTHONPYCACHEPREFIX="${ROOT_DIR}/.pycache"

# ── ROCm stability fixes ──────────────────────────────────────────────────────
export PYTORCH_HIP_ALLOC_CONF="expandable_segments:1"
export AMD_SERIALIZE_KERNEL=3
export HIP_LAUNCH_QUEUE_DUPLICATE_KERNEL_ATTENUATION=1
export TORCH_HIP_DISABLE_TRITON_MMA=1
export HIP_DISABLE_RDC=1
export HIPCC_VERBOSE=0

# ── ROCm/HIP logging (helps detect hang vs stuck) ─────────────────────────────
export HIP_LOG_LEVEL=5
export AMD_LOG_LEVEL=5
export ROCR_DEBUG=1
export Caffe2_log_level=0

# ── Disable ComfyUI-Manager network fetch during execution ─────────────────────
MANAGER_CONFIG="$ROOT_DIR/ComfyUI/user/__manager/config.ini"
if [ -f "$MANAGER_CONFIG" ]; then
  sed -i 's/^network_mode = .*/network_mode = offline/' "$MANAGER_CONFIG"
fi

# ── Launch ─────────────────────────────────────────────────────────────────────
echo "Starting ComfyUI Server on port $PORT..."
echo "ComfyUI python: ${COMFYUI_PYTHON}"
exec "${COMFYUI_PYTHON}" "$ROOT_DIR/ComfyUI/main.py" \
  --extra-model-paths-config "$ROOT_DIR/extra_model_paths.yaml" \
  --output-directory "$HOME/SharedData/Output" \
  --input-directory "$HOME/SharedData/Input" \
  --user-directory "$HOME/SharedData/User" \
  --listen 127.0.0.1 \
  --port "$PORT" \
  --high-ram \
  "${COMFYUI_VRAM_ARGS[@]}" \
  "${EXTRA_ARGS[@]}"
