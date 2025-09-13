#!/bin/bash
# bootstrap_and_adopt.sh (safe v3, universal)
# - Install Docker & Wings
# - Run Panel "wings configure"
# - Issue Let's Encrypt for FQDN (short names auto-expanded)
# - Patch config.yml (api.ssl.* only, keep api.host=0.0.0.0)
# - Ensure SFTP host keys exist (owned by pterodactyl)
# - Ensure /var/lib/pterodactyl perms
# - Optional OLD→NEW adoption

set -euo pipefail

EMAIL="chanmyaekozin@gmail.com"
BASE_DOMAIN="flash-myanmar.com"
CERT_BASE="/etc/letsencrypt/live"
VOLBASE="/var/lib/pterodactyl/volumes"
CFG="/etc/pterodactyl/config.yml"
WINGS_BIN="/usr/local/bin/wings"

say()  { printf '\n\033[1;36m%s\033[0m\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1"; exit 1; }; }

[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }

say "== Flash MyID Node Bootstrap + TLS + Adopt =="

# ---------- Base packages ----------
say "[+] Ensuring base packages..."
apt-get update -y
DEBS="ca-certificates curl tar unzip git gnupg lsb-release rsync jq"
apt-get install -y $DEBS || true

# ---------- Docker ----------
if ! command -v docker >/dev/null 2>&1; then
  say "[+] Installing Docker CE..."
  install -m 0755 -d /etc/apt/keyrings || true
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" >/etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io
  systemctl enable --now docker
else
  say "[=] Docker already installed."
fi

# ---------- Wings ----------
if [[ ! -x "$WINGS_BIN" ]]; then
  say "[+] Installing Wings..."
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64) W="wings_linux_amd64" ;;
    aarch64|arm64) W="wings_linux_arm64" ;;
    *)             W="wings_linux_amd64" ;;
  esac
  curl -L -o "$WINGS_BIN" "https://github.com/pterodactyl/wings/releases/latest/download/${W}"
  chmod +x "$WINGS_BIN"
else
  say "[=] Wings binary already present."
fi

# Ensure config dir
mkdir -p /etc/pterodactyl

# Wings systemd service
if [[ ! -f /etc/systemd/system/wings.service ]]; then
  say "[+] Creating Wings systemd service..."
  cat >/etc/systemd/system/wings.service <<'EOF'
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
ExecStart=/usr/local/bin/wings
Restart=always
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
fi
systemctl enable --now wings || true

# ---------- Panel "wings configure" ----------
say "[?] Paste the EXACT line from Panel to configure this node:"
echo "    cd /etc/pterodactyl && sudo wings configure --panel-url https://panel.flash-myanmar.com --token XXXXX --node NNN"
read -r -p "Paste here (or leave empty to skip): " CONFIG_CMD
if [[ -n "${CONFIG_CMD:-}" ]]; then
  bash -lc "$CONFIG_CMD"
  say "[=] 'wings configure' finished."
else
  say "[=] Skipped 'wings configure' (make sure $CFG exists already)."
fi

# ---------- Ensure SFTP keys ----------
say "[+] Ensuring SFTP host keys ..."
SSH_DIR="/etc/pterodactyl/ssh"
install -d -m 700 "$SSH_DIR"

if id -u pterodactyl >/dev/null 2>&1; then
  chown pterodactyl:pterodactyl "$SSH_DIR"
else
  chown 999:986 "$SSH_DIR" || true
fi

[[ -f "$SSH_DIR/ssh_host_ed25519_key" ]] || ssh-keygen -t ed25519 -f "$SSH_DIR/ssh_host_ed25519_key" -N ""
[[ -f "$SSH_DIR/ssh_host_rsa_key"     ]] || ssh-keygen -t rsa -b 4096 -f "$SSH_DIR/ssh_host_rsa_key" -N ""

chmod 600 "$SSH_DIR"/ssh_host_*_key
chmod 644 "$SSH_DIR"/ssh_host_*_key.pub
chown -R pterodactyl:pterodactyl "$SSH_DIR" || true

# ---------- Ensure /var/lib perms ----------
say "[+] Fixing /var/lib/pterodactyl permissions ..."
mkdir -p /var/lib/pterodactyl/{volumes,archives,backups}
chown -R pterodactyl:pterodactyl /var/lib/pterodactyl
chmod 755 /var/lib/pterodactyl /var/lib/pterodactyl/*

# ---------- Ask name/FQDN & issue cert ----------
read -rp "Enter node name or FQDN (e.g. game1 OR game1.${BASE_DOMAIN}): " NAME
[[ -n "${NAME:-}" ]] || { echo "Name cannot be empty."; exit 1; }
if [[ "$NAME" == *.* ]]; then
  DOMAIN="$NAME"
else
  DOMAIN="${NAME}.${BASE_DOMAIN}"
fi
say "[+] FQDN: $DOMAIN"

if ! command -v certbot >/dev/null 2>&1; then
  apt-get install -y certbot
fi

NGINX_STOPPED=0
if ss -ltnp | grep -q ':80 '; then
  if systemctl is-active --quiet nginx; then
    systemctl stop nginx
    NGINX_STOPPED=1
  else
    echo "Port 80 in use by non-nginx process. Free it and re-run."; exit 1
  fi
fi

certbot certonly --standalone -d "${DOMAIN}" -m "${EMAIL}" --agree-tos -n --keep-until-expiring
CERT_DIR="${CERT_BASE}/${DOMAIN}"
[[ -f "${CERT_DIR}/fullchain.pem" && -f "${CERT_DIR}/privkey.pem" ]] || { echo "Cert not found in ${CERT_DIR}"; exit 1; }
[[ "$NGINX_STOPPED" -eq 1 ]] && systemctl start nginx || true

# ---------- Patch config.yml ----------
say "[+] Patching config.yml ..."
# patch SSL
sed -i -E "/^api:/,/^[^[:space:]]/ {
  s#^(\s{2})host:.*#\1host: 0.0.0.0#;
  /^\s{2}ssl:/,/^[^[:space:]]/ {
    s#^(\s{4})enabled:.*#\1enabled: true#;
    s#^(\s{4})cert:.*#\1cert: ${CERT_DIR}/fullchain.pem#;
    s#^(\s{4})key:.*#\1key: ${CERT_DIR}/privkey.pem#;
  }
}" "$CFG"

# add host_key_path if missing
if ! grep -q "host_key_path:" "$CFG"; then
  sed -i "/^\s{2}sftp:/a\    host_key_path: /etc/pterodactyl/ssh" "$CFG"
fi

# ---------- Restart Wings ----------
systemctl restart wings
sleep 1
journalctl -u wings -n 50 --no-pager || true

say "== Done bootstrap =="
