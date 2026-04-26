#!/bin/bash
set -euo pipefail
if [[ $EUID -ne 0 ]]; then
  echo "[!] Warning: Not running as root. SYN scans and MAC spoofing will not work."
fi


# === Dependency Check and Install ===
echo "[+] Checking for required dependencies..."
packages=(
  nmap tor proxychains4 curl gpg netcat-openbsd tmux coreutils openssl
  enscript ghostscript pandoc nikto
)

missing=()
for pkg in "${packages[@]}"; do
  if ! command -v "$pkg" >/dev/null 2>&1 && ! dpkg -l | grep -qw "$pkg"; then
    missing+=("$pkg")
  fi

done

if [ ${#missing[@]} -ne 0 ]; then
  echo "[*] Missing packages: ${missing[*]}"
  echo "[*] Installing missing dependencies..."
  sudo apt update && sudo apt install -y "${missing[@]}"
fi

TORRC="/etc/tor/torrc"
if ! grep -q "^ControlPort 9051" "$TORRC"; then
  echo "ControlPort 9051" | sudo tee -a "$TORRC"
fi
if ! grep -q "^CookieAuthentication 0" "$TORRC"; then
  echo "CookieAuthentication 0" | sudo tee -a "$TORRC"
fi

# === Begin ExRecon ===
echo "=== ExRecon : Ultimate TOR Nmap Automation ==="
read -rp "Target Domain/IP: " target
if [[ ! "$target" =~ ^[a-zA-Z0-9._:-]+$ ]]; then
  echo "[!] Invalid target format. Aborting."
  exit 1
fi


echo "Select scan types (comma-separated, e.g., 1,3,5):"
echo "1) TOR Quick Scan"
echo "2) TOR Service Detection"
echo "3) TOR UDP Scan + Vuln Detection"
echo "4) TOR Full TCP Port Scan"
echo "5) TOR Aggressive Scan"
echo "6) TOR Firewall Evasion Scan"
echo "7) TOR Web App Enumeration (Nikto)"
echo "8) TOR Stealth SYN Scan"
read -p "Enter selection: " scan_types
IFS=',' read -ra selected_scans <<< "$scan_types"

timestamp=$(date +%s)
output_dir="$HOME/tor_scan_logs"
mkdir -p "$output_dir"

output_file="$output_dir/scan_$timestamp"
ua_string="Mozilla/5.0 (KaliGPT/NmapStealth)"

# Function: Generate decoys
generate_decoys() {
  for i in {1..5}; do echo -n "$((RANDOM%255)).$((RANDOM%255)).$((RANDOM%255)).$((RANDOM%255)),"; done | sed 's/,$//'
}
decoy_list=$(generate_decoys)

# Function: Check if Nikto is installed
check_nikto() {
  if ! command -v nikto >/dev/null; then
    echo "[!] Nikto not found. Web App scan will be skipped unless you install it."
    return 1
  fi
  return 0
}

# Function: Check if decoy is supported
check_decoy_supported() {
  if ! nmap --help 2>&1 | grep -q -- "-D"; then

    return 1
  fi
  return 0
}

# Function: Interactive viewer
view_results() {
  echo -e "\n[*] Viewing scan results..."
  if command -v batcat >/dev/null; then
    batcat "$1"
  elif command -v bat >/dev/null; then
    bat "$1"
  elif command -v less >/dev/null; then
    less "$1"
  elif command -v xdg-open >/dev/null; then
    xdg-open "$1"
  else
    cat "$1"
  fi
}

if ! pgrep -x tor >/dev/null; then
  echo "[*] Starting TOR..."
  sudo systemctl start tor
  sleep 5
fi

echo "[*] Requesting new TOR circuit..."
echo -e 'AUTHENTICATE ""\nSIGNAL NEWNYM\nQUIT' | nc 127.0.0.1 9051 >/dev/null
sleep 5

check_tor() {
  proxychains4 curl -s https://check.torproject.org/ | grep -q "Congratulations"
}
for attempt in {1..3}; do
  if check_tor; then break
  elif [ $attempt -eq 3 ]; then
    echo "[!] TOR not routing traffic. Aborting."
    exit 1
  else
    echo "[!] TOR check failed. Retrying ($attempt)..."
    sleep 3
  fi

done
tor_ip=$(proxychains4 curl -s https://api.ipify.org)
echo "[+] Active TOR Exit IP: $tor_ip"

use_decoy=""
if check_decoy_supported; then
  use_decoy="-D $decoy_list"
else
  echo "[!] Nmap does not support -D on this system. Proceeding without it."
fi

for scan_type in "${selected_scans[@]}"; do
  case $scan_type in
    1)
      echo "[*] Running Quick Scan..."
      proxychains4 nmap -sT -Pn -n --top-ports 100 -T2 --reason --data-length 50 $use_decoy -f \
        --dns-servers 8.8.8.8 -oN "$output_file.quick" "$target"
      ;;
    2)
      echo "[*] Running Service Detection..."
      proxychains4 nmap -sT -Pn -sV -T2 --script=banner,http-title,http-enum,ssl-cert \
        --script-args http.useragent="$ua_string" --data-length 100 $use_decoy -f \
        --dns-servers 8.8.8.8 -oN "$output_file.service" "$target"
      ;;
    3)
      echo "[!] WARNING: TOR is TCP-only. UDP scan may leak your real IP."
      read -rp "Continue anyway? (y/n): " udp_confirm
      [[ "$udp_confirm" != "y" ]] && continue
      echo "[*] Running UDP Vuln Scan..."

      proxychains4 nmap -sU -sV -Pn --script vuln --data-length 120 $use_decoy -f \
        -T2 -oN "$output_file.udp" "$target"
      ;;
    4)
      echo "[*] Running Full Port Scan..."
      proxychains4 nmap -sT -Pn -p- -T2 --reason --data-length 40 $use_decoy -f \
        --dns-servers 8.8.8.8 -oN "$output_file.full" "$target"
      ;;
    5)
      echo "[*] Running Aggressive Scan..."
      proxychains4 nmap -A -T3 -Pn --reason --data-length 60 $use_decoy -f \
        --dns-servers 8.8.8.8 -oN "$output_file.aggressive" "$target"
      ;;
    6)
      echo "[*] Running Firewall Evasion Scan..."
      proxychains4 nmap -sT -Pn -T2 --spoof-mac 0 --ttl 65 --reason --data-length 80 $use_decoy -f \
        --dns-servers 1.1.1.1 -oN "$output_file.evasion" "$target"
      ;;
    7)
      echo "[*] Running Web App Enumeration..."
      proxychains4 nmap -sV -p 80,443,8080 -Pn --script http-title,http-enum \
        --script-args http.useragent="$ua_string" --data-length 100 $use_decoy \
        -oN "$output_file.webnmap" "$target"
      if check_nikto; then
        proxychains4 nikto -host "$target" -output "$output_file.nikto"
      fi
      ;;
    8)
      echo "[!] WARNING: SYN scans require raw sockets and may not route through TOR correctly."
      read -rp "Continue anyway? (y/n): " syn_confirm
      [[ "$syn_confirm" != "y" ]] && continue
      echo "[*] Running Stealth SYN Scan..."
      proxychains4 nmap -sS -Pn -T1 -n --top-ports 100 --reason --data-length 60 $use_decoy -f \
        --dns-servers 8.8.8.8 -oN "$output_file.stealth" "$target"
      ;;
    *)
      echo "[!] Invalid selection: $scan_type"
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
  echo "Target: $target"
  echo "TOR Exit Node: $tor_ip"
  echo "Scanned On: $(date -u)"
  echo
  echo "--- Scan Modules Executed ---"
  for scan_type in "${selected_scans[@]}"; do
    case $scan_type in
      1) echo "[+] Quick Scan (Top 100 TCP Ports)";;
      2) echo "[+] Service Detection (Banner, SSL, HTTP)";;
      3) echo "[+] UDP Vuln Detection";;
      4) echo "[+] Full TCP Port Scan";;
      5) echo "[+] Aggressive Mode";;
      6) echo "[+] Firewall Evasion";;
      7) echo "[+] Web App Enumeration (Nikto)";;
      8) echo "[+] Stealth SYN Scan";;
    esac
  done
  echo
  echo "--- Nmap Findings ---"
  grep -E "open|PORT|Service detection performed" "$output_dir"/scan_"$timestamp".* 2>/dev/null
  echo
  if [ -f "$output_dir/scan_$timestamp.nikto" ]; then
    echo "--- Nikto Findings ---"
    grep -E "\+|OSVDB|CVE" "$output_dir/scan_$timestamp.nikto" | sed 's/^/    /'
    echo
  fi
  echo "--- Timeline ---"
  echo "[$timestamp] TOR Circuit Established"
  echo "[$timestamp] Scans Executed: ${scan_types//,/ }"
  echo "[$(date -u +%H:%M:%S)] Report Generated"
  echo
  echo "--- Notes ---"
  echo "- Scan completed and stored locally."
} > "$summary_txt"

if command -v enscript >/dev/null && command -v ps2pdf >/dev/null; then
  enscript "$summary_txt" -o - | ps2pdf - "$summary_pdf"
elif command -v pandoc >/dev/null; then
  pandoc "$summary_txt" -o "$summary_pdf"
fi

latest_summary=$(ls -t "$output_dir"/scan_summary_*.txt 2>/dev/null | grep -v "$timestamp" | head -n 1)
if [[ -f "$latest_summary" ]]; then
  echo "[*] Analyzing anomaly delta from last scan..."
  diff "$latest_summary" "$summary_txt" > "$summary_txt.delta" || true
fi

read -p "[*] View scan results now? (y/n): " view_choice
if [[ "$view_choice" == "y" ]]; then
  for f in "$output_dir"/scan_"$timestamp".*; do
    [[ "$f" == *.pdf || "$f" == *.delta || "$f" == *.txt ]] && view_results "$f"
  done
fi

echo "[+] Scan complete. Results saved in: $output_dir"
