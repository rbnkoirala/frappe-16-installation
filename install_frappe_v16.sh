#!/usr/bin/env bash
set -euo pipefail

########################################
# Frappe v16 + ERPNext + HRMS + Builder
# Ubuntu 24.04 production installer
########################################

FRAPPE_USER="frappe"
BENCH_NAME="frappe-bench"
DOMAIN=""
SITE_NAME=""
LE_EMAIL=""
TZ_NAME="Asia/Kathmandu"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
SWAP_GB="${SWAP_GB:-8}"

usage() {
  cat <<'EOF'
Usage:
  sudo bash install_frappe_v16.sh \
    --domain planettechnepal.com \
    --site planettechnepal.com \
    --email admin@planettechnepal.com \
    --frappe-user frappe \
    --bench frappe-bench \
    --timezone Asia/Kathmandu

Optional environment variables:
  DB_ROOT_PASSWORD   MariaDB root password for bench new-site
  ADMIN_PASSWORD     Administrator password for ERPNext site
  SWAP_GB            Swap size in GB (default: 8)

Notes:
  - If DB_ROOT_PASSWORD / ADMIN_PASSWORD are not set, script prompts securely.
  - SSL is skipped if --email is not provided.
EOF
}

log() {
  echo
  echo "==> $*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

as_frappe() {
  local cmd="$1"
  sudo -H -u "$FRAPPE_USER" bash -lc "set -euo pipefail; export PATH=\"\$HOME/.local/bin:\$PATH\"; $cmd"
}

app_installed() {
  local app="$1"
  as_frappe "cd ~/$BENCH_NAME && bench --site '$SITE_NAME' list-apps | awk '{print \$1}' | grep -qx '$app'"
}

install_swap() {
  if swapon --show | awk '{print $1}' | grep -qx "/swapfile"; then
    log "Swap already configured"
    return
  fi

  log "Creating ${SWAP_GB}G swap at /swapfile"
  fallocate -l "${SWAP_GB}G" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=$((SWAP_GB * 1024)) status=progress
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo 'vm.swappiness=20' > /etc/sysctl.d/99-frappe-swap.conf
  sysctl -p /etc/sysctl.d/99-frappe-swap.conf >/dev/null
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain) DOMAIN="${2:-}"; shift 2 ;;
      --site) SITE_NAME="${2:-}"; shift 2 ;;
      --email) LE_EMAIL="${2:-}"; shift 2 ;;
      --frappe-user) FRAPPE_USER="${2:-}"; shift 2 ;;
      --bench) BENCH_NAME="${2:-}"; shift 2 ;;
      --timezone) TZ_NAME="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown argument: $1" ;;
    esac
  done
}

parse_args "$@"

[[ "$(id -u)" -eq 0 ]] || die "Run as root (sudo)."

if [[ -z "$SITE_NAME" ]]; then
  if [[ -n "$DOMAIN" ]]; then
    SITE_NAME="$DOMAIN"
  else
    read -rp "Site name (e.g. planettechnepal.com): " SITE_NAME
  fi
fi

if [[ -z "$DB_ROOT_PASSWORD" ]]; then
  read -rsp "MariaDB root password (set/use): " DB_ROOT_PASSWORD
  echo
fi

if [[ -z "$ADMIN_PASSWORD" ]]; then
  read -rsp "ERPNext Administrator password: " ADMIN_PASSWORD
  echo
fi

if [[ -n "$DOMAIN" && -z "$LE_EMAIL" ]]; then
  read -rp "Let's Encrypt email (blank to skip SSL): " LE_EMAIL
fi

export DEBIAN_FRONTEND=noninteractive

log "OS check"
cat /etc/os-release | sed -n '1,8p'

log "System update + base packages"
apt-get update
apt-get -y full-upgrade
apt-get -y install software-properties-common ca-certificates curl gnupg lsb-release \
  git vim htop unzip zip net-tools rsync cron dnsutils

log "Timezone"
timedatectl set-timezone "$TZ_NAME" || true
timedatectl status | sed -n '1,5p'

log "Install Python 3.14 + build deps"
add-apt-repository -y ppa:deadsnakes/ppa
apt-get update
apt-get -y install \
  python3.14 python3.14-venv python3.14-dev python3 python3-venv python3-dev python3-pip python3-setuptools \
  build-essential gcc g++ make \
  libffi-dev libssl-dev libjpeg-dev zlib1g-dev \
  libxml2-dev libxslt1-dev libmariadb-dev libmariadb-dev-compat \
  libldap2-dev libsasl2-dev libtiff5-dev libcurl4-openssl-dev \
  pipx acl
python3.14 --version

log "Install Node.js 24 + Yarn classic"
curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
apt-get -y install nodejs
corepack enable
corepack prepare yarn@1.22.22 --activate
node -v
npm -v
yarn -v

log "Install MariaDB, Redis, Nginx, Supervisor, wkhtmltopdf"
apt-get -y install \
  mariadb-server mariadb-client redis-server nginx supervisor \
  wkhtmltopdf fonts-dejavu fonts-liberation xfonts-75dpi xfonts-base \
  certbot python3-certbot-nginx ansible
systemctl enable --now mariadb redis-server nginx supervisor

log "MariaDB Frappe config"
cat > /etc/mysql/mariadb.conf.d/99-frappe.cnf <<'EOF'
[mysqld]
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
skip-character-set-client-handshake
innodb_file_per_table = 1
innodb_large_prefix = 1
max_connections = 1000
sql_mode = STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION
EOF
systemctl restart mariadb

log "Set/verify MariaDB root password"
if mysql -u root -e "SELECT 1;" >/dev/null 2>&1; then
  mysql -u root <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASSWORD}';
FLUSH PRIVILEGES;
SQL
elif mysql -u root -p"${DB_ROOT_PASSWORD}" -e "SELECT 1;" >/dev/null 2>&1; then
  echo "MariaDB root password already valid."
else
  die "Could not authenticate MariaDB root. Provide correct DB_ROOT_PASSWORD and re-run."
fi
mysql -u root -p"${DB_ROOT_PASSWORD}" -e "SELECT VERSION();"

log "Create/prepare frappe user"
if ! id -u "$FRAPPE_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$FRAPPE_USER"
fi
usermod -aG sudo "$FRAPPE_USER"
id "$FRAPPE_USER"

log "Install bench + uv under $FRAPPE_USER"
as_frappe "pipx install --force frappe-bench"
as_frappe "pipx install --force uv"
as_frappe "bench --version"

log "Install swap (OOM protection for asset build)"
install_swap
free -h
swapon --show

log "Initialize bench (v16)"
if [[ ! -d "/home/$FRAPPE_USER/$BENCH_NAME" ]]; then
  as_frappe "bench init --frappe-branch version-16 --python /usr/bin/python3.14 '$BENCH_NAME'"
else
  echo "/home/$FRAPPE_USER/$BENCH_NAME already exists, skipping bench init."
fi

log "Create site if missing"
if ! as_frappe "cd ~/$BENCH_NAME && bench --site '$SITE_NAME' list-apps >/dev/null 2>&1"; then
  as_frappe "cd ~/$BENCH_NAME && bench new-site '$SITE_NAME' --db-root-password '$DB_ROOT_PASSWORD' --admin-password '$ADMIN_PASSWORD'"
else
  echo "Site $SITE_NAME already exists, skipping new-site."
fi

log "Fetch apps (v16 branches)"
if [[ ! -d "/home/$FRAPPE_USER/$BENCH_NAME/apps/erpnext" ]]; then
  as_frappe "cd ~/$BENCH_NAME && bench get-app --branch version-16 erpnext"
fi
if [[ ! -d "/home/$FRAPPE_USER/$BENCH_NAME/apps/hrms" ]]; then
  as_frappe "cd ~/$BENCH_NAME && bench get-app --branch version-16 hrms"
fi
if [[ ! -d "/home/$FRAPPE_USER/$BENCH_NAME/apps/builder" ]]; then
  as_frappe "cd ~/$BENCH_NAME && bench get-app --branch version-16 builder || bench get-app --branch main builder"
fi

log "Install apps on site"
if ! app_installed erpnext; then
  as_frappe "cd ~/$BENCH_NAME && bench --site '$SITE_NAME' install-app erpnext"
fi
if ! app_installed hrms; then
  as_frappe "cd ~/$BENCH_NAME && bench --site '$SITE_NAME' install-app hrms"
fi
if ! app_installed builder; then
  as_frappe "cd ~/$BENCH_NAME && bench --site '$SITE_NAME' install-app builder"
fi

log "Site config + migrate + build"
as_frappe "cd ~/$BENCH_NAME && bench use '$SITE_NAME'"
if [[ -n "$DOMAIN" ]]; then
  as_frappe "cd ~/$BENCH_NAME && bench --site '$SITE_NAME' set-config host_name 'https://$DOMAIN'"
fi
as_frappe "cd ~/$BENCH_NAME && bench --site '$SITE_NAME' set-config developer_mode 0"
as_frappe "cd ~/$BENCH_NAME && bench --site '$SITE_NAME' set-config maintenance_mode 0"
as_frappe "cd ~/$BENCH_NAME && bench --site '$SITE_NAME' migrate"
as_frappe "cd ~/$BENCH_NAME && export NODE_OPTIONS='--max-old-space-size=4096'; bench build --production"

log "Production setup (nginx + supervisor)"
ln -sf "/home/$FRAPPE_USER/.local/bin/bench" /usr/local/bin/bench
cd "/home/$FRAPPE_USER/$BENCH_NAME"
bench setup production "$FRAPPE_USER" --yes

# Bench-generated nginx may use access_log ... main;
# Define log format globally so nginx -t always succeeds.
cat > /etc/nginx/conf.d/00-log-format-main.conf <<'EOF'
log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                '$status $body_bytes_sent "$http_referer" '
                '"$http_user_agent" "$http_x_forwarded_for"';
EOF

rm -f /etc/nginx/sites-enabled/default || true

# Ensure ownership and ACLs are safe for nginx/static/log access.
chown -R "$FRAPPE_USER:$FRAPPE_USER" "/home/$FRAPPE_USER/$BENCH_NAME"
setfacl -m u:www-data:rx "/home/$FRAPPE_USER" || true
setfacl -m u:www-data:rx "/home/$FRAPPE_USER/$BENCH_NAME" || true
setfacl -R -m u:www-data:rx "/home/$FRAPPE_USER/$BENCH_NAME/sites" || true
setfacl -R -m u:www-data:rx "/home/$FRAPPE_USER/$BENCH_NAME/sites/assets" || true
setfacl -R -m u:www-data:rwX "/home/$FRAPPE_USER/$BENCH_NAME/logs" || true

nginx -t
systemctl restart nginx

# Load supervisor config in case it did not auto-link.
if [[ -f "/home/$FRAPPE_USER/$BENCH_NAME/config/supervisor.conf" ]]; then
  cp "/home/$FRAPPE_USER/$BENCH_NAME/config/supervisor.conf" "/etc/supervisor/conf.d/$BENCH_NAME.conf"
fi
supervisorctl reread || true
supervisorctl update || true

# Clear stale manual bench redis daemons, then start supervisor-managed ones.
pkill -f "redis-server .*${BENCH_NAME}/config/redis_queue.conf" || true
pkill -f "redis-server .*${BENCH_NAME}/config/redis_cache.conf" || true
supervisorctl restart "${BENCH_NAME}-redis:*" || true
supervisorctl restart "${BENCH_NAME}-web:*" || true
supervisorctl restart "${BENCH_NAME}-workers:*" || true

log "Enable scheduler"
as_frappe "cd ~/$BENCH_NAME && bench --site '$SITE_NAME' enable-scheduler || true"

if [[ -n "$DOMAIN" && -n "$LE_EMAIL" ]]; then
  log "Configure SSL via certbot"
  certbot --nginx -d "$DOMAIN" -m "$LE_EMAIL" --agree-tos --redirect --non-interactive --keep-until-expiring || true
fi

log "Verification"
ss -ltnp | egrep ':80 |:443 |:11001|:13001' || true
supervisorctl status || true
as_frappe "cd ~/$BENCH_NAME && bench --site '$SITE_NAME' list-apps"
as_frappe "cd ~/$BENCH_NAME && bench doctor || true"
curl -I -H "Host: $SITE_NAME" http://127.0.0.1 || true
if [[ -n "$DOMAIN" ]]; then
  curl -kI -H "Host: $DOMAIN" https://127.0.0.1 || true
  curl -I "https://$DOMAIN" || true
fi

echo
echo "Install completed."
echo "Site: $SITE_NAME"
if [[ -n "$DOMAIN" ]]; then
  echo "URL: https://$DOMAIN"
else
  echo "URL: http://<server-ip>"
fi
