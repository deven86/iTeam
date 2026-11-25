#!/bin/sh
# iTeam relay — install or update in one command (run on the server, Ubuntu 24.04):
#   curl -fsSL https://raw.githubusercontent.com/deven86/iTeam/main/relay/deploy/bootstrap.sh | sudo sh -s relay.iteamchat.in you@email.com
# Downloads the relay source from GitHub, builds it with the official Go toolchain,
# installs it and (re)starts it. Safe to run again for updates; settings and data are kept.
set -eu
DOMAIN="${1:?usage: ... | sudo sh -s <domain> <email>}"
EMAIL="${2:?usage: ... | sudo sh -s <domain> <email>}"
REPO="${REPO:-deven86/iTeam}"
BRANCH="${BRANCH:-main}"
GO_VERSION="${GO_VERSION:-1.24.7}"
[ "$(id -u)" = 0 ] || { echo "Run with sudo"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

echo "== Downloading iTeam relay source"
curl -fsSL "https://codeload.github.com/$REPO/tar.gz/refs/heads/$BRANCH" -o src.tgz \
  || { echo "Could not download the source. Is the GitHub repo public right now?"; exit 1; }
tar -xzf src.tgz
SRC=$(find . -maxdepth 2 -type d -name relay | head -1)
[ -n "$SRC" ] || { echo "relay folder not found in the download"; exit 1; }

echo "== Server setup (first time) / settings check"
sh "$SRC/deploy/install.sh" "$DOMAIN" "$EMAIL"

echo "== Building (official Go $GO_VERSION, only used for building)"
ARCH=$(dpkg --print-architecture)   # amd64 or arm64
curl -fsSL "https://go.dev/dl/go$GO_VERSION.linux-$ARCH.tar.gz" -o go.tgz
tar -xzf go.tgz
( cd "$SRC" && CGO_ENABLED=0 GOFLAGS=-mod=mod HOME="$WORK" GOCACHE="$WORK/cache" \
    "$WORK/go/bin/go" build -trimpath -ldflags "-s -w -X main.version=$(date -u +%Y%m%d-%H%M)" -o "$WORK/iteam-relay" . )

echo "== Installing and starting"
install -m 755 "$WORK/iteam-relay" /opt/iteam-relay/iteam-relay.next
mv /opt/iteam-relay/iteam-relay.next /opt/iteam-relay/iteam-relay
systemctl restart iteam-relay
sleep 8
if systemctl is-active --quiet iteam-relay; then
  echo
  echo "✅ iTeam relay is running."
  echo "Status page (keep private):"
  echo "  https://$DOMAIN/status?token=$(grep STATUS_TOKEN /etc/iteam-relay/relay.env | cut -d= -f2)"
else
  echo "❌ The relay did not start. Last log lines:"
  journalctl -u iteam-relay -n 30 --no-pager
  exit 1
fi
