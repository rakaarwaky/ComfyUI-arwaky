#!/usr/bin/env bash
# ==============================================================================
# release.sh — CI → Audit → Bump → Commit → Push → Tag → GitHub Release
#
# Usage:
#   bash scripts/release.sh [<new-version>] [options]
#
#   Without a version, auto-bumps the PATCH number from Cargo.toml.
#   Use --major or --minor to bump those instead.
#
# Pipeline:
#   1. CI checks (cargo fmt, check, clippy, test, shellcheck, config validation)
#   2. Security audit (cargo-audit)
#   3. Bump version in Cargo.toml, Cargo.lock, tauri.conf.json
#   4. Commit version bump
#   5. Push current branch to origin
#   6. Create annotated tag v<new-version>
#   7. Push tag to origin
#   8. GitHub Release (gh release create) with dist/ asset upload
#
# Options:
#   --major            Bump MAJOR version (X.0.0) — default: bump PATCH
#   --minor            Bump MINOR version (X.Y.0) — default: bump PATCH
#   --backend <ver>    Also bump BACKEND_VERSION constant in downloader.rs
#   --ci-only          Run CI + audit only, skip bump/commit/push/tag/release
#   --fast             Skip slow checks (shellcheck, cargo-audit)
#   --fix              Run cargo fmt + cargo clippy --fix instead of --check
#   --skip-ci          Skip all CI checks and audit entirely
#   --skip-audit       Skip cargo-audit only
#   --skip-shellcheck  Skip shellcheck
#   --no-gh-release    Skip GitHub Release creation
#   --dry-run          Show what would happen without making changes
#   -h, --help         Show this help
#
# Examples:
#   bash scripts/release.sh            # auto-detect + bump patch → full release
#   bash scripts/release.sh --minor    # auto-detect + bump minor
#   bash scripts/release.sh --major    # auto-detect + bump major
#   bash scripts/release.sh --ci-only  # CI + audit only
#   bash scripts/release.sh --no-gh-release  # tag only, no GitHub Release
#   bash scripts/release.sh 0.3.0      # explicit version
#   bash scripts/release.sh 0.3.0 --fix --dry-run
# ==============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# ── Colors ────────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

pass() { echo -e " ${GREEN}✔${NC} $1"; }
info() { echo -e " ${CYAN}→${NC} $1"; }
warn() { echo -e " ${YELLOW}⚠${NC} $1"; }
fail() { echo -e " ${RED}✘${NC} $1"; }
die()  { fail "$1"; exit 1; }

# ── Config ─────────────────────────────────────────────────────────────────────
FAST=false
FIX=false
CI_ONLY=false
SKIP_CI=false
SKIP_AUDIT=false
SKIP_SHELLCHECK=false
NO_GH_RELEASE=false
DRY_RUN=false
BACKEND=""
NEW_VER=""
BUMP_MAJOR=false
BUMP_MINOR=false

# ── Parse arguments ────────────────────────────────────────────────────────────
usage() {
  sed -n '3,42p' "$0" | sed 's/^#//; s/^ //'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage ;;
    --backend) BACKEND="$2"; shift 2 ;;
    --ci-only) CI_ONLY=true; shift ;;
    --major)   BUMP_MAJOR=true; shift ;;
    --minor)   BUMP_MINOR=true; shift ;;
    --fast) FAST=true; shift ;;
    --fix) FIX=true; shift ;;
    --skip-ci) SKIP_CI=true; shift ;;
    --skip-audit) SKIP_AUDIT=true; shift ;;
    --skip-shellcheck) SKIP_SHELLCHECK=true; shift ;;
    --no-gh-release) NO_GH_RELEASE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    [0-9]*.[0-9]*.[0-9]*)
      if [[ -z "$NEW_VER" ]]; then
        NEW_VER="$1"; shift
      else
        die "Multiple versions specified: $NEW_VER and $1"
      fi
      ;;
    -*)
      die "Unknown option: $1 (use -h for help)"
      ;;
    *)
      die "Unknown argument: $1 (use -h for help)"
      ;;
  esac
done

if [[ -z "${NEW_VER:-}" ]]; then
  if $CI_ONLY; then
    NEW_VER="0.0.0"  # placeholder, not used
  else
    # ── Auto-detect current version and bump ──────────────────────────────────
    if [[ ! -f crates/launcher/Cargo.toml ]]; then
      die "crates/launcher/Cargo.toml not found. Cannot auto-detect version."
    fi
    CURRENT_VER="$(grep -m1 '^version' crates/launcher/Cargo.toml | sed 's/.*"\(.*\)".*/\1/')"
    if [[ ! "$CURRENT_VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
      die "Cannot parse current version: $CURRENT_VER"
    fi

    IFS='.' read -ra PARTS <<< "$CURRENT_VER"
    MAJOR="${PARTS[0]}"
    MINOR="${PARTS[1]}"
    PATCH="${PARTS[2]%%-*}"  # strip pre-release suffix if any

    if $BUMP_MAJOR; then
      NEW_VER="$((MAJOR + 1)).0.0"
    elif $BUMP_MINOR; then
      NEW_VER="$MAJOR.$((MINOR + 1)).0"
    else
      NEW_VER="$MAJOR.$MINOR.$((PATCH + 1))"
    fi
    info "Auto-detected: $CURRENT_VER → $NEW_VER"
  fi
fi

if [[ ! "$NEW_VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]]; then
  if ! $CI_ONLY; then
    die "Invalid version format: $NEW_VER (expected: X.Y.Z or X.Y.Z-pre)"
  fi
fi

if [[ ! -f crates/launcher/Cargo.toml ]]; then
  die "crates/launcher/Cargo.toml not found. Run from project root."
fi

# ── Dry-run guard ──────────────────────────────────────────────────────────────
run() {
  if $DRY_RUN; then
    echo "  [DRY-RUN] $*"
  else
    # shellcheck disable=SC2294
    eval "$@"
  fi
}

# ── CI step helper ─────────────────────────────────────────────────────────────
CI_EXIT=0
ci_step() {
  local name="$1"
  shift
  echo ""
  echo "  === $name ==="
  # shellcheck disable=SC2294
  if eval "$@"; then
    pass "$name"
  else
    fail "$name"
    CI_EXIT=1
  fi
}

# ── 1. CI Checks ───────────────────────────────────────────────────────────────
if $SKIP_CI; then
  echo ""
  warn "━━━ CI checks skipped (--skip-ci) ━━━"
else
  echo ""
  echo -e "${BOLD}━━━ [1/8] CI Checks ━━━${NC}"

  # 1a. cargo fmt
  if $FIX; then
    ci_step "cargo fmt launcher (fix)" \
      "cargo fmt --manifest-path crates/launcher/Cargo.toml"
    ci_step "cargo fmt downloader (fix)" \
      "cargo fmt --manifest-path crates/downloader/Cargo.toml"
  else
    ci_step "cargo fmt launcher (check)" \
      "cargo fmt --manifest-path crates/launcher/Cargo.toml --check"
    ci_step "cargo fmt downloader (check)" \
      "cargo fmt --manifest-path crates/downloader/Cargo.toml --check"
  fi

  # 1b. cargo check
  ci_step "cargo check launcher" \
    "cargo check --manifest-path crates/launcher/Cargo.toml"
  ci_step "cargo check downloader" \
    "cargo check --manifest-path crates/downloader/Cargo.toml"

  # 1c. cargo clippy
  if $FIX; then
    ci_step "cargo clippy launcher (fix)" \
      "cargo clippy --manifest-path crates/launcher/Cargo.toml --fix --allow-dirty -- -D warnings"
    ci_step "cargo clippy downloader (fix)" \
      "cargo clippy --manifest-path crates/downloader/Cargo.toml --fix --allow-dirty -- -D warnings"
  else
    ci_step "cargo clippy launcher" \
      "cargo clippy --manifest-path crates/launcher/Cargo.toml -- -D warnings"
    ci_step "cargo clippy downloader" \
      "cargo clippy --manifest-path crates/downloader/Cargo.toml -- -D warnings"
  fi

  # 1d. cargo test
  ci_step "cargo test launcher" \
    "cargo test --manifest-path crates/launcher/Cargo.toml"
  ci_step "cargo test downloader" \
    "cargo test --manifest-path crates/downloader/Cargo.toml"

  # 1e. shellcheck
  if $FAST || $SKIP_SHELLCHECK; then
    echo ""
    warn "  === shellcheck (skipped) ==="
  elif command -v shellcheck &>/dev/null; then
    script_files="$(find scripts/ -name '*.sh' -type f 2>/dev/null | tr '\n' ' ' || true)"
    if [ -n "$script_files" ]; then
      ci_step "shellcheck" "shellcheck $script_files"
    else
      echo ""
      pass "shellcheck (no scripts to check)"
    fi
  else
    echo ""
    pass "shellcheck (not installed, run: sudo apt install -y shellcheck   # Debian/Ubuntu"\
          "   # or:   sudo dnf install -y shellcheck   # Fedora")
  fi

  # 1f. tauri config validation
  if command -v jq &>/dev/null; then
    ci_step "tauri config validation" "jq empty crates/launcher/tauri.conf.json"
  elif command -v python3 &>/dev/null; then
    ci_step "tauri config validation" \
      "python3 -c 'import json; json.load(open(\"crates/launcher/tauri.conf.json\")); print(\"valid\")'"
  else
    echo ""
    pass "tauri config validation (no jq or python3)"
  fi

  # CI gate
  if [ $CI_EXIT -ne 0 ]; then
    die "CI checks failed. Fix issues and retry."
  fi
  pass "All CI checks passed"
fi

# ── 2. Security Audit ──────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━ [2/8] Security Audit ━━━${NC}"
if $SKIP_CI || $FAST || $SKIP_AUDIT; then
  warn "cargo-audit skipped"
elif cargo audit --version &>/dev/null 2>&1; then
  ci_step "cargo-audit" "(cd '$ROOT_DIR/crates' && cargo audit 2>&1) | tail -20"
  if [ $CI_EXIT -ne 0 ]; then
    warn "cargo-audit found vulnerabilities (continuing anyway — review above)"
  else
    pass "cargo-audit clean"
  fi
else
  warn "cargo-audit not installed (run: cargo install cargo-audit --locked)"
fi

# ── Early exit for --ci-only ───────────────────────────────────────────────────
if $CI_ONLY; then
  echo ""
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${GREEN}✅ CI checks complete.${NC}"
  echo ""
  echo "  Commit:  $(git rev-parse --short HEAD 2>/dev/null || echo '?')"
  echo ""
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  exit 0
fi

# ── 3. Bump Version ────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━ [3/8] Bump Version → $NEW_VER ━━━${NC}"

# 3a. launcher Cargo.toml
if grep -q '^version =' crates/launcher/Cargo.toml; then
  run "sed -i 's/^version = \"[^\"]*\"/version = \"$NEW_VER\"/' crates/launcher/Cargo.toml"
  pass "crates/launcher/Cargo.toml → $NEW_VER"
else
  die "Could not find version field in crates/launcher/Cargo.toml"
fi

# 3b. launcher Cargo.lock (if it exists)
if [ -f crates/launcher/Cargo.lock ]; then
  lock_line="$(grep -n '^name = "app"$' crates/launcher/Cargo.lock 2>/dev/null || true)"
  if [ -n "$lock_line" ]; then
    run "sed -i '/^name = \"app\"$/,/^version = \"[^\"]*\"$/s/^version = \"[^\"]*\"/version = \"$NEW_VER\"/' crates/launcher/Cargo.lock"
    pass "crates/launcher/Cargo.lock → $NEW_VER"
  else
    pass "crates/launcher/Cargo.lock (no 'app' entry to bump)"
  fi
else
  pass "crates/launcher/Cargo.lock (not present)"
fi

# 3c. tauri.conf.json
if [ -f crates/launcher/tauri.conf.json ]; then
  if command -v jq &>/dev/null; then
    run "jq --arg v \"$NEW_VER\" '.version = \$v' crates/launcher/tauri.conf.json > /tmp/tauri-conf-tmp.json && mv /tmp/tauri-conf-tmp.json crates/launcher/tauri.conf.json"
  else
    run "sed -i 's/\"version\": \"[^\"]*\"/\"version\": \"$NEW_VER\"/' crates/launcher/tauri.conf.json"
  fi
  pass "crates/launcher/tauri.conf.json → $NEW_VER"
fi

# 3d. BACKEND_VERSION (optional)
if [[ -n "$BACKEND" ]]; then
  if grep -q 'BACKEND_VERSION' crates/launcher/src/downloader.rs 2>/dev/null; then
    run "sed -i 's/^const BACKEND_VERSION: \&str = \".*\";/const BACKEND_VERSION: \&str = \"$BACKEND\";/' crates/launcher/src/downloader.rs"
    pass "BACKEND_VERSION → $BACKEND"
  elif grep -q 'BACKEND_VERSION' crates/downloader/downloader-engine/src/engine.rs 2>/dev/null; then
    run "sed -i 's/^const BACKEND_VERSION: \&str = \".*\";/const BACKEND_VERSION: \&str = \"$BACKEND\";/' crates/downloader/downloader-engine/src/engine.rs"
    pass "BACKEND_VERSION → $BACKEND (downloader-engine)"
  else
    warn "BACKEND_VERSION constant not found in project"
  fi
fi

# ── 4. Verify version updated correctly ────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━ Verify Version ━━━${NC}"
actual_ver="$(grep -m1 '^version' crates/launcher/Cargo.toml | sed 's/.*"\(.*\)".*/\1/')"
if $DRY_RUN; then
  pass "Version verified (dry-run, would be: $NEW_VER, current: $actual_ver)"
elif [ "$actual_ver" = "$NEW_VER" ]; then
  pass "Version verified: $actual_ver"
else
  die "Version mismatch: expected $NEW_VER, got $actual_ver"
fi

# ── 5. Commit ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━ [4/8] Commit Version Bump ━━━${NC}"

files_to_add=(
  "crates/launcher/Cargo.toml"
  "crates/launcher/tauri.conf.json"
)
[ -f crates/launcher/Cargo.lock ] && files_to_add+=("crates/launcher/Cargo.lock")
[[ -n "$BACKEND" ]] && files_to_add+=("crates/launcher/src/downloader.rs")

run "git add ${files_to_add[*]}"
run "git commit -m 'chore: bump version to $NEW_VER${BACKEND:+ (backend: $BACKEND)}'"
pass "Committed: chore: bump version to $NEW_VER"

# ── 6. Push ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━ [5/8] Push to Origin ━━━${NC}"
branch="$(git branch --show-current)"
run "git push origin '$branch'"
pass "Pushed $branch → origin/$branch"

# ── 7. Tag Release ─────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━ [6/8] Create Tag v$NEW_VER ━━━${NC}"
run "git tag -a 'v$NEW_VER' -m 'Release v$NEW_VER${BACKEND:+ (backend: $BACKEND)}'"
pass "Tag v$NEW_VER created"

# ── 8. Push Tag ────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━ [7/8] Push Tag v$NEW_VER ━━━${NC}"
run "git push origin 'v$NEW_VER'"
pass "Tag v$NEW_VER pushed"

# ── 8. GitHub Release ─────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━ [8/8] GitHub Release v$NEW_VER ━━━${NC}"
if $NO_GH_RELEASE; then
  warn "GitHub Release skipped (--no-gh-release)"
elif ! command -v gh &>/dev/null; then
  warn "gh CLI not installed — skipping GitHub Release creation"
else
  # Generate release notes from commits since last tag
  prev_tag="$(git tag --sort=-creatordate | head -2 | tail -1 || true)"
  if [ -n "$prev_tag" ]; then
    release_notes="$(git log --oneline --no-decorate "${prev_tag}..v${NEW_VER}" 2>/dev/null || true)"
  else
    release_notes="$(git log --oneline --no-decorate -20 2>/dev/null || true)"
  fi
  release_notes="## What's Changed

${release_notes:-Initial release v$NEW_VER}"

  # Build asset list from dist/
  assets=()
  if [ -d dist ] && [ "$(ls -A dist 2>/dev/null)" ]; then
    for f in dist/*; do
      [ -f "$f" ] && assets+=("$f")
    done
  fi

  if [ ${#assets[@]} -gt 0 ]; then
    info "Uploading ${#assets[@]} assets from dist/..."
    asset_args=""
    for a in "${assets[@]}"; do
      asset_args="$asset_args --attach '$a'"
    done
    # shellcheck disable=SC2294
    run "gh release create 'v$NEW_VER' --title 'v$NEW_VER' --notes \"$release_notes\" $asset_args"
  else
    # shellcheck disable=SC2294
    run "gh release create 'v$NEW_VER' --title 'v$NEW_VER' --notes \"$release_notes\""
  fi
  pass "GitHub Release v$NEW_VER created"
fi

# ── Done ───────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✅ Release $NEW_VER complete!${NC}"
echo ""
echo "  Tag:     v$NEW_VER"
echo "  Branch:  $branch"
echo "  Commit:  $(git rev-parse --short HEAD)"
[[ -n "$BACKEND" ]] && echo "  Backend: $BACKEND"
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
