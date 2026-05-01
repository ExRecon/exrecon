#!/bin/bash
set -euo pipefail

# === ExRecon v2.1.0 ===
VERSION="2.1.0"

# === Colors ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# === Long option handling (--help / --version) ===
if [[ "${1:-}" == "--version" ]]; then
  echo "ExRecon v$VERSION"
  exit 0
fi

if [[ "${1:-}" == "--help" ]]; then
  echo "Usage: $0 [-t target] [-s scan_types]"
  echo "  -t  Target domain or IP"
  echo "  -s  Comma-separated scan types (1-8)"
  echo "  -h  Show this help"
  echo "  --version  Show version"
  exit 0
fi

# === Output directory defined early so trap can reference it ===
output_dir="$HOME/tor_scan_logs"
mkdir -p "$output_dir"

# === Trap for clean interrupt ===
trap 'echo -e "\n${RED}[!]${NC} Interrupted. Partial results may exist in: $output_dir"; exit 1' INT TERM

# === Root check ===
if [[ ${EUID:-0} -ne 0 ]]; then
  echo -e "${YELLOW}[!]${NC} Warning: Not running as root. SYN scans will not work correctly."
fi

# === Dependency Check and Install ===
echo -e "${GREEN}[+]${NC} Checking for required dependencies..."

packages=(
  nmap tor proxychains4 curl gpg nc tmux coreutils openssl
  enscript ghostscript pandoc nikto
)

missing_packages=()
for pkg in "${packages[@]}"; do
  if ! command -v "$pkg" >/dev/null 2>&1; then
    missing_packages+=("$pkg")
  fi
done

if [[ ${#missing_packages[@]} -ne 0 ]]; then
  echo -e "${YELLOW}[*]${NC} Missing packages: ${missing_packages[*]}"
  if command -v apt >/dev/null 2>&1; then
    echo -e "${YELLOW}[*]${NC} Installing missing dependencies..."
    sudo apt update && sudo apt install -y "${missing_packages[@]}"
  else
    echo -e "${RED}[!]${NC} Package manager apt not found. Please install missing packages manually."
    exit 1
  fi
fi

# === TOR Config ===
TORRC="/etc/tor/torrc"
if ! grep -q "^ControlPort 9051" "$TORRC" 2>/dev/null; then
  echo "ControlPort 9051" | sudo tee -a "$TORRC" >/dev/null
fi
if ! grep -q "^CookieAuthentication 0" "$TORRC" 2>/dev/null; then
  echo "CookieAuthentication 0" | sudo tee -a "$TORRC" >/dev/null
fi

# === proxychains4 Config Check ===
PROXYCHAINS_CONF="/etc/proxychains4.conf"
if ! grep -q "socks5.*127.0.0.1.*9050" "$PROXYCHAINS_CONF" 2>/dev/null; then
  echo -e "${YELLOW}[!]${NC} proxychains4 may not be configured for TOR. Check: $PROXYCHAINS_CONF"
fi

# === Header ===
echo -e "${CYAN}=== ExRecon v$VERSION : Ultimate TOR Nmap Automation ===${NC}"

# === CLI Arguments ===
target=""
scan_types=""

while getopts ":t:s:h" opt; do
  case $opt in
    t) target="$OPTARG" ;;
    s) scan_types="$OPTARG" ;;
    h) echo "Usage: $0 [-t target] [-s scan_types]"; exit 0 ;;
    :) echo -e "${RED}[!]${NC} Option -$OPTARG requires an argument."; exit 1 ;;
    ?) echo -e "${RED}[!]${NC} Unknown option: -$OPTARG"; exit 1 ;;
  esac
done

# === Interactive Prompts (fallback if no CLI args) ===
if [[ -z "$target" ]]; then
  read -rp "Target Domain/IP: " target
fi

if [[ ! "$target" =~ ^[a-zA-Z0-9._:-]+$ ]]; then
  echo -e "${RED}[!]${NC} Invalid target format. Aborting."
  exit 1
fi

if [[ -z "$scan_types" ]]; then
  echo "Select scan types (comma-separated, e.g., 1,3,5):"
  echo "  1) TOR Quick Scan"
  echo "  2) TOR Service Detection"
  echo "  3) TOR UDP Scan + Vuln Detection"
  echo "  4) TOR Full TCP Port Scan"
  echo "  5) TOR Aggressive Scan"
  echo "  6) TOR Firewall Evasion Scan"
  echo "  7) TOR Web App Enumeration (Nikto)"
  echo "  8) TOR Stealth SYN Scan"
  read -rp "Enter selection: " scan_types
fi

IFS=',' read -ra selected_scans <<< "$scan_types"

# === Setup ===
timestamp=$(date +%s)
output_file="$output_dir/scan_$timestamp"

ua_string="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

# === Log Rotation (keep last 20 scans) ===
shopt -s nullglob
summary_files=("$output_dir"/scan_summary_*.txt)
shopt -u nullglob
if [[ ${#summary_files[@]} -gt 20 ]]; then
  printf '%s\n' "${summary_files[@]}" | sort | head -n $(( ${#summary_files[@]} - 20 )) | xargs rm -f
  echo -e "${YELLOW}[*]${NC} Old logs pruned. Keeping last 20 scans."
fi

# === Functions ===

generate_decoys() {
  local decoys=()
  for i in {1..5}; do
    decoys+=("$((RANDOM % 223 + 1)).$((RANDOM % 255)).$((RANDOM % 255)).$((RANDOM % 254 + 1))")
  done
  local IFS=','
  echo "${decoys[*]}"
}

check_nikto() {
  if ! command -v nikto >/dev/null 2>&1; then
    echo -e "${YELLOW}[!]${NC} Nikto not found. Web App scan will be skipped."
    return 1
  fi
  return 0
}

check_decoy_supported() {
  nmap --help 2>&1 | grep -q -- '-D'
}

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

rotate_tor_circuit() {
  echo -e "${YELLOW}[*]${NC} Rotating TOR circuit..."
  printf 'AUTHENTICATE ""\nSIGNAL NEWNYM\nQUIT\n' | nc 127.0.0.1 9051 >/dev/null 2>&1
  sleep 2
  echo -e "${GREEN}[+]${NC} TOR circuit rotated."
}

check_tor() {
  proxychains4 curl -s https://check.torproject.org/ | grep -q "Congratulations"
}

# === Start TOR ===
if ! pgrep -x tor >/dev/null 2>&1; then
  echo -e "${YELLOW}[*]${NC} Starting TOR..."
  sudo systemctl start tor
  echo -e "${YELLOW}[*]${NC} Waiting for TOR to be ready..."
  for i in {1..30}; do
    nc -z 127.0.0.1 9051 2>/dev/null && break
    sleep 1
  done
fi

rotate_tor_circuit

# === Verify TOR Routing ===
for attempt in {1..3}; do
  if check_tor; then
    break
  elif [[ $attempt -eq 3 ]]; then
    echo -e "${RED}[!]${NC} TOR not routing traffic. Aborting."
    exit 1
  else
    echo -e "${YELLOW}[!]${NC} TOR check failed. Retrying ($attempt)..."
    sleep 3
  fi
done

tor_ip=$(proxychains4 curl -s https://api.ipify.org)
echo -e "${GREEN}[+]${NC} Active TOR Exit IP: $tor_ip"

# === Decoy Setup ===

decoy_flag=""
if check_decoy_supported; then
  decoy_list=$(generate_decoys)
  decoy_flag="-D $decoy_list"
else
  echo -e "${YELLOW}[!]${NC} Nmap -D not supported on this system. Proceeding without decoys."
fi

# === Scan Loop ===
for scan_type in "${selected_scans[@]}"; do
  scan_type="${scan_type// /}"
  rotate_tor_circuit
  case "$scan_type" in
    1)
      echo -e "${CYAN}[*]${NC} Running Quick Scan..."
      proxychains4 nmap -sT -Pn -n --top-ports 100 -T2 --reason --data-length 50 \
        $decoy_flag -f --host-timeout 5m \
        --dns-servers 8.8.8.8 -oN "$output_file.quick" "$target"
      ;;
    2)
      echo -e "${CYAN}[*]${NC} Running Service Detection..."
      proxychains4 nmap -sT -Pn -sV -T2 \
        --script=banner,http-title,http-enum,ssl-cert \
        --script-args "http.useragent=$ua_string" \
        --data-length 100 $decoy_flag -f --host-timeout 5m \
        --dns-servers 8.8.8.8 -oN "$output_file.service" "$target"
      ;;
    3)
      echo -e "${RED}[!]${NC} WARNING: TOR is TCP-only. UDP scan may leak your real IP."
      read -rp "Continue anyway? (y/n): " udp_confirm
      [[ "$udp_confirm" != "y" ]] && continue
      echo -e "${CYAN}[*]${NC} Running UDP Vuln Scan..."
      proxychains4 nmap -sU -sV -Pn --script vuln \
        --data-length 120 $decoy_flag -f --host-timeout 5m \
        -T2 -oN "$output_file.udp" "$target"
      ;;
    4)
      echo -e "${CYAN}[*]${NC} Running Full Port Scan..."
      proxychains4 nmap -sT -Pn -p- -T2 --reason --data-length 40 \
        $decoy_flag -f --host-timeout 10m \
        --dns-servers 8.8.8.8 -oN "$output_file.full" "$target"
      ;;
    5)
      echo -e "${CYAN}[*]${NC} Running Aggressive Scan..."
      proxychains4 nmap -A -T3 -Pn --reason --data-length 60 \
        $decoy_flag -f --host-timeout 5m \
        --dns-servers 8.8.8.8 -oN "$output_file.aggressive" "$target"
      ;;
    6)
      echo -e "${CYAN}[*]${NC} Running Firewall Evasion Scan..."
      proxychains4 nmap -sT -Pn -T2 --ttl 65 --reason --data-length 80 \
        $decoy_flag -f --host-timeout 5m \
        --dns-servers 1.1.1.1 -oN "$output_file.evasion" "$target"
      ;;
    7)
      echo -e "${CYAN}[*]${NC} Running Web App Enumeration..."
      proxychains4 nmap -sV -p 80,443,8080 -Pn \
        --script http-title,http-enum \
        --script-args "http.useragent=$ua_string" \
        --data-length 100 $decoy_flag --host-timeout 5m \
        -oN "$output_file.webnmap" "$target"
      if check_nikto; then
        proxychains4 nikto -host "$target" -output "$output_file.nikto"
      fi
      ;;
    8)
      echo -e "${RED}[!]${NC} WARNING: SYN scans require raw sockets and may not route correctly through TOR."
      read -rp "Continue anyway? (y/n): " syn_confirm
      [[ "$syn_confirm" != "y" ]] && continue
      echo -e "${CYAN}[*]${NC} Running Stealth SYN Scan..."
      proxychains4 nmap -sS -Pn -T1 -n --top-ports 100 --reason --data-length 60 \
        $decoy_flag -f --host-timeout 5m \
        --dns-servers 8.8.8.8 -oN "$output_file.stealth" "$target"
      ;;
    *)
      echo -e "${RED}[!]${NC} Invalid selection: $scan_type"
      ;;
  esac
done

# === Generate Human-Readable Summary ===
summary_txt="$output_dir/scan_summary_$timestamp.txt"
summary_pdf="$output_dir/scan_summary_$timestamp.pdf"

{
  echo "ExRecon Scan Report - Timestamp: $timestamp"
  echo "==========================================="
  echo
  echo "Target:      $target"
  echo "TOR Exit IP: $tor_ip"
  echo "Scanned On:  $(date -u)"
  echo
  echo "-- Scan Modules Executed --"
  for scan_type in "${selected_scans[@]}"; do
    scan_type="${scan_type// /}"
    case "$scan_type" in
      1) echo "  [+] Quick Scan (Top 100 TCP Ports)" ;;
      2) echo "  [+] Service Detection (Banner, SSL, HTTP)" ;;
      3) echo "  [+] UDP Vuln Detection" ;;
      4) echo "  [+] Full TCP Port Scan" ;;
      5) echo "  [+] Aggressive Mode" ;;
      6) echo "  [+] Firewall Evasion" ;;
      7) echo "  [+] Web App Enumeration (Nikto)" ;;
      8) echo "  [+] Stealth SYN Scan" ;;
    esac
done
  echo
  echo "-- Nmap Findings --"
  grep -hE "open|PORT|Service detection performed" "$output_dir"/scan_"$timestamp".* 2>/dev/null || echo "  No findings captured."
  echo
  if [[ -f "$output_dir/scan_$timestamp.nikto" ]]; then
    echo "-- Nikto Findings --"
    grep -E '\+|OSVDB|CVE' "$output_dir/scan_$timestamp.nikto" 2>/dev/null | sed 's/^/  /' || echo "  No Nikto findings."
    echo
  fi
  echo "-- Timeline --"
  echo "  [$timestamp] TOR Circuit Established"
  echo "  [$timestamp] Scans Executed: ${scan_types//,/ }"
  echo "  [$(date -u +%H:%M:%S)] Report Generated"
  echo
  echo "-- Notes --"
  echo "  Scan completed and stored locally."
} > "$summary_txt"

# === Generate PDF ===
if command -v enscript >/dev/null 2>&1 && command -v ps2pdf >/dev/null 2>&1; then
  enscript -q "$summary_txt" -o - | ps2pdf - "$summary_pdf"
elif command -v pandoc >/dev/null 2>&1; then
  pandoc "$summary_txt" -o "$summary_pdf"
fi

# === Delta Analysis ===
shopt -s nullglob
all_summaries=("$output_dir"/scan_summary_*.txt)
shopt -u nullglob

latest_summary=""
if [[ ${#all_summaries[@]} -gt 1 ]]; then
  mapfile -t sorted_summaries < <(printf '%s\n' "${all_summaries[@]}" | sort -r)
  for f in "${sorted_summaries[@]}"; do
    if [[ "$f" != "$summary_txt" ]]; then
      latest_summary="$f"
      break
    fi
  done
fi

if [[ -n "$latest_summary" ]]; then
  echo -e "${YELLOW}[*]${NC} Analyzing delta from last scan..."
  diff "$latest_summary" "$summary_txt" > "$summary_txt.delta" || true
fi

# === View Results ===
read -rp "[*] View scan results now? (y/n): " view_choice
if [[ "$view_choice" == "y" ]]; then
  for f in "$output_dir"/scan_"$timestamp".*; do
    [[ "$f" == *.pdf || "$f" == *.delta || "$f" == *.txt ]] && continue
    [[ -f "$f" ]] && view_results "$f"
  done
  view_results "$summary_txt"
fi

if [[ -f "${summary_txt}.delta" ]]; then
  read -rp "[*] View change delta from last scan? (y/n): " delta_choice
  [[ "$delta_choice" == "y" ]] && view_results "${summary_txt}.delta"
fi

echo -e "${GREEN}[+]${NC} Scan complete. Results saved in: $output_dir"
