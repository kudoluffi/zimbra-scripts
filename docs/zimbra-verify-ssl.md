# 🔒 Zimbra SSL Verification Script

**Version:** 1.1  
**Last Updated:** 2026

## Deskripsi
Script untuk verifikasi SSL certificate deployment di semua layanan Zimbra.

## Usage
```bash
sudo bash zimbra-verify-ssl.sh
```

### Checks
1. Certificate deployed di Zimbra config
2. HTTPS (Port 443)
3. IMAPS (Port 993)
4. POP3S (Port 995)
5. SMTPS (Port 465)
6. Certificate expiry
7. Auto-renewal cron
8. Certbot timer status

### Output
Semua check harus [PASS] sebelum lanjut ke step berikutnya.
