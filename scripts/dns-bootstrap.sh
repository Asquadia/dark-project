#!/bin/bash
# dns-bootstrap.sh — installed on each BIND instance.
# Configures either the PRIMARY (master) or SECONDARY (slave) based on $NP_ROLE.
# Discovered via environment: NP_ROLE in {primary,secondary}, NP_ZONE, NP_VPC_CIDR,
# NP_FORWARDER, NP_CACHE_RG, NP_DB_ID, NP_ALB_NAME.
set -eu
ROLE="${NP_ROLE:?ROLE required (primary|secondary)}"
ZONE="${NP_ZONE:-nexusplay.lab}"
VPC_CIDR="${NP_VPC_CIDR:-172.31.0.0/16}"
FORWARDER="${NP_FORWARDER:-169.254.169.253}"
CACHE_RG="${NP_CACHE_RG:-nexusplay-redis}"
DB_ID="${NP_DB_ID:-nexusplay-db}"
ALB_NAME="${NP_ALB_NAME:-nexusplay-alb}"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$REGION"

# Allow named to write slave zone files.
mkdir -p /var/named/slaves
chown -R named:named /var/named 2>/dev/null || true

write_options() {
  cat > /etc/named.conf <<EOF
options {
    directory "/var/named";
    recursion yes;
    allow-recursion { 127.0.0.1; ${VPC_CIDR}; };
    allow-query     { 127.0.0.1; ${VPC_CIDR}; };
    allow-transfer  { ${VPC_CIDR}; };
    forwarders      { ${FORWARDER}; };
    forward         only;
    dnssec-validation no;
    listen-on port 53 { any; };
    listen-on-v6 { none; };
    notify yes;
    empty-zones-enable no;
};
EOF
}

if [ "$ROLE" = "primary" ]; then
  write_options
  cat >> /etc/named.conf <<EOF
zone "${ZONE}" {
    type master;
    file "nexusplay.lab.zone";
    allow-transfer { ${VPC_CIDR}; };
};
EOF
elif [ "$ROLE" = "secondary" ]; then
  # Discover primary IP by Name tag.
  PRIMARY_IP="$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=nexusplay-dns-primary" "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text 2>/dev/null || true)"
  if [ -z "$PRIMARY_IP" ] || [ "$PRIMARY_IP" = "None" ]; then
    echo "[bootstrap] FATAL: could not find primary IP" >&2
    exit 1
  fi
  echo "${PRIMARY_IP}" > /etc/nexusplay-primary-ip
  write_options
  cat >> /etc/named.conf <<EOF
zone "${ZONE}" {
    type slave;
    file "slaves/nexusplay.lab.zone";
    masters { ${PRIMARY_IP}; };
    allow-transfer { ${VPC_CIDR}; };
};
EOF
else
  echo "[bootstrap] FATAL: unknown role ${ROLE}" >&2
  exit 1
fi

# Enable and start named now.
systemctl enable named

# PRIMARY: write the initial zone BEFORE starting named, so the master file exists.
if [ "$ROLE" = "primary" ]; then
  install -m 0755 /opt/nexusplay-dns/update-zone.sh /usr/local/bin/nexusplay-update-zone
  /usr/local/bin/nexusplay-update-zone || true
fi

systemctl restart named || systemctl start named
sleep 2

# Install the zone-update cron on the PRIMARY only.
if [ "$ROLE" = "primary" ]; then
  cat > /etc/cron.d/nexusplay-update-zone <<'CRON'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/1 * * * * root /usr/local/bin/nexusplay-update-zone >> /var/log/nexusplay-dns.log 2>&1
CRON
  chmod 0644 /etc/cron.d/nexusplay-update-zone
  crond 2>/dev/null || true
fi

# Secondary: re-check primary IP every minute and reload if it changed.
if [ "$ROLE" = "secondary" ]; then
  cat > /usr/local/bin/nexusplay-rewatch-primary <<'WATCH'
#!/bin/bash
export AWS_DEFAULT_REGION=us-east-1
NEW="$(aws ec2 describe-instances \
  --filters 'Name=tag:Name,Values=nexusplay-dns-primary' 'Name=instance-state-name,Values=running' \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text 2>/dev/null || true)"
OLD="$(cat /etc/nexusplay-primary-ip 2>/dev/null || true)"
if [ -n "$NEW" ] && [ "$NEW" != "None" ] && [ "$NEW" != "$OLD" ]; then
  echo "$NEW" > /etc/nexusplay-primary-ip
  sed -i "s/masters { [^}]* };/masters { $NEW };/" /etc/named.conf
  systemctl reload named || systemctl restart named
  echo "[rewatch] primary IP changed: $OLD -> $NEW" >> /var/log/nexusplay-dns.log
fi
WATCH
  chmod 0755 /usr/local/bin/nexusplay-rewatch-primary
  cat > /etc/cron.d/nexusplay-rewatch <<'CRON2'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/1 * * * * root /usr/local/bin/nexusplay-rewatch-primary >> /var/log/nexusplay-dns.log 2>&1
CRON2
  chmod 0644 /etc/cron.d/nexusplay-rewatch
  crond 2>/dev/null || true
fi

echo "[bootstrap] ${ROLE} ready"