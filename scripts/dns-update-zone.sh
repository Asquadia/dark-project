#!/bin/bash
# update-zone.sh — regenerate the nexusplay.lab zone from live AWS resource discovery.
# Runs on the BIND PRIMARY only. Discovers: dns EC2 (by tag), app EC2 (by Component tag),
# ElastiCache (by replication-group-id), RDS (by db-instance-id), ALB (by name).
# Writes the zone file and reloads BIND. Idempotent; safe to run every minute via cron.
set -u
ZONE="${NP_ZONE:-nexusplay.lab}"
VPC_CIDR="${NP_VPC_CIDR:-172.31.0.0/16}"
CACHE_RG="${NP_CACHE_RG:-nexusplay-redis}"
DB_ID="${NP_DB_ID:-nexusplay-db}"
ALB_NAME="${NP_ALB_NAME:-nexusplay-alb}"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
ZONEFILE="/var/named/nexusplay.lab.zone"
SERIAL="$(date +%Y%m%d%H%M%S)"
# SOA serial must fit in 32 bits (4294967295). Clamp by taking mod 2^32
# so that even after the year 2038 we keep producing valid serials.
SERIAL="$((SERIAL % 4294967295))"
[ "$SERIAL" -eq 0 ] && SERIAL=1

# AWS CLI uses the instance role (IMDS) — no credentials needed.
export AWS_DEFAULT_REGION="$REGION"

die() { echo "[update-zone] ERROR: $*" >&2; exit 1; }

# --- Discover EC2 instances by Project tag ---
EC2_JSON="$(aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=NexusPlay" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[PrivateIpAddress,Tags]' --output json 2>/dev/null)" || EC2_JSON="[]"

dns_a=""      # dns-primary / dns-secondary A records
game_a=""     # game.nexusplay.lab round-robin
player_a=""   # player.nexusplay.lab round-robin
for row in $(echo "$EC2_JSON" | jq -c '.[]'); do
  ip="$(echo "$row" | jq -r '.[0]')"
  [ "$ip" = "null" ] && continue
  name="$(echo "$row" | jq -r '.[1][]? | select(.Key=="Name").Value // empty')"
  comp="$(echo "$row" | jq -r '.[1][]? | select(.Key=="Component").Value // empty')"
  case "$name" in
    nexusplay-dns-primary)   dns_a="${dns_a}dns-primary   IN A ${ip}\n" ;;
    nexusplay-dns-secondary) dns_a="${dns_a}dns-secondary IN A ${ip}\n" ;;
  esac
  case "$comp" in
    game-service)   game_a="${game_a}game   IN A ${ip}\n" ;;
    player-service) player_a="${player_a}player IN A ${ip}\n" ;;
  esac
done

# --- Discover ElastiCache primary endpoint (if it exists) ---
redis_cname=""
RG_JSON="$(aws elasticache describe-replication-groups --replication-group-id "$CACHE_RG" --query 'ReplicationGroups[0].NodeGroups[0].PrimaryEndpoint.Address' --output text 2>/dev/null)" || RG_JSON=""
if [ -n "$RG_JSON" ] && [ "$RG_JSON" != "None" ] && [ "$RG_JSON" != "null" ]; then
  redis_cname="redis IN CNAME ${RG_JSON}."
fi

# --- Discover RDS endpoint (if it exists) ---
db_cname=""
DB_EP="$(aws rds describe-db-instances --db-instance-identifier "$DB_ID" --query 'DBInstances[0].Endpoint.Address' --output text 2>/dev/null)" || DB_EP=""
if [ -n "$DB_EP" ] && [ "$DB_EP" != "None" ]; then
  db_cname="db IN CNAME ${DB_EP}."
fi

# --- Discover ALB DNS (if it exists) ---
app_cname=""
ALB_DNS="$(aws elbv2 describe-load-balancers --names "$ALB_NAME" --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null)" || ALB_DNS=""
if [ -n "$ALB_DNS" ] && [ "$ALB_DNS" != "None" ]; then
  app_cname="app IN CNAME ${ALB_DNS}."
fi

# --- Write the zone file ---
TMP="${ZONEFILE}.tmp"
{
  echo "\$TTL 60"
  echo "@   IN SOA dns-primary.${ZONE}. admin.${ZONE}. ( ${SERIAL} 60 60 604800 60 )"
  echo "@              IN NS  dns-primary.${ZONE}."
  echo "@              IN NS  dns-secondary.${ZONE}."
  printf '%b' "$dns_a"
  [ -n "$redis_cname" ]  && echo "$redis_cname"
  [ -n "$db_cname" ]     && echo "$db_cname"
  [ -n "$app_cname" ]    && echo "$app_cname"
  printf '%b' "$game_a"
  printf '%b' "$player_a"
} > "$TMP"

# Only reload if the zone actually changed (avoid needless reload spam).
if [ -f "$ZONEFILE" ] && diff -q "$ZONEFILE" "$TMP" >/dev/null 2>&1; then
  rm -f "$TMP"
  echo "[update-zone] no change"
  exit 0
fi
mv "$TMP" "$ZONEFILE"
chgrp named "$ZONEFILE" 2>/dev/null || true
chmod 640 "$ZONEFILE" 2>/dev/null || true
rndc reload "${ZONE}" 2>/dev/null || systemctl reload named 2>/dev/null || systemctl restart named
echo "[update-zone] zone updated serial=${SERIAL}"