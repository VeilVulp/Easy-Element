<div align="center">

# 🧩 Easy Element (v2.0)

**The Ultimate 1-Click Matrix Stack Installer**

[![Bash](https://img.shields.io/badge/Script-Bash-4EAA25?style=flat-square&logo=gnu-bash&logoColor=white)]()
[![Matrix](https://img.shields.io/badge/Matrix-Synapse-black?style=flat-square&logo=matrix)]()
[![PostgreSQL](https://img.shields.io/badge/Database-PostgreSQL-336791?style=flat-square&logo=postgresql&logoColor=white)]()
[![LiveKit](https://img.shields.io/badge/WebRTC-LiveKit-ff4754?style=flat-square)]()
[![MAS](https://img.shields.io/badge/Auth-MAS-007A5A?style=flat-square)]()

</div>

---

## 🌟 Overview

**Easy Element** (formerly PD-Element) is a powerful, interactive bash script that fully automates the installation and configuration of a complete, modern Matrix ecosystem on an Ubuntu/Debian server.

Version 2.0 brings massive architectural upgrades, moving from standard SQLite to an enterprise-grade stack featuring **PostgreSQL**, **LiveKit** (Element Call), and **Matrix Authentication Service (MAS)** for full Element X compatibility.

---

## 🚀 Key Features (v2.0)

* 🐘 **PostgreSQL by Default:** High-performance database backend replacing SQLite for Synapse and MAS.
* 📹 **LiveKit Integration:** Built-in MatrixRTC support using LiveKit Server and `lk-jwt-service` for seamless voice and video calls.
* 🔐 **MAS Integration:** Matrix Authentication Service enabled out-of-the-box, required for next-gen clients like **Element X**.
* 🌍 **Automated Reverse Proxy & SSL:** Configures Nginx and Let's Encrypt certificates for all necessary domains.
* 📞 **Integrated TURN Server:** Pre-configured `coturn` for reliable VoIP and WebRTC connections.
* 🛠️ **Feature-Rich Admin Menu:** 18 specialized commands including:
  * Full-stack installation and component management.
  * Adding, listing, and deactivating users securely using PostgreSQL queries.
  * Database credentials view.
  * Automated server backup and configuration restorations.
  * Health checks, call diagnostics, and comprehensive fix wizards.

---

## 🛠 Prerequisites

A fresh and clean server is highly recommended (do not mix this with existing web servers as `nginx` and ports `80`/`443` will be claimed).

1. **Operating System:** Ubuntu 22.04 LTS or newer (Debian 12+ also supported).
2. **User Privileges:** Root access (`sudo -i`).
3. **Ports:** Ensure ports `80`, `443`, `3478`, `5349`, `7881`, `49160-49200`, and `50100-50200` are open for HTTP(S), TURN, and WebRTC traffic.
4. **Domain Setup:** You will need 5 distinct fully qualified domain names (FQDN) or subdomains pointing to your server's IP address (A records):

| Subdomain Use Case         | Example                     | A Record Destination  |
|----------------------------|-----------------------------|-----------------------|
| 🌐 Matrix Homeserver       | `chat.example.com`          | Your Server IP        |
| 🧭 Element Web Portal      | `app.example.com`           | Your Server IP        |
| 🏠 Base Domain (.well-known) | `example.com`               | Your Server IP        |
| 📹 LiveKit Server          | `livekit.example.com`       | Your Server IP        |
| 🔐 MAS Auth Domain         | `auth.example.com`          | Your Server IP        |

---

## 💻 Quick Start

1. SSH into your server as root:
   ```bash
   sudo -i
   ```
2. Clone this repository:
   ```bash
   git clone https://github.com/VeilVulp/Easy-Element.git
   cd Easy-Element
   ```
3. Make the script executable and run the manager:
   ```bash
   chmod +x install.sh
   ./install.sh
   ```

4. Follow the interactive prompts to install the stack. Select **Option 1) Install / Reinstall (Full Stack)**.

---

## 📝 Configuration Manager Menu

Upon launching `./install.sh`, you will be greeted by the Easy Element Manager.

<details>
<summary>Click to view the manager menu options</summary>

1. Install / Reinstall (Full Stack)
2. Create admin user (interactive)
3. Create normal user (interactive)
4. Create user with RANDOM password (auto)
5. Reactivate user (exists-ok)
6. List users (PostgreSQL)
7. Deactivate user (safe)
8. Set upload limits (Nginx + Synapse)
9. Toggle registration ON/OFF
10. Health Check (all services)
11. Fix Wizard (auto-fix common issues)
12. Backup server (config + PostgreSQL)
13. Restore backup
14. Call Diagnostics (TURN/LiveKit/WebRTC)
15. Update Element Web
16. Show Database & Credentials Info
17. Full uninstall / purge
18. Exit

</details>

---

## 📂 Project Structure
- `install.sh`: The core 1629-line Bash management script. It contains all installation logic, `psql` queries, systemd configurations, and interactive menus.

---

## 👤 Author Information
- **Author:** VeilVulp
- **Project Name:** Easy Element
- **GitHub Repository:** [https://github.com/VeilVulp/Easy-Element](https://github.com/VeilVulp/Easy-Element)
