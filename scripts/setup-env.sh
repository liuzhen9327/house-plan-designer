#!/usr/bin/env bash
# Idempotent dependency install for house-plan-designer.
# Safe to run more than once from a cloud agent, a local shell, or CI.
# Cloud Agent `install` should stay in sync with this script.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export DEBIAN_FRONTEND=noninteractive

sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  python3 \
  python3-pip \
  python3-venv \
  python-is-python3 \
  ca-certificates \
  curl \
  xz-utils \
  libgl1 \
  libglib2.0-0t64

# Node.js 18+ on the default PATH. Skip when a new enough node is already present.
need_node=0
if ! command -v node >/dev/null 2>&1; then
  need_node=1
elif ! node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 18 ? 0 : 1)'; then
  need_node=1
fi
if [ "$need_node" -eq 1 ]; then
  NODE_VERSION=22.23.4
  tmp="$(mktemp)"
  curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" -o "$tmp"
  sudo tar -xJf "$tmp" -C /usr/local --strip-components=1
  rm -f "$tmp"
fi
if ! command -v npm >/dev/null 2>&1; then
  echo "npm is not on PATH after installing Node.js" >&2
  exit 1
fi

# Python packages used by analyze.py, CAD import, and export checks.
# Ubuntu marks the system interpreter as externally managed; install into the user site.
python3 -m pip install --user --upgrade --break-system-packages \
  numpy \
  pillow \
  opencv-python \
  pymupdf \
  ezdxf \
  pypdf

# puppeteer-core only. package-lock.json pins registry.npmjs.org; do not rewrite it.
npm install --prefix "$ROOT/scripts"

# Chromium for scripts/browser.mjs. Ubuntu's chromium-browser package is a snap
# stub, which does not run in this container, so install Playwright's Chromium
# and point CHROME_PATH at that executable.
if ! command -v npx >/dev/null 2>&1; then
  echo "npx is not on PATH" >&2
  exit 1
fi
export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-$HOME/.cache/ms-playwright}"
# Run from /tmp so npx does not treat this repository (puppeteer-core only) as a Playwright project.
# install-deps runs apt and needs root. Install the browser itself as the user.
(
  cd /tmp
  if [ "$(id -u)" -eq 0 ]; then
    npx --yes playwright@1.55.1 install-deps chromium
  else
    sudo env "PATH=$PATH" npx --yes playwright@1.55.1 install-deps chromium
  fi
  npx --yes playwright@1.55.1 install chromium
)

chrome_bin="$(find "$PLAYWRIGHT_BROWSERS_PATH" -type f -path '*/chrome-linux*/chrome' | sort | tail -n 1)"
if [ -z "$chrome_bin" ] || [ ! -f "$chrome_bin" ]; then
  echo "Chromium executable not found under $PLAYWRIGHT_BROWSERS_PATH" >&2
  exit 1
fi
sudo ln -sfn "$chrome_bin" /usr/bin/chromium
sudo tee /etc/profile.d/chrome-path.sh >/dev/null <<'EOF'
export CHROME_PATH=/usr/bin/chromium
EOF
sudo chmod 644 /etc/profile.d/chrome-path.sh
if [ -f /etc/environment ] && grep -q '^CHROME_PATH=' /etc/environment; then
  sudo sed -i 's|^CHROME_PATH=.*|CHROME_PATH=/usr/bin/chromium|' /etc/environment
else
  echo 'CHROME_PATH=/usr/bin/chromium' | sudo tee -a /etc/environment >/dev/null
fi
# This image sources ~/.bashrc for login shells. Keep CHROME_PATH there too.
bashrc="${HOME}/.bashrc"
touch "$bashrc"
if grep -q '^export CHROME_PATH=' "$bashrc"; then
  sed -i 's|^export CHROME_PATH=.*|export CHROME_PATH=/usr/bin/chromium|' "$bashrc"
else
  printf '\nexport CHROME_PATH=/usr/bin/chromium\n' >> "$bashrc"
fi

export CHROME_PATH=/usr/bin/chromium
echo "CHROME_PATH=${CHROME_PATH}"
"$CHROME_PATH" --version
node --version
python3 --version
