# 🔒 Zimbra Let's Encrypt Script

**Version:** 1.2  
**Last Updated:** 2026  
**Compatibility:** Ubuntu 22.04 LTS + Zimbra 10.1.x OSE/NE

---

## 📋 Deskripsi

Script `zimbra-letsencrypt.sh` adalah automation tool untuk menerbitkan, deploy, dan auto-renewal SSL certificate dari **Let's Encrypt** pada server Zimbra Collaboration Suite. Script ini menangani seluruh proses kompleks termasuk stop/start service, verifikasi domain, konversi format certificate, dan deployment ke semua layanan Zimbra (nginx, postfix, dovecot, dll).

---

## ✨ Fitur Utama

| Fitur | Deskripsi |
|-------|-----------|
| **Auto Issue** | Request SSL certificate dari Let's Encrypt secara otomatis |
| **Standalone Mode** | Verifikasi via HTTP-01 challenge (port 80) |
| **DNS-01 Support** | Alternatif verifikasi via DNS TXT record (jika port 80 diblokir) |
| **Auto Deploy** | Deploy certificate ke semua layanan Zimbra |
| **Auto Renewal** | Cron job mingguan untuk renew certificate sebelum expired |
| **Email Optional** | Tidak wajib input email untuk ACME account |
| **Chain Fix** | Otomatis tambahkan Root CA ISRG X1 untuk validasi Zimbra |
| **Logging** | Semua proses tercatat di log file untuk troubleshooting |

---

## 📥 Instalasi

### 1. Download Script
```bash
wget https://raw.githubusercontent.com/kudoluffi/zimbra-scripts/main/scripts/zimbra-letsencrypt.sh
chmod +x zimbra-letsencrypt.sh
```
### 2. Prasyarat Wajib
Sebelum menjalankan script, pastikan:
* ✅ Zimbra sudah terinstall & berjalan normal
* ✅ FQDN sudah memiliki A Record yang mengarah ke IP publik server
* ✅ Port 80 & 443 terbuka dari internet (untuk HTTP challenge)
* ✅ Script dijalankan sebagai root

### 3. Jalankan Script
```bash
sudo ./zimbra-letsencrypt.sh
```

### 4. Input Konfigurasi
Script akan meminta 2 informasi:
```bash
FQDN Zimbra (contoh: mail.example.com): mail.example.com
Email ACME recovery (opsional, tekan Enter untuk skip): admin@example.com
```
| Parameter | Deskripsi | Wajib? |
|-----------|-----------|--------|
| FQDN | Hostname lengkap Zimbra (harus sama dengan A record) | ✅ Ya |
| Email | Email untuk recovery ACME account | ❌ Opsional |
---

## 🔧 Cara Kerja Script
### Flow Proses
```
1. Install Certbot (jika belum ada)
2. Stop Zimbra web services (zmproxy, zmmailboxd)
3. Request certificate dari Let's Encrypt via port 80
4. Copy certificate ke /opt/zimbra/ssl/letsencrypt/
5. Tambahkan Root CA ISRG X1 ke commercial_ca.crt
6. Verify certificate dengan zmcertmgr
7. Deploy certificate ke semua layanan Zimbra
8. Restart Zimbra services
9. Setup cron job untuk auto-renewal
```

### File yang Dimodifikasi
| File | Perubahan |
|------|-----------|
| ```/opt/zimbra/ssl/letsencrypt/commercial.crt``` | Fullchain certificate (Leaf + Intermediate) |
| ```/opt/zimbra/ssl/letsencrypt/commercial.key``` | Private key |
| ```/opt/zimbra/ssl/letsencrypt/commercial_ca.crt``` | CA Bundle (Intermediate + Root ISRG X1) |
| ```/etc/cron.d/zimbra-le-renew``` | Cron job auto-renewal mingguan |
| ```/usr/local/bin/zimbra-le-renew.sh``` | Script renewal otomatis |
---

## ✅ Verifikasi Setelah Instalasi
### 1. Cek Certificate yang Terdeploy
```
su - zimbra -c "/opt/zimbra/bin/zmcertmgr viewdeployedcrt"
```
Output yang diharapkan:
```
*** Certificate '/opt/zimbra/ssl/zimbra/commercial/commercial.crt' properties
  Subject: CN=mail.example.com
  Issuer: C=US, O=Let's Encrypt, CN=R12
  Validity: Not Before: Apr 16 00:00:00 2026 GMT
            Not After: Jul 16 00:00:00 2026 GMT
```
### 2. Cek via Browser
1. Buka https://mail.example.com
2. Klik icon gembok di address bar
3. Pilih Certificate is valid
4. Verifikasi:
   * ✅ Issued to: mail.example.com
   * ✅ Issued by: Let's Encrypt R12
   * ✅ Valid until: (tanggal 90 hari dari sekarang)

### 3. Cek via OpenSSL
```bash
echo | openssl s_client -connect nmail.newbienotes.my.id:443 -servername nmail.newbienotes.my.id 2>/dev/null | openssl x509 -noout -dates
```
Output:
```bash
notBefore=Apr 16 00:00:00 2026 GMT
notAfter=Jul 16 00:00:00 2026 GMT
```
