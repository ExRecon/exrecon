#!/bin/bash
# === ExRecon Dependencies Installer ===
# Installs all required tools for ExRecon to function.

set -euo pipefail

# Source shared library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

echo "[+] Updating package list..."
sudo apt update

# Required tools (from shared PACKAGES array)
echo "[+] Installing packages: ${PACKAGES[*]}"
sudo apt install -y "${PACKAGES[@]}"

# Ensure TOR control config (single implementation)
configure_tor

echo "[+] Restarting TOR service..."
sudo systemctl restart tor 2>/dev/null || sudo systemctl restart tor@default 2>/dev/null

echo "[✓] All dependencies installed. ExRecon is ready to go."