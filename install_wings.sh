#!/bin/bash
set -Eeuo pipefail

# ====== CONFIG (optional) ======
# Set a fast mirror if your default Ubuntu mirrors are slow/blocked.
# Leave empty to keep defaults. Example mirrors:
# - http://mirror.cse.iitk.ac.in/ubuntu
# - http://mirror.yandex.ru/ubuntu
# - http://mirrors.ustc.edu.cn/ubuntu
APT_MIRROR="${APT_MIRROR:-}"

# Timeout (seconds) for curl/wget network ops
NET_TIMEOUT="${NET_TIMEOUT:-25}"

export DEBIAN_FRONTEND=noninteractive

log() { echo -e "\e[1;32m[+]\e[0m $*"; }
warn() { echo -e "\e[1;33m[!]\e[0m $*"; }
err() { echo -e "\e[1;31m[✗]\e[0m $*" >&2; }

retry() {
  local tries="${2:-5}" delay=3
  for ((i=1; i<=tries; i++)); do
    if eval "$1"; then return 0; fi
    warn "Attempt $i failed: $1"
    sleep "$delay"
    delay=$((delay*2))
  done
  err "Command failed after $tries attempts: $1"
  return 1
}

# ====== Mirror switch (optional) ======
if [[ -n "${APT_MIRROR}" ]]; then
  log "Switching APT mirror to: $APT_MIRROR"
  sudo cp -a /etc/apt/sources.list /etc/apt/sources.list.bak || true
  sudo sed -i "s|http://[^ ]*ubuntu.com/ubuntu/|${APT_MIRROR}/|g" /etc/apt/sources.list
fi

# ====== APT prep ======
log "Refreshing package lists…"
retry "sudo apt-get update -o Acquire::Retries=3 -o Acquire::http::No-Cache=true -o Acquire::http::Pipeline-Depth=0 -yq" 5

log "Installing required packages…"
retry "sudo apt-get install -yq --no-install-recommends \
  ca-certificates curl tar unzip git redis-server gnupg lsb-release" 5

# ====== Timezone ======
log 'Setting timezone to MMT (Asia/Yangon)…'
sudo timedatectl set-timezone Asia/Yangon || warn "timedatectl failed; continuing"

# ====== Docker install with fallbacks ======
install_docker_via_script() {
  log "Installing Docker (get.docker.com)…"
  curl -fsSL --max-time "$NET_TIMEOUT" https://get.docker.com | sh
}

install_docker_via_apt() {
  log "Installing docker.io from Ubuntu repos (fallback)…"
  retry "sudo apt-get install -yq docker.io" 5
}

if ! command -v docker >/dev/null 2>&1; then
  if ! install_docker_via_script; then
    warn "get.docker.com path failed, trying docker.io…"
    install_docker_via_apt
  fi
else
  log "Docker already present."
fi

log "Enabling and starting docker service…"
sudo systemctl enable --now docker

# ====== Wings binary ======
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) WINGS_ASSET="wings_linux_amd64" ;;
  aarch64|arm64) WINGS_ASSET="wings_linux_arm64" ;;
  *) warn "Unknown arch $ARCH; defaulting to amd64"; WINGS_ASSET="wings_linux_amd64" ;;
esac

log "Downloading Wings binary (${WINGS_ASSET})…"
sudo curl -fL --connect-timeout "$NET_TIMEOUT" --retry 5 \
  -o /usr/local/bin/wings \
  "https://github.com/pterodactyl/wings/releases/latest/download/${WINGS_ASSET}"
sudo chmod +x /usr/local/bin/wings

# ====== Wings config ======
log "Setting up Wings configuration…"
sudo mkdir -p /etc/pterodactyl
sudo curl -fL --connect-timeout "$NET_TIMEOUT" --retry 5 \
  -o /etc/pterodactyl/config.yml \
  "https://raw.githubusercontent.com/chanmyaekozin-ucsy/test1234/main/config.yml"

# ====== Systemd unit ======
log "Creating Wings systemd service…"
sudo tee /etc/systemd/system/wings.service >/dev/null <<'EOF'
[Unit]
Description=Pterodactyl Wings Daemon
Wants=network-online.target
After=network-online.target docker.service
Requires=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
ExecStart=/usr/local/bin/wings
Restart=on-failure
RestartSec=5
StartLimitInterval=180
StartLimitBurst=10
LimitNOFILE=1048576
# Light hardening
NoNewPrivileges=yes
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_SYS_ADMIN

[Install]
WantedBy=multi-user.target
EOF

# ====== Start Wings ======
log "Enabling and starting Wings…"
sudo systemctl daemon-reload
sudo systemctl enable --now wings

log "Wings installation completed. Status below:"
sudo systemctl status wings --no-pager || true
