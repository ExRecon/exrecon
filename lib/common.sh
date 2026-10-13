#!/bin/bash
# === ExRecon Shared Library ===
# Sourced by exrecon.sh and exrecon-install.sh

set -euo pipefail

# === Colors ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# === Configurable Paths (override via env or /etc/exrecon.conf) ===
TORRC="${TORRC:-/etc/tor/torrc}"
PROXYCHAINS_CONF="${PROXYCHAINS_CONF:-/etc/proxychains4.conf}"
OUTPUT_DIR="${OUTPUT_DIR:-$HOME/tor_scan_logs}"
DNS_PRIMARY="${DNS_PRIMARY:-8.8.8.8}"
DNS_SECONDARY="${DNS_SECONDARY:-1.1.1.1}"

# === Package List (single source of truth) ===
PACKAGES=(
  nmap tor proxychains4 curl gpg netcat-openbsd tmux
  coreutils openssl pandoc nikto
)

# === Configure TOR (single implementation) ===
configure_tor() {
  if ! grep -q "^ControlPort 9051" "$TORRC" 2>/dev/null; then
    echo "ControlPort 9051" | sudo tee -a "$TORRC" >/dev/null
  fi
  if ! grep -q "^CookieAuthentication 0" "$TORRC" 2>/dev/null; then
    echo "CookieAuthentication 0" | sudo tee -a "$TORRC" >/dev/null
  fi
}

# === Scan Type Flags (data-driven) ===
declare -A SCAN_FLAGS=(
  [1]="-sT -Pn -n --top-ports 100 -T2 --reason --data-length 50"
  [2]="-sT -Pn -sV -T2 --script=banner,http-title,http-enum,ssl-cert"
  [3]="-sU -sV -Pn --script vuln --data-length 120 -T2"
  [4]="-sT -Pn -p- -T2 --reason --data-length 40"
  [5]="-A -T3 -Pn --reason --data-length 60"
  [6]="-sT -Pn -T2 --ttl 65 --reason --data-length 80"
  [7]="-sV -p 80,443,8080 -Pn --script http-title,http-enum"
  [8]="-sS -Pn -T1 -n --top-ports 100 --reason --data-length 60"
)

declare -A SCAN_NAMES=(
  [1]="Quick Scan (Top 100 TCP Ports)"
  [2]="Service Detection (Banner, SSL, HTTP)"
  [3]="UDP Vuln Detection"
  [4]="Full TCP Port Scan"
  [5]="Aggressive Mode"
  [6]="Firewall Evasion"
  [7]="Web App Enumeration (Nikto)"
  [8]="Stealth SYN Scan"
)

declare -A SCAN_WARNINGS=(
  [3]="WARNING: TOR is TCP-only. UDP scan may leak your real IP."
  [8]="WARNING: SYN scans require raw sockets and may not route correctly through TOR."
)

declare -A SCAN_DNS=(
  [1]="$DNS_PRIMARY"
  [2]="$DNS_PRIMARY"
  [3]="$DNS_PRIMARY"
  [4]="$DNS_PRIMARY"
  [5]="$DNS_PRIMARY"
  [6]="$DNS_SECONDARY"
  [7]="$DNS_PRIMARY"
  [8]="$DNS_PRIMARY"
)

declare -A SCAN_TIMEOUT=(
  [1]="5m"
  [2]="5m"
  [3]="5m"
  [4]="10m"
  [5]="5m"
  [6]="5m"
  [7]="5m"
  [8]="5m"
)

# === Scan-specific nmap extras ===
declare -A SCAN_EXTRAS=(
  [1]="-f --host-timeout 5m --dns-servers $DNS_PRIMARY"
  [2]="--script-args \"http.useragent=\$ua_string\" --data-length 100 -f --host-timeout 5m --dns-servers $DNS_PRIMARY"
  [3]="-f --host-timeout 5m --dns-servers $DNS_PRIMARY"
  [4]="-f --host-timeout 10m --dns-servers $DNS_PRIMARY"
  [5]="-f --host-timeout 5m --dns-servers $DNS_PRIMARY"
  [6]="-f --host-timeout 5m --dns-servers $DNS_SECONDARY"
  [7]="--script-args \"http.useragent=\$ua_string\" --data-length 100 -f --host-timeout 5m --dns-servers $DNS_PRIMARY"
  [8]="-f --host-timeout 5m --dns-servers $DNS_PRIMARY"
)

# === Decoy generation ===
generate_decoys() {
  local decoys=()
  for i in {1..5}; do
    decoys+=("$((RANDOM % 223 + 1)).$((RANDOM % 255)).$((RANDOM % 255)).$((RANDOM % 254 + 1))")
  done
  local IFS=','
  echo "${decoys[*]}"
}

# === Check nmap decoy support ===
check_decoy_supported() {
  nmap --help 2>&1 | grep -q -- '-D'
}

# === View results with fallback ===
view_results() {
  echo -e "\n${YELLOW}[*]${NC} Viewing: $1"
  if command -v batcat >/dev/null 2>&1; then
    batcat "$1"
  elif command -v bat >/dev/null 2>&1; then
    bat "$1"
  elif command -v less >/dev/null 2>&1; then
    less "$1"
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$1"
  else
    cat "$1"
  fi
}

# === Rotate TOR circuit ===
rotate_tor_circuit() {
  echo -e "${YELLOW}[*]${NC} Rotating TOR circuit..."
  printf 'AUTHENTICATE ""
SIGNAL NEWNYM
QUIT
' | nc 127.0.0.1 9051 >/dev/null 2>&1
  sleep 2
  echo -e "${GREEN}[+]${NC} TOR circuit rotated."
}

# === Check TOR routing ===
check_tor() {
  proxychains4 curl -s https://check.torproject.org/ | grep -q "Congratulations"
}

# === Ensure output dir ===
mkdir -p "$OUTPUT_DIR"