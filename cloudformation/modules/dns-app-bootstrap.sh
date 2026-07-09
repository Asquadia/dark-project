#!/bin/bash
# App-instance DNS bootstrap: point /etc/resolv.conf at the BIND DNS servers
# that serve the nexusplay.lab zone (db, redis, game, player, alb).
# Called from EC2 user-data on game/player ASG instances.
set -e
BIND_PRIMARY="172.31.41.135"   # nexusplay-dns-secondary (physical primary in our setup)
BIND_SECONDARY="172.31.33.112" # nexusplay-dns-primary
BIND_TERTIARY="169.254.169.253" # VPC DNS fallback (forwarded by BIND)

cat > /etc/resolv.conf <<EOF
nameserver ${BIND_PRIMARY}
nameserver ${BIND_SECONDARY}
nameserver ${BIND_TERTIARY}
search ec2.internal
options timeout:3 attempts:2
EOF
chmod 644 /etc/resolv.conf
echo "resolv.conf updated to BIND DNS"
