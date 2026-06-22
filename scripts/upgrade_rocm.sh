#!/bin/bash
# ==============================================================================
# upgrade_rocm.sh — Install / upgrade ROCm 7.2.4 packages for AMD GPU
# Supports: Ubuntu/Debian (apt), Fedora/RHEL (dnf)
# Usage: sudo bash upgrade_rocm.sh [--version 7.2.4] [--family apt|dnf]
# ==============================================================================
set -euo pipefail

step() { echo "==> $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: sudo bash upgrade_rocm.sh [--version 7.2.4] [--family apt|dnf]

Install / upgrade ROCm runtime libraries needed by PyTorch ROCm wheels.
Auto-detects the package family. Defaults to ROCm 7.2.4.
EOF
}

ROCM_VERSION=""
PKG_FAMILY=""
while [ $# -gt 0 ]; do
    case "$1" in
        --version) ROCM_VERSION="${2:-}"; shift 2 ;;
        --family)  PKG_FAMILY="${2:-}";  shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
    esac
done

ROCM_VERSION="${ROCM_VERSION:-7.2.4}"

if [ "$(id -u)" != "0" ]; then
    fail "This script must be run as root (sudo bash upgrade_rocm.sh ...)."
fi

# Auto-detect package family
if [ -z "$PKG_FAMILY" ]; then
    if command -v apt-get &>/dev/null; then
        PKG_FAMILY="apt"
    elif command -v dnf &>/dev/null; then
        PKG_FAMILY="dnf"
    else
        fail "No supported package manager found (need apt or dnf)."
    fi
fi
step "Using package family: $PKG_FAMILY"

case "$PKG_FAMILY" in
    apt)
        step "Refreshing apt metadata"
        apt-get update -y >/dev/null

        # ROCm 7.2 apt package names (verified against repo.radeon.com/rocm/apt/7.2)
        # NOTE: ROCm apt repo (https://repo.radeon.com/rocm/apt/7.2) should be
        # configured in /etc/apt/sources.list.d/rocm.list before this runs.
        ROCM_PKGS=(
            rocm-hip-runtime
            hip-runtime-amd
            rocm-smi-lib
            rocminfo
            comgr
            comgr-dev
            hipsparse
            hipsparse-dev
            rocsparse
            rocsparse-dev
            rocblas
            rocblas-dev
            hipblas
            hipblas-dev
            hipblaslt
            hipblaslt-dev
            rocfft
            rocfft-dev
            hipsolver
            hipsolver-dev
            miopen-hip
            miopen-hip-dev
        )

        step "Installing ROCm ${ROCM_VERSION} packages (${#ROCM_PKGS[@]} packages)"
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "${ROCM_PKGS[@]}"; then
            fail "Required ROCm package install failed"
        fi

        # Ensure /opt/rocm/lib is in the dynamic linker search path
        if [ -d /opt/rocm/lib ] && [ ! -f /etc/ld.so.conf.d/rocm.conf ]; then
            echo "/opt/rocm/lib" > /etc/ld.so.conf.d/rocm.conf
            step "Added /etc/ld.so.conf.d/rocm.conf → /opt/rocm/lib"
        fi
        ldconfig
        ;;

    dnf)
        # Original Fedora logic preserved for upstream compatibility
        ROCM_YUM_REPO_URL="https://repo.radeon.com/rocm/rhel9/${ROCM_VERSION}/main"
        REPO_FILE="/etc/yum.repos.d/rocm.repo"
        REPO_FILE_DIR="/etc/yum.repos.d"
        REPO_FILE_BASENAME="$(basename "$REPO_FILE")"

        step "Refreshing dnf metadata"
        dnf makecache -y >/dev/null || fail "Unable to refresh dnf metadata"

        step "Ensuring ROCm release repo"
        mkdir -p "$REPO_FILE_DIR"
        if [ ! -f "$REPO_FILE" ]; then
            cat > "$REPO_FILE" <<EOF
[ROCm]
name=ROCm
baseurl=${ROCM_YUM_REPO_URL}
enabled=1
gpgcheck=1
gpgkey=https://repo.radeon.com/rocm/rocm.gpg.key
EOF
        fi

        step "Removing repo files that do not match the requested ROCm version"
        while IFS= read -r repo_file; do
            [ -n "$repo_file" ] || continue
            if [ "$(basename "$repo_file")" = "$REPO_FILE_BASENAME" ]; then continue; fi
            if grep -Eq 'rocm|amdgpu' "$repo_file" 2>/dev/null; then
                rm -f "$repo_file"
            fi
        done < <(find "$REPO_FILE_DIR" -maxdepth 1 -type f 2>/dev/null | sort)

        step "Removing old ROCm/runtime Fedora packages"
        readarray -t conflict_packages < <(rpm -qa 'rocm-runtime*' 'hip-*' 'hip*-runtime*' 2>/dev/null | sort || true)
        if [ "${#conflict_packages[@]}" -gt 0 ]; then
            removed=()
            for pkg in "${conflict_packages[@]}"; do
                repo="$(dnf repoquery --installed --queryformat '%{repoid}' "$pkg" 2>/dev/null | grep -Fx "fedora" || true)"
                if [ -n "$repo" ]; then
                    removed+=("$pkg")
                fi
            done
            if [ "${#removed[@]}" -gt 0 ]; then
                dnf remove -y "${removed[@]}"
            fi
        fi

        step "Installing AMD ROCm ${ROCM_VERSION} packages"
        if ! dnf install -y rocm-hip-libs rocm-smi rocm-comgr rocm-dev; then
            fail "Required ROCm package install failed"
        fi
        ;;

    *)
        fail "Unknown package family: $PKG_FAMILY (expected: apt or dnf)"
        ;;
esac

step "Verifying ROCm install"
if command -v rocminfo &>/dev/null; then
    rocminfo 2>&1 | grep -E "Agent Name|Marketing Name" | head -4 || true
fi
echo ""
echo "ROCm ${ROCM_VERSION} (${PKG_FAMILY}) install complete."
