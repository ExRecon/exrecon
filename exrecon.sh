#!/bin/bash
# === ExRecon v2.2.0 ===
# TOR + Nmap automation for recon
# Refactored: shared lib, data-driven scans, ~180 lines

set -euo pipefail

# Source shared library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

VERSION="2.2.0"

# === Long option handling ===
if [[ "${1:-}" == "--version" ]]; then
  echo "ExRecon v$VERSION"
  exit 0
fi

if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
  echo "Usage: $0 [-t target] [-s scan_types] [--fix-tor] [--interactive]"
  echo "  -t, --target       Target domain or IP"
  echo "  -s, --scans        Comma-separated scan types (1-8)"
  echo "      --fix-tor      Fix TOR config and test routing, then exit"
  echo "      --interactive  Force interactive mode (default if no -t)"
  echo "      --version      Show version"
  exit 0
fi

if [[ "${1:-}" == "--fix-tor" ]]; then
  echo -e "${CYAN}[+]${NC} Fixing TOR configuration..."
  configure_tor
  sudo systemctl restart tor 2>/dev/null || sudo systemctl restart tor@default 2>/dev/null
  sleep 3
  if check_tor; then
    tor_ip=$(proxychains4 curl -s https://api.ipify.org)
    echo -e "${GREEN}[+]${NC} TOR working. Exit IP: $tor_ip"
  else
    echo -e "${RED}[!]${NC} TOR not routing after fix."
    exit 1
  fi
  exit 0
fi

# === Trap for clean interrupt ===
trap 'echo -e "\n${RED}[!]${NC} Interrupted. Partial results may exist in: $OUTPUT_DIR"; exit 1' INT TERM

# === Root check ===
if [[ ${EUID:-0} -ne 0 ]]; then
  echo -e "${YELLOW}[!]${NC} Warning: Not running as root. SYN scans will not work correctly."
fi

# === Dependency Check ===
echo -e "${GREEN}[+]${NC} Checking for required dependencies..."
missing_packages=()
for pkg in "${PACKAGES[@]}"; do
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
    echo -e "${RED}[!]${NC} Package manager apt not found. Install missing packages manually: ${missing_packages[*]}"
    exit 1
  fi
fi

# === Proxychains config check ===
if ! grep -q "socks5.*127.0.0.1.*9050" "$PROXYCHAINS_CONF" 2>/dev/null; then
  echo -e "${YELLOW}[!]${NC} proxychains4 may not be configured for TOR. Check: $PROXYCHAINS_CONF"
fi

# === Header ===
echo -e "${CYAN}=== ExRecon v$VERSION : Ultimate TOR Nmap Automation ===${NC}"

# === CLI Arguments ===
target=""
scan_types=""
interactive=false

while [[ $# -gt 0 ]]; do
  case $1 in
    -t|--target) target="$2"; shift 2 ;;
    -s|--scans) scan_types="$2"; shift 2 ;;
    --interactive) interactive=true; shift ;;
    *) echo -e "${RED}[!]${NC} Unknown option: $1"; exit 1 ;;
  esac
done

# === Interactive Prompts (fallback) ===
if [[ -z "$target" ]] || [[ "$interactive" == "true" ]]; then
  read -rp "Target Domain/IP: " target
fi

if [[ ! "$target" =~ ^[a-zA-Z0-9._:-]+$ ]]; then
  echo -e "${RED}[!]${NC} Invalid target format. Aborting."
  exit 1
fi

if [[ -z "$scan_types" ]]; then
  echo "Select scan types (comma-separated, e.g., 1,3,5):"
  for i in {1..8}; do
    echo "  $i) ${SCAN_NAMES[$i]}"
  done
  read -rp "Enter selection: " scan_types
fi

IFS=',' read -ra selected_scans <<< "$scan_types"

# === Setup ===
timestamp=$(date +%s)
output_file="$OUTPUT_DIR/scan_$timestamp"
ua_string="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

# === Log Rotation (keep last 20 scans) ===
find "$OUTPUT_DIR" -name 'scan_summary_*.txt' -mtime +20 -delete 2>/dev/null
echo -e "${YELLOW}[*]${NC} Old logs pruned. Keeping last 20 scans."

# === TOR Config ===
configure_tor

# === Start TOR ===
if ! pgrep -x tor >/dev/null 2>&1; then
  echo -e "${YELLOW}[*]${NC} Starting TOR..."
  sudo systemctl start tor 2>/dev/null || sudo systemctl start tor@default 2>/dev/null
  echo -e "${YELLOW}[*]${NC} Waiting for TOR to be ready..."
  for i in {1..30}; do
    nc -z 127.0.0.1 9051 2>/dev/null && break
    sleep 1
  done
fi

rotate_tor_circuit

# === Verify TOR Routing ===
for attempt in {1..3}; do
  if check_tor; then break
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
  echo -e "${YELLOW}[!]${NC} Nmap -D not supported. Proceeding without decoys."
fi

# === Scan Loop ===
for scan_type in "${selected_scans[@]}"; do
  scan_type="${scan_type// /}"
  [[ -z "${SCAN_FLAGS[$scan_type]:-}" ]] && { echo -e "${RED}[!]${NC} Invalid selection: $scan_type"; continue; }

  # Warning for risky scans
  if [[ -n "${SCAN_WARNINGS[$scan_type]:-}" ]]; then
    echo -e "${RED}[!]${NC} ${SCAN_WARNINGS[$scan_type]}"
    read -rp "Continue anyway? (y/n): " confirm
    [[ "$confirm" != "y" ]] && continue
  fi

  echo -e "${CYAN}[*]${NC} Running ${SCAN_NAMES[$scan_type]}..."
  rotate_tor_circuit

  # Build nmap command from data
  dns_server="${SCAN_DNS[$scan_type]}"
  timeout="${SCAN_TIMEOUT[$scan_type]}"
  extras="${SCAN_EXTRAS[$scan_type]}"

  proxychains4 nmap ${SCAN_FLAGS[$scan_type]} $extras $decoy_flag --dns-servers "$dns_server" --host-timeout "$timeout" -oN "${output_file}.${scan_type}" "$target"
done

# === Generate Human-Readable Summary ===
summary_txt="$OUTPUT_DIR/scan_summary_$timestamp.txt"
summary_pdf="$OUTPUT_DIR/scan_summary_$timestamp.pdf"

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
    echo "  [+] ${SCAN_NAMES[$scan_type]}"
  done
  echo
  echo "-- Nmap Findings --"
  grep -hE "open|PORT|Service detection performed" "$OUTPUT_DIR"/scan_"$timestamp".* 2>/dev/null || echo "  No findings captured."
  echo
  if [[ -f "${output_file}.7.nikto" ]]; then
    echo "-- Nikto Findings --"
    grep -E '\+|OSVDB|CVE' "${output_file}.7.nikto" 2>/dev/null | sed 's/^/  /' || echo "  No Nikto findings."
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

# === Generate PDF (single fallback: pandoc) ===
if command -v pandoc >/dev/null 2>&1; then
  pandoc "$summary_txt" -o "$summary_pdf"
fi

# === Delta Analysis ===
mapfile -t sorted_summaries < <(find "$OUTPUT_DIR" -name 'scan_summary_*.txt' -printf '%T@ %p\n' | sort -rn | cut -d' ' -f2-)
latest_summary=""
for f in "${sorted_summaries[@]}"; do
  if [[ "$f" != "$summary_txt" ]]; then
    latest_summary="$f"
    break
  fi
done

if [[ -n "$latest_summary" ]]; then
  echo -e "${YELLOW}[*]${NC} Analyzing delta from last scan..."
  diff "$latest_summary" "$summary_txt" > "${summary_txt}.delta" ; true
fi

# === View Results ===
read -rp "[*] View scan results now? (y/n): " view_choice
if [[ "$view_choice" == "y" ]]; then
  for f in "$OUTPUT_DIR"/scan_"$timestamp".*; do
    [[ "$f" == *.pdf || "$f" == *.delta || "$f" == *.txt ]] && continue
    [[ -f "$f" ]] && view_results "$f"
  done
  view_results "$summary_txt"
fi

if [[ -f "${summary_txt}.delta" ]]; then
  read -rp "[*] View change delta from last scan? (y/n): " delta_choice
  [[ "$delta_choice" == "y" ]] && view_results "${summary_txt}.delta"
fi

echo -e "${GREEN}[+]${NC} Scan complete. Results saved in: $OUTPUT_DIR"