#!/bin/bash
# bootstrap_and_adopt.sh
# - Bootstrap node (Docker, Wings) if needed
# - Issue TLS cert for node FQDN
# - (Optional) patch /etc/pterodactyl/config.yml to use TLS + host, restart wings
# - Discover old UUIDs, prompt mapping to NEW_UUIDs, migrate files, remove old containers/data, restart Docker

set -euo pipefail

EMAIL="chanmyaekozin@gmail.com"
CERT_BASE="/etc/letsencrypt/live"
VOLBASE="/var/lib/pterodactyl/volumes"
CFG="/etc/pterodactyl/config.yml"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1"; exit 1; }; }
say()  { printf '\n\e[1;36m%s\e[0m\n' "$*"; }

[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }

say "== Flash MyID Node Bootstrap + TLS + Adopt =="

# ---------- Base packages ----------
say "[+] Ensuring base packages..."
apt-get update -y
DEBS="ca-certificates curl tar unzip git redis-server gnupg lsb-release rsync jq"
apt-get install -y $DEBS || true

# ---------- Docker ----------
if ! command -v docker >/dev/null 2>&1; then
  say "[+] Installing Docker CE..."
  install -m 0755 -d /etc/apt/keyrings || true
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io
  systemctl enable --now docker
else
  say "[=] Docker already installed."
fi

# ---------- Wings ----------
if ! command -v wings >/dev/null 2>&1; then
  say "[+] Installing Wings..."
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64) W="wings_linux_amd64" ;;
    aarch64|arm64) W="wings_linux_arm64" ;;
    *)             W="wings_linux_amd64" ;;
  esac
  curl -L -o /usr/local/bin/wings "https://github.com/pterodactyl/wings/releases/latest/download/${W}"
  chmod +x /usr/local/bin/wings

  mkdir -p /etc/pterodactyl

  # Optional: fetch a starter config if missing (you can overwrite later with Panel-generated one)
  if [[ ! -f "$CFG" ]]; then
    read -rp "No /etc/pterodactyl/config.yml found. Download a starter config from your URL? [y/N]: " DL
    if [[ "${DL,,}" == "y" ]]; then
      read -rp "Enter config.yml URL: " CONFIG_URL
      curl -fL "$CONFIG_URL" -o "$CFG" || { echo "Download failed."; exit 1; }
    else
      echo "Create or paste your panel-generated config into $CFG later."
    fi
  fi

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
  systemctl enable --now wings || true
else
  say "[=] Wings already installed."
fi

# ---------- Ask domain & issue cert ----------
read -rp "Enter node domain (e.g. vip-running2.flash-myanmar.com): " DOMAIN
[[ -n "${DOMAIN:-}" ]] || { echo "Domain cannot be empty."; exit 1; }
say "[+] Domain: $DOMAIN"

if ! command -v certbot >/dev/null 2>&1; then
  say "[+] Installing certbot..."
  apt-get install -y certbot
fi

# Free port 80 if nginx is using it (for standalone HTTP-01)
NGINX_STOPPED=0
if ss -ltnp | grep -q ':80 '; then
  if systemctl is-active --quiet nginx; then
    say "[*] Port 80 busy by nginx — stopping temporarily for cert issuance..."
    systemctl stop nginx
    NGINX_STOPPED=1
  else
    echo "Port 80 in use by non-nginx process. Free it and re-run."; exit 1
  fi
fi

say "[+] Issuing/renewing cert for https://${DOMAIN} ..."
certbot certonly --standalone -d "${DOMAIN}" -m "${EMAIL}" --agree-tos -n --keep-until-expiring
CERT_DIR="${CERT_BASE}/${DOMAIN}"
[[ -f "${CERT_DIR}/fullchain.pem" && -f "${CERT_DIR}/privkey.pem" ]] || { echo "Cert not found in ${CERT_DIR}"; exit 1; }
say "[=] Certificate OK: ${CERT_DIR}"

# Bring nginx back if we stopped it only for issuance
[[ "$NGINX_STOPPED" -eq 1 ]] && systemctl start nginx || true

# ---------- Patch Wings config to use TLS + host ----------
if [[ -f "$CFG" ]]; then
  say "[?] Patch Wings ($CFG) to use domain + cert and restart wings?"
  read -rp "[Y/n]: " DO_PATCH; DO_PATCH=${DO_PATCH:-Y}
  if [[ "${DO_PATCH,,}" == "y" ]]; then
    cp -a "$CFG" "${CFG}.bak.$(date +%F_%H%M%S)"
    # Ensure ssl: block exists
    if ! grep -q '^ssl:' "$CFG"; then
      cat >>"$CFG" <<EOF

ssl:
  enabled: true
  cert: ${CERT_DIR}/fullchain.pem
  key: ${CERT_DIR}/privkey.pem
EOF
    fi
    sed -i "s|^host:.*|host: ${DOMAIN}|" "$CFG" || true
    sed -i "s|^panel_url:.*|panel_url: https://panel.flash-myanmar.com|" "$CFG" || true
    sed -i "s|^  enabled:.*|  enabled: true|" "$CFG" || true
    sed -i "s|^  cert:.*|  cert: ${CERT_DIR}/fullchain.pem|" "$CFG" || true
    sed -i "s|^  key:.*|  key:  ${CERT_DIR}/privkey.pem|" "$CFG" || true

    systemctl daemon-reload
    systemctl restart wings || true
    say "[=] Wings restarted."
  fi
else
  say "[!] No $CFG found — skipping Wings patch."
fi

# ---------- Discover old servers ----------
need docker; need rsync
say "== Discovering old servers on this node =="

declare -A UUID_PORTS
declare -A UUID_CIDS

# From containers (running or stopped)
for ID in $(docker ps -a -q); do
  UUID=$(docker inspect "$ID" --format '{{ index .Config.Labels "io.pterodactyl.server.uuid" }}' 2>/dev/null || true)
  [[ -z "$UUID" ]] && continue
  BIND=$(docker inspect "$ID" --format '{{json .HostConfig.PortBindings}}' 2>/dev/null || echo "{}")
  UUID_PORTS["$UUID"]="$BIND"
  UUID_CIDS["$UUID"]+="$ID "
done

# From volumes directory
if [[ -d "$VOLBASE" ]]; then
  while IFS= read -r d; do
    base=$(basename "$d")
    [[ "$base" =~ ^[0-9a-fA-F-]{36}$ ]] || continue
    : "${UUID_PORTS[$base]:={}}"
  done < <(find "$VOLBASE" -maxdepth 1 -mindepth 1 -type d)
fi

if [[ ${#UUID_PORTS[@]} -eq 0 ]]; then
  say "[=] No old UUIDs found under Docker/volumes. Nothing to adopt."
  exit 0
fi

printf "\n%-38s  %s\n" "OLD_UUID" "PORT_BINDINGS(json)"
echo "--------------------------------------------------------------------------------"
for U in "${!UUID_PORTS[@]}"; do
  printf "%-38s  %s\n" "$U" "${UUID_PORTS[$U]}"
done
echo
echo "For each OLD_UUID above that you want to adopt, enter its NEW_UUID (must already exist in Panel)."
echo "Leave NEW_UUID blank to skip that OLD_UUID."
echo

# ---------- Migrate OLD -> NEW ----------
for OLD in "${!UUID_PORTS[@]}"; do
  read -rp "NEW_UUID for OLD ${OLD}: " NEW
  if [[ -z "$NEW" ]]; then
    echo "Skipping ${OLD}."; continue
  fi

  OLDDIR="${VOLBASE}/${OLD}"
  NEWDIR="${VOLBASE}/${NEW}"

  if [[ ! -d "$NEWDIR" ]]; then
    echo "❌ NEW dir not found: $NEWDIR  (Create the server in Panel first!)"
    continue
  fi
  [[ -d "$OLDDIR" ]] || echo "⚠️  OLD dir not found: $OLDDIR (continuing)"

  say "== Adopting ${OLD} → ${NEW} =="

  # 1) Warm copy
  if [[ -d "$OLDDIR" ]]; then
    echo "➡️  Warm copy..."
    rsync -a --numeric-ids --info=progress2 "$OLDDIR/" "$NEWDIR/"
  fi

  # 2) Stop old containers
  if [[ -n "${UUID_CIDS[$OLD]:-}" ]]; then
    echo "➡️  Stopping old container(s): ${UUID_CIDS[$OLD]}"
    docker stop ${UUID_CIDS[$OLD]} || true
  else
    echo "ℹ️  No running containers for ${OLD}."
  fi

  # 3) Final sync
  if [[ -d "$OLDDIR" ]]; then
    echo "➡️  Final sync..."
    rsync -a --delete --numeric-ids "$OLDDIR/" "$NEWDIR/"
  fi

  # 4) Fix perms
  echo "➡️  Fixing permissions on NEW..."
  chown -R 988:988 "$NEWDIR" || true

  # 5) Remove old container(s)
  if [[ -n "${UUID_CIDS[$OLD]:-}" ]]; then
    echo "🗑  Removing old container(s): ${UUID_CIDS[$OLD]}"
    docker rm -f ${UUID_CIDS[$OLD]} || true
  fi

  # 6) Show old ports (info)
  PORTJSON="${UUID_PORTS[$OLD]}"
  echo "Old port bindings: ${PORTJSON}"

  # 7) Delete old data dir
  if [[ -d "$OLDDIR" ]]; then
    echo "🧹 Removing old data dir: $OLDDIR"
    rm -rf "$OLDDIR"
  fi

  # 8) Restart Docker to free any stale docker-proxy
  echo "🔄 Restarting Docker to free ports..."
  systemctl restart docker || true

  say "✅ Done mapping ${OLD} → ${NEW}"
done

say "All requested mappings processed."
echo "Start servers from the Panel and watch:  journalctl -u wings -f"
