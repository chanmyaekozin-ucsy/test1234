#!/bin/bash
set -e


echo "[+] Installing required packages..."
apt install -y curl tar unzip git redis-server

echo "[+] Setting timezone to MMT (Asia/Yangon)..."
timedatectl set-timezone Asia/Yangon

echo "[+] Installing Docker..."
curl -fsSL https://get.docker.com | sh
systemctl enable --now docker

echo "[+] Downloading Wings binary..."
curl -Lo /usr/local/bin/wings https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64
chmod +x /usr/local/bin/wings

echo "[+] Setting up Wings configuration..."
mkdir -p /etc/pterodactyl
curl -Lo /etc/pterodactyl/config.yml https://raw.githubusercontent.com/chanmyaekozin-ucsy/test1234/main/config.yml

echo "[+] Creating Wings systemd service..."
cat > /etc/systemd/system/wings.service << EOF
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PIDFile=/var/run/wings.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=10

[Install]
WantedBy=multi-user.target
EOF

echo "[+] Enabling and starting Wings..."
systemctl daemon-reload
systemctl enable --now wings

echo "[✅] Wings installation completed. Status below:"
systemctl status wings --no-pager
