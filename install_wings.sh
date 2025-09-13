#!/bin/bash
# bootstrap_and_adopt.sh (safe v2)
# - Install Docker & Wings
# - Run Panel "wings configure"
# - Issue Let's Encrypt for FQDN
# - Patch config.yml (api.ssl.* only)
# - Ensure SFTP host keys for Wings (owned by pterodactyl)
# - Optional OLD→NEW adoption

set -euo pipefail

EMAIL="chanmyaekozin@gmail.com"
BASE_DOMAIN="flash-myanmar.com"           # <— used to expand short names: game1 -> game1.flash-myanmar.com
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

# Wings systemd service (idempotent, run as root — Wings will drop to pterodactyl uid/gid per config)
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
systemctl enable --now wings || true   # ok if it fails before config exists

# ---------- Paste & run Panel-provided "wings configure" ----------
say "[?] Paste the EXACT line from Panel to configure this node (example:"
echo "    cd /etc/pterodactyl && sudo wings configure --panel-url https://panel.flash-myanmar.com --token XXXXX --node 15"
read -r -p "Paste here (or leave empty to skip): " CONFIG_CMD
if [[ -n "${CONFIG_CMD:-}" ]]; then
  say "[*] Running your configure command..."
  bash -lc "$CONFIG_CMD"
  say "[=] 'wings configure' finished."
else
  say "[=] Skipped 'wings configure' (make sure $CFG exists already)."
fi

# ---------- Ensure SFTP host keys exist & readable by pterodactyl ----------
ensure_sftp_keys() {
  local sshdir="/etc/pterodactyl/ssh"
  say "[+] Ensuring SFTP host keys in $sshdir ..."
  install -d -m 700 "$sshdir"

  # Try to chown to pterodactyl; if user not yet present, fallback to 999:986 (as in config.yml)
  if id -u pterodactyl >/dev/null 2>&1; then
    chown pterodactyl:pterodactyl "$sshdir"
  else
    chown 999:986 "$sshdir" || true
  fi

  [[ -f "$sshdir/ssh_host_ed25519_key" ]] || ssh-keygen -t ed25519 -f "$sshdir/ssh_host_ed25519_key" -N ""
  [[ -f "$sshdir/ssh_host_rsa_key"     ]] || ssh-keygen -t rsa -b 4096 -f "$sshdir/ssh_host_rsa_key" -N ""

  chmod 600 "$sshdir"/ssh_host_*_key
  chmod 644 "$sshdir"/ssh_host_*_key.pub

  # Ownership again (covers keys just created by root)
  if id -u pterodactyl >/dev/null 2>&1; then
    chown -R pterodactyl:pterodactyl "$sshdir"
  else
    chown -R 999:986 "$sshdir" || true
  fi
}
ensure_sftp_keys

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
  say "[+] Installing certbot..."
  apt-get install -y certbot
fi

# Free port 80 for standalone HTTP-01
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

[[ "$NGINX_STOPPED" -eq 1 ]] && systemctl start nginx || true

# ---------- Patch Wings config (api.ssl only; leave api.host=0.0.0.0) ----------
patch_api_ssl() {
  [[ -f "$CFG" ]] || { echo "Missing $CFG"; exit 1; }

  # Ensure an api.ssl block exists; if not, create it after '  port:'
  if ! awk '/^api:/{f=1}/^[^[:space:]]/{f=0} f&&/^\s{2}ssl:/{found=1} END{exit found?0:1}' "$CFG"; then
    say "[+] Inserting api.ssl block..."
    awk -v cert="$CERT_DIR/fullchain.pem" -v key="$CERT_DIR/privkey.pem" '
      BEGIN{inapi=0; done=0}
      /^api:/{inapi=1}
      /^[^[:space:]]/{if(inapi && !done){ /* fallthrough */ } inapi=0}
      {print}
      { if(inapi && !done && $0 ~ /^\s{2}port:/){
          print "  ssl:"
          print "    enabled: true"
          print "    cert: " cert
          print "    key: " key
          done=1
        }
      }
      END{if(!done && inapi){
        print "  ssl:"
        print "    enabled: true"
        print "    cert: " cert
        print "    key: " key
      }}
    ' "$CFG" > "${CFG}.tmp" && mv "${CFG}.tmp" "$CFG"
  fi

  # Update values strictly within api.ssl block
  sed -i -E "/^api:/,/^[^[:space:]]/ {
    /^\s{2}ssl:/,/^[^[:space:]]/ {
      s#^(\s{4})enabled:.*#\1enabled: true#;
      s#^(\s{4})cert:.*#\1cert: ${CERT_DIR}/fullchain.pem#;
      s#^(\s{4})key:.*#\1key: ${CERT_DIR}/privkey.pem#;
    }
  }" "$CFG"

  # Keep api.host as 0.0.0.0 (listen on all), do NOT set it to domain
  sed -i -E "/^api:/,/^[^[:space:]]/ { s#^(\s{2})host:.*#\1host: 0.0.0.0# }" "$CFG"
}
patch_api_ssl

# (Optional) explicitly set SFTP host_key_path under system.sftp (Wings defaults to /etc/pterodactyl/ssh)
ensure_sftp_path_key() {
  if ! awk '/^system:/{sys=1}/^[^[:space:]]/{if(sys&&!saw){} sys=0}
           sys&&/^\s{2}sftp:/{sftp=1}
           sys&&/^\s{2}[a-z]/{if(sftp&&!saw){} sftp=0}
           sftp&&/^\s{4}host_key_path:/{saw=1}
           END{exit saw?0:1}' "$CFG"; then
    say "[+] Adding system.sftp.host_key_path ..."
    awk '
      BEGIN{sys=0;sftp=0;done=0}
      /^system:/{sys=1}
      /^[^[:space:]]/{if(sys){sys=0}; if(sftp){sftp=0}}
      {print}
      { if(sys && /^\s{2}sftp:/ && !done){
          print "    host_key_path: /etc/pterodactyl/ssh"
          done=1
        }
      }
    ' "$CFG" > "${CFG}.tmp" && mv "${CFG}.tmp" "$CFG"
  fi
}
ensure_sftp_path_key

# ---------- Restart & show logs ----------
systemctl restart wings
sleep 1
journalctl -u wings -n 80 --no-pager || true

# ---------- OLD→NEW adoption (same as your original; trimmed a bit) ----------
need docker; need rsync
say "== Discovering old servers on this node =="

declare -A UUID_PORTS=()
declare -A UUID_CIDS=()

for ID in $(docker ps -a -q); do
  UUID=$(docker inspect "$ID" --format '{{ index .Config.Labels "io.pterodactyl.server.uuid" }}' 2>/dev/null || true)
  [[ -z "$UUID" ]] && continue
  BIND=$(docker inspect "$ID" --format '{{json .HostConfig.PortBindings}}' 2>/dev/null || echo "{}")
  UUID_PORTS["$UUID"]="$BIND"
  UUID_CIDS["$UUID"]+="$ID "
done

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

for OLD in "${!UUID_PORTS[@]}"; do
  read -rp "NEW_UUID for OLD ${OLD}: " NEW
  [[ -z "$NEW" ]] && { echo "Skipping ${OLD}."; continue; }

  OLDDIR="${VOLBASE}/${OLD}"
  NEWDIR="${VOLBASE}/${NEW}"

  if [[ ! -d "$NEWDIR" ]]; then
    echo "❌ NEW dir not found: $NEWDIR  (Create the server in Panel first!)"
    continue
  fi

  say "== Adopting ${OLD} → ${NEW} =="

  [[ -d "$OLDDIR" ]] && rsync -a --numeric-ids --info=progress2 "$OLDDIR/" "$NEWDIR/"

  if [[ -n "${UUID_CIDS[$OLD]:-}" ]]; then
    docker stop ${UUID_CIDS[$OLD]} || true
  fi

  [[ -d "$OLDDIR" ]] && rsync -a --delete --numeric-ids "$OLDDIR/" "$NEWDIR/"
  chown -R 988:988 "$NEWDIR" || true

  if [[ -n "${UUID_CIDS[$OLD]:-}" ]]; then
    docker rm -f ${UUID_CIDS[$OLD]} || true
  fi
  [[ -d "$OLDDIR" ]] && rm -rf "$OLDDIR"
  systemctl restart docker || true

  say "✅ Done mapping ${OLD} → ${NEW}"
done

say "All requested mappings processed."
echo "Start servers from the Panel and watch:  journalctl -u wings -f"
