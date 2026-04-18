# 📜 Zimbra Pre-Install Script

**Version:** 14.7  
**Last Updated:** 2026  
**Compatibility:** Ubuntu 22.04 LTS + Zimbra 10.1.x OSE/NE

---

## 📋 Deskripsi

Script `zimbra-preinstall.sh` adalah automation tool untuk mempersiapkan server Ubuntu 22.04 sebelum instalasi Zimbra Collaboration Suite. Script ini menangani konfigurasi sistem yang kompleks dan rawan error jika dilakukan manual, sehingga instalasi Zimbra dapat berjalan lancar tanpa hambatan DNS, firewall, atau dependency.

---

## ✨ Fitur Utama

| Fitur | Deskripsi |
|-------|-----------|
| **Auto Dependencies** | Install semua package yang dibutuhkan Zimbra |
| **Split-DNS (dnsmasq)** | DNS lokal dengan MX record otomatis untuk server internal/NAT |
| **Firewall (UFW)** | Rule otomatis untuk port Zimbra (25,80,443,587,993,995,7071) |
| **Fail2Ban** | Proteksi brute-force untuk Webmail, IMAP, POP3, SMTP |
| **Time Sync** | Chrony/systemd-timesyncd untuk sinkronisasi waktu akurat |
| **Sysctl Tuning** | Optimasi kernel untuk performa mail server |
| **systemd-resolved Fix** | Disable konflik DNS resolver bawaan Ubuntu |
| **MX Record Auto** | Otomatis generate MX record untuk domain |

---

## 📥 Instalasi

### 1. Download Script
```bash
wget https://raw.githubusercontent.com/kudoluffi/zimbra-scripts/main/scripts/zimbra-preinstall.sh
chmod +x zimbra-preinstall.sh
```
### 2. Jalankan Script
```bash
sudo ./zimbra-preinstall.sh
```
### 3. Input Konfigurasi
Script akan meminta 4 informasi:
```bash
FQDN (mail.example.com):
IP Internal Server:
Upstream DNS (8.8.8.8/1.1.1.1):
Domain Email (example.com):
```
| Parameter | Deskripsi | Contoh |
|-----------|-----------|--------|
| FQDN | Hostname lengkap server mail | mail.example.com |
| IP Internal | IP address server (public/private) | 192.168.1.50 |
| Upstream DNS | DNS publik untuk forward query | 8.8.8.8 |
| Domain Email | Domain utama untuk email | example.com |
---
## 🔧 Konfigurasi yang Diubah
File Sistem
| File | Perubahan |
|------|-----------|
| ```/etc/hosts``` | Entry FQDN & IP server |
| ```/etc/dnsmasq.conf``` | Split-DNS + MX record |
| ```/etc/resolv.conf``` | Nameserver ke 127.0.0.1 |
| ```/etc/sysctl.d/99-zimbra.conf``` | Kernel tuning |
| ```/etc/fail2ban/jail.d/zimbra.conf``` | Rule brute-force protection |
| ```/etc/ufw/*``` | Firewall rules |

Port yang Dibuka
| Port | Service | Protokol |
|------|---------|----------|
| 22 | SSH | TCP |
| 25 | SMTP | TCP |
| 80 | HTTP | TCP |
| 110 | POP3 | TCP |
| 143 | IMAP | TCP |
| 443 | HTTPS | TCP |
| 587 | SMTP Submission | TCP |
| 993 | IMAPS | TCP |
| 995 | POP3S | TCP |
| 7071 | Zimbra Admin | TCP |
---
## ✅ Verifikasi Setelah Instalasi
### 1. Cek Status Service
```bash
systemctl is-active dnsmasq fail2ban ufw chrony
# Semua harus return "active"
```
### 2. Test DNS Lokal
```bash
# Test A record
dig nmail.newbienotes.my.id @127.0.0.1 +short

# Test MX record (WAJIB untuk Zimbra)
dig MX newbienotes.my.id @127.0.0.1 +short
# Output: 10 nmail.newbienotes.my.id.
```
### 3. Test Firewall
```bash
ufw status verbose
nmap -p 25,80,443,587,993 <IP_SERVER>
```
### 4. Test Fail2Ban
```bash
fail2ban-client status zimbra-auth
# Setelah Zimbra install & jail enabled
```
---
## Download dan Install Zimbra Foss from Maldua
https://maldua.github.io/zimbra-foss/downloads/stable.html
```bash
wget https://github.com/maldua/zimbra-foss/releases/download/zimbra-foss-build-ubuntu-22.04/10.1.16.p1/zcs-10.1.16_GA_4200001.UBUNTU22_64.20260310121616.tgz
tar -xvf zcs-10.1.16_GA_4200001.UBUNTU22_64.20260310121616.tgz
cd zcs-10.1.16_GA_4200001.UBUNTU22_64.20260310121616
sudo ./install.sh
```
---
## 📦 Post-Installation
Setelah Zimbra Selesai Install:
### 1. Aktifkan Fail2Ban
```bash
sudo sed -i 's/enabled  = false/enabled  = true/' /etc/fail2ban/jail.d/zimbra.conf
sudo systemctl restart fail2ban
sudo fail2ban-client status zimbra-auth
```
### 2. Whitelist IP Kantor
Edit /etc/fail2ban/jail.d/zimbra.conf:
```bash
[zimbra-auth]
ignoreip = 127.0.0.1/8 ::1 IP_KANTOR_ANDA/32
```
### 3. Backup Konfigurasi
```bash
cp /etc/dnsmasq.conf /root/dnsmasq.conf.backup
cp /etc/fail2ban/jail.d/zimbra.conf /root/zimbra-jail.backup
ufw export > /root/ufw-rules.backup
```
### 4. Monitor Log
```bash
tail -f /var/log/fail2ban.log
tail -f /opt/zimbra/log/audit.log
```
