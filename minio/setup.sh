#!/usr/bin/env bash
# Single-node MinIO on a fixed-size ext4 loopback volume, bound only to a Tailscale IP.
#
# Usage: sudo [TS_AUTHKEY=tskey-auth-...] bash setup.sh <name> <size> [tailscale-ip]
#   name          Tailscale hostname + volume name, e.g. minio-vps
#   size          volume size: 1.2T, 500G (SI) or 2Ti (IEC)
#   tailscale-ip  use this 100.x.y.z; omit to install/join Tailscale and detect it
set -Eeuo pipefail
umask 027
die() { echo "ERROR: $*" >&2; exit 1; }
trap 'die "failed at line $LINENO"' ERR

(( $# >= 2 )) || die "usage: sudo bash $0 <name> <size> [tailscale-ip]"
(( EUID == 0 )) || die "run as root"
NAME=$1 SIZE=$2 IP=${3:-}
[[ $NAME =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || die "name: lowercase letters, digits, dashes"
BYTES=$(numfmt --from=auto "$SIZE") || die "bad size: $SIZE"
DATA=/srv/$NAME VOL=/var/lib/minio-volume/$NAME.ext4 ENVF=/etc/minio/credentials.env

export DEBIAN_FRONTEND=noninteractive
if command -v apt-get >/dev/null; then apt-get update -q; apt-get install -yq curl e2fsprogs openssl
else dnf install -y curl e2fsprogs openssl; fi

if [[ -z $IP ]]; then
  command -v tailscale >/dev/null || curl -fsSL https://tailscale.com/install.sh | sh
  systemctl enable --now tailscaled
  tailscale ip -4 &>/dev/null || tailscale up --hostname="$NAME" ${TS_AUTHKEY:+--auth-key="$TS_AUTHKEY"}
  IP=$(tailscale ip -4)
fi
[[ $IP =~ ^100\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "not a Tailscale IPv4: $IP"

# UDP 41641 improves odds of a direct (non-DERP) path; MinIO ports stay tailnet-only.
if ufw status 2>/dev/null | grep -q 'Status: active'; then
  ufw allow 41641/udp; ufw allow in on tailscale0 to any port 9000:9001 proto tcp
elif firewall-cmd --state &>/dev/null; then
  firewall-cmd --permanent --add-port=41641/udp; firewall-cmd --reload
fi

install -d -m 0700 "${VOL%/*}"; install -d "$DATA"
if [[ -e $VOL ]]; then
  [[ $(stat -c %s "$VOL") == "$BYTES" ]] || die "$VOL exists with a different size; refusing to resize"
else
  free=$(df -B1 --output=avail "${VOL%/*}" | tail -n1)
  (( free >= BYTES + 50000000000 )) || die "need $SIZE + 50G headroom, only $free bytes free"
  fallocate -l "$BYTES" "$VOL"; chmod 0600 "$VOL"
  mkfs.ext4 -q -F -m 0 -T largefile -L "${NAME:0:16}" "$VOL"
fi
grep -q " $DATA ext4 " /etc/fstab || echo "$VOL $DATA ext4 loop,noatime 0 2" >> /etc/fstab
systemctl daemon-reload
mountpoint -q "$DATA" || mount "$DATA"

id minio &>/dev/null || useradd --system --user-group --home-dir /nonexistent --shell /usr/sbin/nologin minio
chown minio:minio "$DATA"; chmod 0750 "$DATA"

case $(uname -m) in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; *) die "unsupported arch $(uname -m)" ;; esac
url=https://dl.min.io/community/server/minio/release/linux-$arch/minio
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
curl -fL --retry 3 -o "$tmp/minio" "$url"
echo "$(curl -fsSL "$url.sha256sum" | cut -d' ' -f1)  $tmp/minio" | sha256sum -c --quiet
install -m 0755 "$tmp/minio" /usr/local/bin/minio

# Reuse existing root credentials on re-run; otherwise generate them.
install -d -m 0750 -o root -g minio /etc/minio
creds=$(grep -hs '^MINIO_ROOT_' /etc/minio/*.env) || creds="MINIO_ROOT_USER=storage-admin
MINIO_ROOT_PASSWORD=$(openssl rand -hex 24)"
echo "$creds" > "$ENVF"; chown root:minio "$ENVF"; chmod 0640 "$ENVF"

# ponytail: no wait-for-Tailscale launcher; bind fails until the IP exists and systemd retries forever.
cat > /etc/systemd/system/minio.service <<EOF
[Unit]
Description=MinIO ($NAME) on Tailscale $IP
Wants=network-online.target
After=network-online.target tailscaled.service
RequiresMountsFor=$DATA
StartLimitIntervalSec=0

[Service]
Type=notify
User=minio
Group=minio
EnvironmentFile=$ENVF
Environment=MINIO_BROWSER_REDIRECT_URL=http://$IP:9001
ExecStart=/usr/local/bin/minio server --address $IP:9000 --console-address $IP:9001 $DATA
Restart=always
RestartSec=2s
LimitNOFILE=1048576
TasksMax=infinity
TimeoutStopSec=infinity
SendSIGKILL=no
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=$DATA

[Install]
WantedBy=multi-user.target
EOF

# Larger socket buffers for high-bandwidth, higher-latency Tailscale paths.
cat > /etc/sysctl.d/90-minio-tailnet.conf <<'EOF'
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 65535
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.ipv4.tcp_mtu_probing = 1
fs.file-max = 2097152
EOF
sysctl --system >/dev/null

systemctl daemon-reload; systemctl enable minio; systemctl restart minio  # restart applies unit changes on re-run
for i in {1..30}; do
  curl -fs --max-time 2 "http://$IP:9000/minio/health/live" >/dev/null && break
  (( i < 30 )) || die "MinIO not healthy; see: journalctl -u minio"
  sleep 1
done

cat <<EOF

MinIO ($NAME) is up, tailnet-only.
  S3:       http://$IP:9000
  Console:  http://$IP:9001
  Storage:  $SIZE at $DATA (backing file $VOL)
$creds
Throughput: allow UDP 41641 at the provider firewall; 'tailscale ping $IP' should go direct, not DERP.
EOF
