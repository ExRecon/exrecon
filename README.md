# 🛡️ ExRecon v2.2.0 — TOR + Nmap Recon Automation

A streamlined, dependency-light reconnaissance tool that runs **modular Nmap scans over TOR** with circuit rotation, clean summaries, and delta tracking — all in ~250 lines of bash.

---

## ✨ Features

| Capability | Description |
|------------|-------------|
| **TOR-routed scans** | All traffic via `proxychains4`; auto-rotates circuits per scan |
| **8 scan profiles** | Quick, Service, UDP, Full, Aggressive, Evasion, Web, SYN — select any combo |
| **Auto deps** | Detects & installs missing packages (`nmap`, `tor`, `proxychains4`, `nikto`, `pandoc`, …) |
| **`--fix-tor` mode** | One-shot TOR config repair + connectivity test |
| **CLI + Interactive** | `./exrecon.sh -t target -s 1,4` or run without args for prompts |
| **PDF via pandoc** | Single dependency for reports; no `enscript`/`ghostscript` needed |
| **Delta analysis** | Auto-diffs new summary vs last scan |
| **Configurable paths** | Override `TORRC`, `OUTPUT_DIR`, DNS via env or `/etc/exrecon.conf` |

---

## 📦 Dependencies

| Package | Purpose |
|---------|---------|
| `nmap` | Port/service scanning |
| `tor` | Anonymity network |
| `proxychains4` | TOR routing for nmap/curl |
| `curl` | IP checks & TOR verification |
| `gpg` | (Reserved for future sig verification) |
| `netcat-openbsd` | TOR control port (`nc 127.0.0.1 9051`) |
| `tmux` | (Reserved for background scan support) |
| `coreutils` | Standard utils (`date`, `find`, `sort`) |
| `openssl` | (Reserved for future crypto) |
| `pandoc` | Text → PDF report generation |
| `nikto` | Web app vulnerability scan (scan type 7) |

> **Removed:** `enscript`, `ghostscript` (were only for legacy PDF fallback).

---

## 🔧 Installation

```bash
chmod +x exrecon.sh exrecon-install.sh
./exrecon-install.sh
```

The installer:
- Updates apt & installs all packages above
- Patches `/etc/tor/torrc` with `ControlPort 9051` + `CookieAuthentication 0`
- Restarts TOR service

Then run ExRecon:
```bash
./exrecon.sh --help
```

---

## 🚀 Usage

### CLI (recommended)
```bash
# Quick + Full scan against a target
./exrecon.sh -t example.com -s 1,4

# Service detection + Web enum
./exrecon.sh -t 192.168.1.10 -s 2,7

# Repair TOR config and test routing, then exit
./exrecon.sh --fix-tor
```

### Interactive
```bash
./exrecon.sh
# or
./exrecon.sh --interactive
# Prompts for target, then scan selection (1-8, comma-separated)
```

### Flags
| Flag | Description |
|------|-------------|
| `-t, --target <host>` | Target domain or IP |
| `-s, --scans <list>` | Comma-separated scan types (1-8) |
| `--fix-tor` | Fix TOR config, test routing, exit |
| `--interactive` | Force prompt mode (default if no `-t`) |
| `--version` | Show version |
| `-h, --help` | Show help |

---

## 📋 Scan Types

| # | Name | Nmap Flags (summary) |
|---|------|----------------------|
| 1 | **Quick** | `-sT -Pn --top-ports 100 -T2` |
| 2 | **Service Detection** | `-sT -sV --script=banner,http-title,http-enum,ssl-cert` |
| 3 | **UDP + Vuln** | `-sU -sV --script vuln` *(⚠️ leaks real IP over TOR)* |
| 4 | **Full TCP** | `-sT -Pn -p- -T2` |
| 5 | **Aggressive** | `-A -T3` (OS, version, scripts, traceroute) |
| 6 | **Firewall Evasion** | `--ttl 65`, modified data-length |
| 7 | **Web Enum** | `-sV -p 80,443,8080 + Nikto` |
| 8 | **Stealth SYN** | `-sS -T1` *(⚠️ needs root; may not route via TOR)* |

---

## 📁 Output

```
~/tor_scan_logs/
├── scan_<ts>.1.quick       # Raw nmap output per scan
├── scan_<ts>.2.service
├── ...
├── scan_summary_<ts>.txt   # Human-readable report
├── scan_summary_<ts>.pdf   # Pandoc-generated PDF
└── scan_summary_<ts>.delta # Diff vs previous scan (if exists)
```

Old summaries auto-pruned after **20 days** (`find -mtime +20`).

---

## ⚙️ Configuration (Environment Variables)

| Variable | Default | Description |
|----------|---------|-------------|
| `TORRC` | `/etc/tor/torrc` | TOR config path |
| `PROXYCHAINS_CONF` | `/etc/proxychains4.conf` | Proxychains config |
| `OUTPUT_DIR` | `~/tor_scan_logs` | Scan output directory |
| `DNS_PRIMARY` | `8.8.8.8` | DNS for most scans |
| `DNS_SECONDARY` | `1.1.1.1` | DNS for evasion scan (6) |

Or create `/etc/exrecon.conf`:
```bash
OUTPUT_DIR="/var/log/exrecon"
DNS_PRIMARY="9.9.9.9"
```

---

## 🔐 Notes

- **Root required** for SYN scans (type 8), MAC spoofing, raw sockets
- TOR validated before every scan; circuit rotated per scan type
- All traffic forced through TOR via ProxyChains
- UDP scan (type 3) and SYN scan (type 8) warn before running

---

## ⚠️ Legal Warning

**ExRecon is for authorized testing only.** Do not scan systems you do not own or lack explicit written permission to test. Unauthorized scanning is illegal in most jurisdictions.

---

## 📜 License

MIT — see `LICENSE`.

---

## 🧠 Architecture

```
exrecon/
├── exrecon.sh           # Main entry (~256 lines)
├── exrecon-install.sh   # Installer (~23 lines)
└── lib/
    └── common.sh        # Shared: packages, paths, TOR config, scan flags, helpers
```

All duplication removed; scan profiles are data-driven associative arrays. Single source of truth for packages, TOR config, and paths.

---

## 🤝 Contributing

See `CONTRIBUTING.md`. PRs welcome for:
- New scan profiles (add to `SCAN_FLAGS` in `lib/common.sh`)
- Output formatters
- Cross-platform (non-apt) installers