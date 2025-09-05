#!/bin/bash
set -euo pipefail

echo "[+] Installing base packages..."
apt-get update -y
apt-get install -y ca-certificates curl tar unzip git redis-server gnupg lsb-release

echo "[+] Setting timezone to MMT (Asia/Yangon)..."
timedatectl set-timezone Asia/Yangon

# ---------------- Docker ----------------
echo "[+] Setting up Docker repository..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list

echo "[+] Installing Docker (CE version)..."
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io
systemctl enable --now docker

# ---------------- Wings ----------------
echo "[+] Downloading Wings binary..."
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) WINGS_ASSET="wings_linux_amd64" ;;
  aarch64|arm64) WINGS_ASSET="wings_linux_arm64" ;;
  *) echo "[!] Unknown arch $ARCH, defaulting to amd64"; WINGS_ASSET="wings_linux_amd64" ;;
esac

curl -Lo /usr/local/bin/wings \
  "https://github.com/pterodactyl/wings/releases/latest/download/${WINGS_ASSET}"
chmod +x /usr/local/bin/wings

echo "[+] Setting up Wings configuration..."
mkdir -p /etc/pterodactyl
# (replace this with wings configure later using your panel token)
curl -Lo /etc/pterodactyl/config.yml \
  https://raw.githubusercontent.com/chanmyaekozin-ucsy/test1234/main/config.yml

# ---------------- Systemd ----------------
echo "[+] Creating Wings systemd service..."
cat > /etc/systemd/system/wings.service << 'EOF'
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

echo "[+] Enabling and starting Wings..."
systemctl daemon-reload
systemctl enable --now wings

echo "[✅] Wings installation completed. Status below:"
systemctl status wings -l --no-pager
