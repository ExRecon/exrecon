# Contributing to ExRecon 🛡️

First off, thank you for considering contributing to **ExRecon**! Community involvement is what keeps this stealth reconnaissance framework robust, updated, and effective for security professionals worldwide.

As an open-source security tool designed for automated Nmap/Nikto scans and TOR-integrated evasion, we maintain high standards for code integrity and operational security (OPSEC).

---

### 🚀 How You Can Contribute

We are looking for contributions in the following key areas:
* **Module Development:** Adding new scanning engines or integrating third-party tools (e.g., Amass, Nuclei, Subfinder).
* **Evasion Techniques:** Improving TOR/Proxychains integration and advanced WAF bypass logic.
* **Bug Reports:** Identifying edge cases where scans fail, circuits leak, or dependencies conflict.
* **Documentation:** Improving the README, Wiki, or adding "Advanced Usage" guides for complex network environments.
* **Feature Requests:** Suggesting new ways to make reconnaissance faster, lighter, and more stealthy.

---

### 🛠️ Development Workflow

1.  **Fork & Clone:** Fork the repository and create your feature branch.
    ```bash
    git checkout -b feature/YourAmazingFeature
    ```
2.  **Code Standards:** * **Linting:** Ensure all Bash scripts are linted (we recommend using `shellcheck`).
    * **Modularity:** Maintain the modular architecture to ensure the core engine remains lightweight.
    * **Documentation:** Comment your code clearly, especially where complex `iptables` or specific `nmap` flags are utilized.
3.  **Security First:** Never hardcode credentials, personal API keys, or sensitive local paths in your contributions. 
4.  **Submit a Pull Request (PR):** Describe your changes in detail. Explain the functional benefit (e.g., "Reduces detection rate by X%" or "Automates dependency resolution for Arch Linux").

---

### 🐛 Reporting Bugs & Security Issues

* **Standard Bugs:** Please use the [GitHub Issue Tracker](https://github.com/ExRecon/exrecon/issues). Include your OS version (e.g., Kali 2024.x), dependency versions, and the specific command that triggered the error.
* **Security Vulnerabilities:** If you find a security flaw within ExRecon itself, please do not open a public issue. Instead, contact the maintainers directly to ensure a coordinated disclosure.

---

### ⚖️ Code of Conduct

We are committed to fostering an open and welcoming environment. By participating in this project, you agree to abide by professional standards, treating all contributors with respect and focusing on constructive technical feedback.

---

### 🌟 Why Join the ExRecon Team?

By contributing to ExRecon, you are building a tool designed for the **Bug Bounty** and **Pentesting** communities. Contributors are credited in the `Contributors` section and in official release notes for major versions.

**Let’s build the future of stealth reconnaissance together.**
