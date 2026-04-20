# 🗄️ Zimbra Backup Script

**Version:** 1.9  
**Last Updated:** 2026  
**Compatibility:** Ubuntu 22.04 LTS + Zimbra 10.1.x OSE

---

## 📋 Deskripsi

Script `zimbra-backup.sh` adalah automation tool untuk backup Zimbra Collaboration Suite secara komprehensif. Script ini mendukung **weekly full backup** + **daily incremental backup** dengan retention policy 30 hari.

Backup mencakup:
- ✅ Konfigurasi Zimbra (global, server, local)
- ✅ Daftar akun & distribution lists
- ✅ Password hashes (encrypted)
- ✅ Mailbox semua user (format TGZ)
- ✅ User preferences (termasuk signatures & filters)

**Excluded system accounts:** `admin@`, `spam.*`, `ham.*`, `virus-quarantine.*`, `galsync.*`, `postmaster@`, `abuse@`

---

## ✨ Fitur Utama

| Fitur | Deskripsi |
|-------|-----------|
| **Weekly Full + Daily Incremental** | Full backup setiap Minggu, incremental hari lainnya |
| **Auto Overwrite Same-Day** | Backup multiple kali sehari tidak membuat duplikat |
| **System Account Exclusion** | Skip akun sistem yang tidak perlu di-backup |
| **Password Hash Backup** | Backup password hash untuk preserve login setelah restore |
| **Secure Permissions** | Password files: 600 (zimbra only) |
| **Retention Policy** | Auto-delete backup > 30 hari |
| **Mailbox Export TGZ** | Format standar Zimbra, bisa restore via zmrestore |
| **User Preferences** | Include signatures, filters, forwarding (dari zmprov ga) |
| **Comprehensive Logging** | Semua proses tercatat di log file |

---
## 🔍 Related Scripts

- **[zimbra-verify-backup.md](zimbra-verify-backup.md)** - Verify backup integrity with Telegram notification
- **zimbra-restore-config.sh** - Restore Zimbra configuration (Coming Soon)
- **zimbra-restore-passwords.sh** - Restore password hashes (Coming Soon)
- **zimbra-restore-mailboxes.sh** - Restore user mailboxes (Coming Soon)

---

## 📱 Telegram Notification

Untuk menerima notifikasi Telegram saat verification FAILED atau WARNING, setup [`zimbra-verify-backup.sh`](zimbra-verify-backup.md) dengan Telegram bot.

**Quick Setup:**
```bash
# 1. Create bot via @BotFather
# 2. Get Chat ID via @userinfobot
# 3. Add to crontab:
0 4 * * * /root/zimbra-verify-backup.sh
```
---

## 📥 Instalasi

### 1. Download Script
```bash
wget https://raw.githubusercontent.com/kudoluffi/zimbra-scripts/main/scripts/zimbra-backup.sh
chmod +x zimbra-backup.sh
```
### 2. Buat Backup Directory
```bash
sudo mkdir -p /backup/zimbra/{config,mailboxes,distribution-lists,passwords,logs}
sudo chown -R zimbra:zimbra /backup/zimbra
sudo chmod 755 /backup/zimbra
sudo chmod 700 /backup/zimbra/passwords
```
### 3. Test Manual Backup
```bash
# Full backup
sudo bash zimbra-backup.sh full

# Incremental backup
sudo bash zimbra-backup.sh incremental

# Auto (Sunday=full, other days=incremental)
sudo bash zimbra-backup.sh auto
```

---

## 🔧 Konfigurasi
### Backup Schedule (Cron)
Edit crontab:
```bash
sudo crontab -e
```
Tambahkan:
```bash
# Daily incremental (Mon-Sat, 2 AM)
0 2 * * 1-6 /root/zimbra-backup.sh incremental >> /var/log/zimbra-backup-cron.log 2>&1

# Weekly full (Sunday, 2 AM)
0 2 * * 0 /root/zimbra-backup.sh full >> /var/log/zimbra-backup-cron.log 2>&1

# Daily verify (4 AM)
0 4 * * * /root/zimbra-verify-backup.sh $(date +%Y%m%d) >> /var/log/zimbra-backup-verify.log 2>&1
```
### Excluded Accounts
Edit bagian EXCLUDE_PATTERNS di script untuk customize:
```bash
EXCLUDE_PATTERNS=(
  "^admin@"              # Administrative accounts
  "^spam\."              # Spam quarantine
  "^ham\."               # Ham quarantine
  "^virus-quarantine\."  # Virus quarantine
  "^galsync\."           # GAL sync accounts
  "^postmaster@"         # System postmaster
  "^abuse@"              # System abuse
)
```
### Retention Policy
Ubah RETENTION_DAYS untuk customize lama penyimpanan:
```
RETENTION_DAYS=30  # Simpan 30 hari terakhir
```

---

## 📁 Backup Structure
```
/backup/zimbra/
├── config/
│   ├── global-config-20260419.txt      # Global settings (zmprov gacf)
│   ├── server-config-20260419.txt      # Server settings (zmprov gs)
│   ├── local-config-20260419.txt       # Local settings (zmlocalconfig)
│   └── zimbra-version-20260419.txt     # Zimbra version info
├── mailboxes/
│   └── 20260419/
│       ├── akun1.tgz              # Mailbox export (TGZ)
│       ├── akun2.tgz
│       ├── akun1-preferences.txt  # User settings (includes signatures & filters)
│       ├── akun2-preferences.txt
│       └── BACKUP-SUMMARY.txt          # Backup summary
├── distribution-lists/
│   ├── domains-20260419.txt              # All domains
│   ├── accounts-20260419.txt             # All accounts
│   ├── distribution-lists-20260419.txt   # All DL emails (zmprov gadl)
│   ├── dl-members-all_example_com-20260419.txt
│   ├── dl-members-distlist2_example_com-20260419.txt
├── passwords/
│   └── 20260419/
│       ├── akun1_example_com.shadow  # Password hash (600 permission)
│       └── akun2_example_com.shadow
└── logs/
    └── zimbra-backup-20260419.log      # Backup log
```

---

## 🔄 Cara Kerja Script

### Flow Proses
```
1. Pre-checks (root access, directories)
2. Export global config (zmprov gacf)
3. Export server config (zmprov gs hostname)
4. Export local config (zmlocalconfig -m)
5. Export domain list (zmprov gad)
6. Export account list (zmprov -l gaa)
7. Export distribution lists (zmprov -l gad -t distributionlist)
8. Backup password hashes (zmprov -l ga user userPassword)
9. Backup mailboxes (zmmailbox getRestURL ?fmt=tgz)
10. Export user preferences (zmprov ga user)
11. Apply retention policy (delete > 30 days)
12. Generate backup summary
```

---

## ✅ Verification

### 1. Check Backup Files
```bash
# List backup directories
ls -la /backup/zimbra/mailboxes/

# Check backup size
du -sh /backup/zimbra/mailboxes/20260419/

# Verify password files permission (MUST be 600)
ls -la /backup/zimbra/passwords/20260419/
# Expected: -rw------- (600) zimbra:zimbra
```
### 2. Verify Backup Integrity
```bash
sudo bash zimbra-verify-backup.sh 20260419
```
### 3. Check Backup Content
```bash
# Verify accounts list contains emails (not help menu)
head -5 /backup/zimbra/distribution-lists/accounts-20260419.txt
# Expected: user@domain.com

# Verify password hash format
sudo cat /backup/zimbra/passwords/20260419/*.shadow | head -3
# Expected: {SSHA}xxxxxxxxxxxxx

# Verify preferences includes signatures
grep -i "zimbraPrefSignature" /backup/zimbra/mailboxes/20260419/*-preferences.txt | head -3
```
### 4. External Verification
```bash
# Check backup log for errors
grep -i "fail\|error" /var/log/zimbra-backup-20260419.log

# Check backup summary
cat /backup/zimbra/mailboxes/20260419/BACKUP-SUMMARY.txt
```

---

## 🛡️ Security Best Practice

### Password Hash Files
| Setting | Value | Why |
|---------|-------|-----|
| Permission | 600 | Only owner (zimbra) can read/write |
| Owner | zimbra:zimbra | Only zimbra user can access |
| Directory | 700 | Only zimbra can enter directory |
| Encryption | Recommended | Encrypt backup disk with LUKS |


---

## 🔗 Referensi
* [Zimbra Backup Guide](https://wiki.zimbra.com/wiki/Backup_and_Restore)
* [zmmailbox Command Reference](https://wiki.zimbra.com/wiki/Zmmailbox)
* [zmprov Command Reference](https://wiki.zimbra.com/wiki/Zmprov)
* [Zimbra Password Management](https://wiki.zimbra.com/wiki/Password_Management)
