#!/usr/bin/env bash
#
# One-shot setup of one or more Linux self-hosted GitHub Actions runners.
# Linux counterpart to setup-self-hosted-runner.ps1. Same shape: download
# runner tarball, register against the repo with caller-specified labels,
# install as a systemd service, flip USE_SELF_HOSTED=true.
#
# Designed for a small VPS (Hetzner CX22 / Contabo VPS 10 / Oracle Free
# Tier / OVH VLE). Tested on Ubuntu 24.04 LTS, 2 vCPU / 4 GB.
#
# Performance tweaks (mirror the .ps1):
#   - Shared pnpm store under $RUNNER_ROOT/pnpm-store (env PNPM_STORE_PATH)
#   - Shared Playwright browser cache under $RUNNER_ROOT/playwright-browsers
#     (env PLAYWRIGHT_BROWSERS_PATH)
#   Both env vars injected into the systemd unit so jobs see them.
#
# Workflow-side gotcha (REQUIRED for multi-runner on same host): scope
# pnpm/action-setup's install dir to runner.temp in your .github/workflows/*.yml:
#
#   - name: Setup pnpm
#     uses: pnpm/action-setup@v4
#     with:
#       dest: ${{ runner.temp }}/setup-pnpm
#
# Usage:
#   sudo REPO_OWNER=dstefl REPO_NAME=my-project RUNNER_LABELS='my-runner,linux' \
#     ./setup-self-hosted-runner.sh
#
#   # 2 parallel runners, no auto-toggle:
#   sudo REPO_OWNER=dstefl REPO_NAME=my-project RUNNER_LABELS='my-runner,linux' \
#        COUNT=2 NO_AUTO_TOGGLE=1 ./setup-self-hosted-runner.sh
#
# Env vars (override defaults):
#   REPO_OWNER           (required)
#   REPO_NAME            (required)
#   RUNNER_ROOT          Default: /opt/actions-runners/${REPO_NAME}
#   RUNNER_LABELS        Default: linux
#   RUNNER_NAME_PREFIX   Default: $(hostname)
#   COUNT                Default: 1 (use 2-4 for parallel slots on the VPS)
#   NO_AUTO_TOGGLE       Default: unset (=> script flips USE_SELF_HOSTED=true)
#
# Prerequisites the script installs automatically:
#   - curl, jq, tar, ca-certificates, git
#   - Node.js 20+ (via NodeSource)
#   - pnpm via corepack
#   - GitHub CLI (gh)
#
# Rollback:
#   gh variable delete USE_SELF_HOSTED --repo $REPO_OWNER/$REPO_NAME
#
# Deregister a slot:
#   cd $RUNNER_ROOT/<slot>   # or RUNNER_ROOT itself for single-runner installs
#   sudo ./svc.sh stop && sudo ./svc.sh uninstall
#   token=$(gh api -X POST repos/$REPO_OWNER/$REPO_NAME/actions/runners/remove-token --jq .token)
#   ./config.sh remove --token "$token"
#
set -euo pipefail

# --- Defaults / required ------------------------------------------------------
: "${REPO_OWNER:?REPO_OWNER is required}"
: "${REPO_NAME:?REPO_NAME is required}"

RUNNER_ROOT="${RUNNER_ROOT:-/opt/actions-runners/${REPO_NAME}}"
RUNNER_LABELS="${RUNNER_LABELS:-linux}"
RUNNER_NAME_PREFIX="${RUNNER_NAME_PREFIX:-$(hostname)}"
COUNT="${COUNT:-1}"
NO_AUTO_TOGGLE="${NO_AUTO_TOGGLE:-}"

if ! [[ "$COUNT" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: COUNT must be a positive integer (got '$COUNT')" >&2
  exit 1
fi

# --- Banner -------------------------------------------------------------------
echo "=== Self-hosted runner setup (linux) ==="
echo "Repository:       ${REPO_OWNER}/${REPO_NAME}"
echo "Runner root:      ${RUNNER_ROOT}"
echo "Runner prefix:    ${RUNNER_NAME_PREFIX}"
echo "Runner labels:    ${RUNNER_LABELS}"
echo "Runner count:     ${COUNT}"
if [ -n "${NO_AUTO_TOGGLE}" ]; then
  echo "Auto-toggle:      NO (manual gh variable set required)"
else
  echo "Auto-toggle:      YES (USE_SELF_HOSTED=true after success)"
fi
echo ""

# --- Step 0: root + tooling ---------------------------------------------------
echo "Step 0: checking prerequisites..."

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "ERROR: must run as root (use sudo). systemd service install + apt require root." >&2
  exit 1
fi

apt-get update -qq
apt-get install -y -qq curl jq tar ca-certificates git >/dev/null

# Node 20+ via NodeSource if not present
if ! command -v node >/dev/null 2>&1 || [ "$(node -v | sed 's/v//;s/\..*//')" -lt 20 ]; then
  echo "  installing Node 20.x (NodeSource)..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null
  apt-get install -y -qq nodejs >/dev/null
fi
echo "  [OK] node $(node -v)"

# pnpm via corepack
if ! command -v pnpm >/dev/null 2>&1; then
  echo "  installing pnpm via corepack..."
  corepack enable
  corepack prepare pnpm@latest --activate
fi
echo "  [OK] pnpm $(pnpm -v)"

# GitHub CLI
if ! command -v gh >/dev/null 2>&1; then
  echo "  installing gh CLI..."
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg
  chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list
  apt-get update -qq
  apt-get install -y -qq gh >/dev/null
fi
echo "  [OK] gh $(gh --version | head -1)"

if ! gh auth status >/dev/null 2>&1; then
  echo "ERROR: gh CLI is not authenticated. Run 'gh auth login' first." >&2
  exit 1
fi

arch=$(uname -m)
case "$arch" in
  x86_64)  runner_arch="x64" ;;
  aarch64) runner_arch="arm64" ;;
  *) echo "ERROR: unsupported architecture: $arch" >&2; exit 1 ;;
esac
echo "  [OK] arch=$arch -> runner=$runner_arch"

# --- Step 1: shared caches ----------------------------------------------------
echo ""
echo "Step 1: provisioning shared caches under ${RUNNER_ROOT}..."

mkdir -p "$RUNNER_ROOT"
pnpm_store_path="$RUNNER_ROOT/pnpm-store"
playwright_browsers_path="$RUNNER_ROOT/playwright-browsers"
mkdir -p "$pnpm_store_path" "$playwright_browsers_path"
echo "  [OK] $pnpm_store_path"
echo "  [OK] $playwright_browsers_path"

# --- Step 2: latest runner version + cached download --------------------------
echo ""
echo "Step 2: fetching latest runner version..."
runner_version=$(gh api repos/actions/runner/releases/latest --jq '.tag_name' | sed 's/^v//')
tarball="actions-runner-linux-${runner_arch}-${runner_version}.tar.gz"
download_url="https://github.com/actions/runner/releases/download/v${runner_version}/${tarball}"
echo "  [OK] runner v${runner_version}"

shared_tarball="${RUNNER_ROOT}/${tarball}"
if [ ! -f "$shared_tarball" ]; then
  echo "  downloading ${tarball} ..."
  curl -fsSL -o "$shared_tarball" "$download_url"
  echo "  [OK] downloaded"
else
  echo "  [OK] reusing cached $shared_tarball"
fi

# Dedicated service user. The runner refuses to run config.sh as root.
runner_user="ghactions"
if ! id -u "$runner_user" >/dev/null 2>&1; then
  echo "  creating user '$runner_user' ..."
  useradd --system --create-home --shell /usr/sbin/nologin "$runner_user"
fi
echo "  [OK] runner user: $runner_user"
chown -R "$runner_user:$runner_user" "$RUNNER_ROOT"

# --- Step 3: per-slot install loop --------------------------------------------
installed_slots=()
for slot in $(seq 1 "$COUNT"); do
  echo ""
  echo "=== Slot $slot/$COUNT ==="

  if [ "$COUNT" -eq 1 ]; then
    slot_dir="$RUNNER_ROOT"
    slot_name="$RUNNER_NAME_PREFIX"
  else
    slot_dir="$RUNNER_ROOT/$slot"
    slot_name="${RUNNER_NAME_PREFIX}-${slot}"
  fi
  echo "Slot dir:  $slot_dir"
  echo "Slot name: $slot_name"

  reg_token=$(gh api -X POST "repos/${REPO_OWNER}/${REPO_NAME}/actions/runners/registration-token" --jq '.token')
  if [ -z "$reg_token" ]; then
    echo "ERROR: empty registration token for slot $slot" >&2
    exit 1
  fi

  # Idempotent teardown
  if [ -d "$slot_dir" ] && [ -f "$slot_dir/.runner" ]; then
    echo "  WARN: existing config in $slot_dir -- deregistering first..."
    pushd "$slot_dir" >/dev/null
    if [ -f svc.sh ]; then
      ./svc.sh stop 2>/dev/null || true
      ./svc.sh uninstall 2>/dev/null || true
    fi
    remove_token=$(gh api -X POST "repos/${REPO_OWNER}/${REPO_NAME}/actions/runners/remove-token" --jq '.token' 2>/dev/null || true)
    if [ -n "$remove_token" ]; then
      sudo -u "$runner_user" ./config.sh remove --token "$remove_token" 2>/dev/null || true
    fi
    popd >/dev/null
  fi

  mkdir -p "$slot_dir"
  chown "$runner_user:$runner_user" "$slot_dir"

  if [ ! -f "$slot_dir/config.sh" ]; then
    echo "  extracting runner binary..."
    tar -xzf "$shared_tarball" -C "$slot_dir"
    chown -R "$runner_user:$runner_user" "$slot_dir"
  fi

  echo "  registering with GitHub..."
  pushd "$slot_dir" >/dev/null
  sudo -u "$runner_user" ./config.sh \
    --unattended \
    --url "https://github.com/${REPO_OWNER}/${REPO_NAME}" \
    --token "$reg_token" \
    --name "$slot_name" \
    --labels "$RUNNER_LABELS" \
    --work _work \
    --replace
  reg_token=""

  echo "  installing + starting systemd service..."
  ./svc.sh install "$runner_user"
  ./svc.sh start

  # Inject shared-cache env vars into the systemd unit.
  unit_file=$(ls /etc/systemd/system/actions.runner.*"$slot_name".service 2>/dev/null | head -1 || true)
  if [ -n "$unit_file" ] && [ -f "$unit_file" ]; then
    if ! grep -q "PNPM_STORE_PATH" "$unit_file"; then
      sed -i "/^User=/a Environment=\"PNPM_STORE_PATH=$pnpm_store_path\"\nEnvironment=\"PLAYWRIGHT_BROWSERS_PATH=$playwright_browsers_path\"" "$unit_file"
      systemctl daemon-reload
      systemctl restart "$(basename "$unit_file" .service)"
      echo "  [OK] cache env vars injected into $unit_file"
    fi
  else
    echo "  WARN: couldn't locate systemd unit for slot — caches won't be shared until manual fix" >&2
  fi
  popd >/dev/null

  installed_slots+=("$slot_name")
  echo "  [OK] slot $slot installed: $slot_name"
done

# --- Step 4: confirm Online with GitHub ---------------------------------------
echo ""
echo "Step 4: confirming Online status with GitHub..."
sleep 5
runners_json=$(gh api "repos/${REPO_OWNER}/${REPO_NAME}/actions/runners")
for name in "${installed_slots[@]}"; do
  status=$(echo "$runners_json" | jq -r --arg n "$name" '.runners[] | select(.name==$n) | .status' || true)
  if [ "$status" = "online" ]; then
    echo "  [OK] $name is Online"
  elif [ -n "$status" ]; then
    echo "  WARN: $name registered but status=$status"
  else
    echo "  WARN: $name not yet visible at https://github.com/${REPO_OWNER}/${REPO_NAME}/settings/actions/runners"
  fi
done

# --- Step 5: enable workflow toggle (last) ------------------------------------
echo ""
if [ -n "$NO_AUTO_TOGGLE" ]; then
  echo "Step 5: SKIPPING toggle (NO_AUTO_TOGGLE set). Workflows still go to ubuntu-latest."
  echo "  Enable manually:  gh variable set USE_SELF_HOSTED --body true --repo ${REPO_OWNER}/${REPO_NAME}"
else
  echo "Step 5: flipping USE_SELF_HOSTED=true repo variable..."
  gh variable set USE_SELF_HOSTED --body 'true' --repo "${REPO_OWNER}/${REPO_NAME}"
  echo "  [OK] vars.USE_SELF_HOSTED = true"
fi

# --- Summary ------------------------------------------------------------------
echo ""
echo "=== Setup complete! ==="
echo ""
echo "Runners installed:"
for name in "${installed_slots[@]}"; do
  echo "  - $name"
done
echo ""
echo "Shared caches:"
echo "  PNPM_STORE_PATH          = $pnpm_store_path"
echo "  PLAYWRIGHT_BROWSERS_PATH = $playwright_browsers_path"
echo ""
echo "REMINDER for multi-runner mode (COUNT >= 2): update each workflow's"
echo "Setup pnpm step to scope dest to runner.temp:"
echo "  - uses: pnpm/action-setup@v4"
echo "    with:"
echo "      dest: \${{ runner.temp }}/setup-pnpm"
echo ""
echo "Verify in GitHub UI:"
echo "  https://github.com/${REPO_OWNER}/${REPO_NAME}/settings/actions/runners"
echo ""
echo "Rollback to GitHub-hosted:"
echo "  gh variable delete USE_SELF_HOSTED --repo ${REPO_OWNER}/${REPO_NAME}"
