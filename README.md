# Frappe v16 Automated Installer (Ubuntu 24.04)

One-shot production-oriented installer for:

- Frappe Framework v16
- ERPNext (v16)
- HRMS (v16)
- Builder (v16-compatible)

Script: [`install_frappe_v16.sh`](https://github.com/rbnkoirala/frappe-16-installation/blob/main/install_frappe_v16.sh)

## What this script sets up

- Ubuntu 24.04 dependency stack
- Python 3.14
- Node.js 24 + Yarn classic
- MariaDB, Redis, Nginx, Supervisor
- wkhtmltopdf + fonts
- Bench + `frappe-bench`
- Site creation and app installation
- Production config (`bench setup production`)
- SSL via Certbot (optional)
- Swap (default 8 GB) to avoid frontend build OOM

## Quick Start

### 1) Download the script on your VPS

```bash
wget -O install_frappe_v16.sh https://raw.githubusercontent.com/rbnkoirala/frappe-16-installation/main/install_frappe_v16.sh
chmod +x install_frappe_v16.sh
```

### 2) Run installer (interactive passwords)

```bash
sudo bash install_frappe_v16.sh \
  --domain yourdomain.com \
  --email admin@yourdomain.com \
  --frappe-user frappe \
  --bench frappe-bench \
  --timezone Asia/Kathmandu
```

### 3) Run installer (non-interactive passwords)

```bash
sudo DB_ROOT_PASSWORD='your_db_root_password' \
ADMIN_PASSWORD='your_admin_password' \
bash install_frappe_v16.sh \
  --domain yourdomain.com \
  --email admin@yourdomain.com \
  --yes
```

## Script Options

- `--domain` Domain for host config and SSL (example: `yourdomain.com`)
- `--site` Site name (optional; script prompts if omitted)
- `--email` Let’s Encrypt email (SSL skipped if omitted)
- `--frappe-user` Bench OS user (default: `frappe`)
- `--bench` Bench directory name (default: `frappe-bench`)
- `--timezone` Server timezone (default: `Asia/Kathmandu`)
- `--yes` Skip final execution confirmation prompt

## Environment Variables

- `DB_ROOT_PASSWORD` MariaDB root password used during site creation
- `ADMIN_PASSWORD` ERPNext Administrator password
- `SWAP_GB` Swap size in GB (default: `8`)

## Verification After Install

```bash
sudo supervisorctl status
sudo nginx -t
curl -I http://yourdomain.com
curl -I https://yourdomain.com
```

## Common Notes

If behind Cloudflare and you get `521`, confirm:

- `A` record points to server IP
- No incorrect `AAAA` record
- Origin allows inbound `80/443`
- Cloudflare SSL mode is `Full (strict)`

## Security Reminder

Rotate credentials after install:

- MariaDB root password
- ERPNext Administrator password
- SSH keys/password policy

## License

MIT (or your preferred license).

> **Note:** This installer is still under testing. Do not rely on it fully before validating it in your own environment.
