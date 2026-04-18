# 🐧 Zimbra Automation Scripts

Kumpulan script otomatisasi untuk instalasi, konfigurasi, dan maintenance **Zimbra Collaboration Suite** (OSE & Network Edition). Script ini dirancang untuk memudahkan deployment server email production-ready dengan keamanan dan best practice yang terintegrasi.

![Ubuntu](https://img.shields.io/badge/Ubuntu-22.04-orange?style=flat-square&logo=ubuntu)
![Zimbra](https://img.shields.io/badge/Zimbra-10.x-green?style=flat-square&logo=zimbra)
![License](https://img.shields.io/badge/License-MIT-blue?style=flat-square)
![Status](https://img.shields.io/badge/Status-Production%20Ready-brightgreen?style=flat-square)

---

## 📋 Daftar Script

| Script | Deskripsi | Status |
|--------|-----------|--------|
| [`zimbra-preinstall.sh`](scripts/zimbra-preinstall.sh) | Persiapan sistem sebelum instalasi Zimbra (DNS, Firewall, Fail2Ban, Dependencies) | ✅ Stable v14.7 |
| [`zimbra-letsencrypt.sh`](scripts/zimbra-letsencrypt.sh) | Otomatisasi SSL Let's Encrypt untuk Zimbra + Auto Renewal | ✅ Stable v1.2 |
| _zimbra_backup.sh_ | Backup otomatis Zimbra (Coming Soon) | 🚧 Development |
| _zimbra_migration.sh_ | Migrasi Zimbra ke server baru (Coming Soon) | 🚧 Development |

---

## 🚀 Quick Start

### 1. Clone Repositori
```bash
git clone https://github.com/kudoluffi/zimbra-scripts.git
cd zimbra-scripts
```
### 2. Jalankan Pre-Install Script
```bash
chmod +x scripts/zimbra_preinstall.sh
sudo bash scripts/zimbra_preinstall.sh
```
### 3. Instal Zimbra
Download installer Zimbra dari sumber resmi, lalu jalankan:
```
./install.sh
```
### 4. Setup SSL
```bash
chmod +x scripts/zimbra_letsencrypt.sh
sudo bash scripts/zimbra_letsencrypt.sh
```
---
## 📖 Dokumentasi Lengkap
Dokumentasi detail untuk setiap script tersedia di folder [_docs/_](docs/):
* [_zimbra_preinstall.md_](docs/zimbra_preinstall.md) - Panduan lengkap pre-installation
* [_zimbra_letsencrypt.md_](docs/zimbra_letsencrypt.md) - Panduan SSL Let's Encrypt
---
## ⚙️ Persyaratan Sistem
### Minimum
* OS: Ubuntu 22.04 LTS (Fresh Install)
* CPU: 2 Cores
* RAM: 4 GB (8 GB recommended untuk production)
* Storage: 40 GB SSD
* Network: Static IP, FQDN valid, Port 25/80/443 terbuka
### Supported Zimbra Version
* Zimbra 10.1.x OSE (Maldua Build)
* Zimbra 10.x Network Edition
* Zimbra 9.x OSE/NE (dengan penyesuaian minor)
---
## 🔒 Fitur Keamanan
* ✅ UFW Firewall - Rule otomatis untuk port Zimbra
* ✅ Fail2Ban - Proteksi brute-force untuk Webmail, IMAP, POP3, SMTP
* ✅ Split-DNS (dnsmasq) - DNS lokal untuk server internal/NAT
* ✅ SSL/TLS - Let's Encrypt dengan auto-renewal
* ✅ Sysctl Hardening - Optimasi kernel untuk mail server
---
## 🛠️ Troubleshooting
| Masalah | Solusi |
|---------|--------|
| Script berhenti di tengah | Cek log di ```/var/log/zimbra_preinstall_*.log```() |
| UFW inactive | Konfigurasi Security Group di cloud provider |
| SSL verification failed | Tambahkan Root CA ISRG X1 ke commercial_ca.crt |
| Fail2Ban tidak start | Pastikan ```/opt/zimbra/log/audit.log``` ada |
---
## 🙏 Credits
* Zimbra Collaboration Suite
* Maldua - Zimbra OSE Build
* Fail2Ban Team - Intrusion prevention system
* Let's Encrypt - Free SSL/TLS certificates
* Ubuntu Community - OS & documentation

