#!/bin/sh
# iTeam relay — one-time server setup (Ubuntu 22.04/24.04, e.g. AWS Lightsail Mumbai).
# Run once in the Lightsail browser terminal:   sudo sh install.sh relay.yourdomain.com you@email.com
# It prepares the server; the program itself arrives from GitHub (relay.yml) and updates the same way.
set -eu
DOMAIN="${1:?usage: sudo sh install.sh <domain> <email>}"
EMAIL="${2:?usage: sudo sh install.sh <domain> <email>}"
[ "$(id -u)" = 0 ] || { echo "Run with sudo"; exit 1; }

echo "== Security updates (automatic from now on)"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unattended-upgrades ufw >/dev/null
dpkg-reconfigure -f noninteractive unattended-upgrades

echo "== Firewall: only SSH, HTTP (certificate) and HTTPS"
ufw allow 22/tcp >/dev/null; ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null
ufw --force enable >/dev/null

echo "== Folders"
id iteam >/dev/null 2>&1 || useradd --system --home /var/lib/iteam-relay --shell /usr/sbin/nologin iteam
install -d -o iteam -g iteam -m 700 /var/lib/iteam-relay
install -d -m 755 /opt/iteam-relay
install -d -o root -g iteam -m 750 /etc/iteam-relay

if [ ! -f /etc/iteam-relay/relay.env ]; then
  STATUS=$(head -c 18 /dev/urandom | base64 | tr '+/' '-_')
  BACKUP=$(head -c 32 /dev/urandom | base64)
  cat > /etc/iteam-relay/relay.env <<EOF
RELAY_DOMAIN=$DOMAIN
ACME_EMAIL=$EMAIL
RELAY_DATA=/var/lib/iteam-relay
APPLE_AUDIENCES=com.jondhale.iteam
GOOGLE_AUDIENCES=
APNS_KEY_FILE=
APNS_KEY_ID=
APNS_TEAM_ID=
APNS_TOPIC=com.jondhale.iteam
FCM_SERVICE_ACCOUNT=
STATUS_TOKEN=$STATUS
BACKUP_KEY=$BACKUP
EOF
  chown root:iteam /etc/iteam-relay/relay.env; chmod 640 /etc/iteam-relay/relay.env
fi

cat > /etc/systemd/system/iteam-relay.service <<'EOF'
[Unit]
Description=iTeam relay
After=network-online.target
Wants=network-online.target

[Service]
User=iteam
Group=iteam
EnvironmentFile=/etc/iteam-relay/relay.env
ExecStart=/opt/iteam-relay/iteam-relay
Restart=always
RestartSec=3
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/var/lib/iteam-relay
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable iteam-relay >/dev/null 2>&1 || true
[ -x /opt/iteam-relay/iteam-relay ] && systemctl restart iteam-relay || true

echo
echo "Done. Keep this private status link (open it on your phone once the relay is running):"
echo "  https://$DOMAIN/status?token=$(grep STATUS_TOKEN /etc/iteam-relay/relay.env | cut -d= -f2)"
echo "Backup key is in /etc/iteam-relay/relay.env — copy it somewhere safe (e.g. your password manager)."
