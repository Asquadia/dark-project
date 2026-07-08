#!/bin/bash
# app-bootstrap.sh — runs on each app instance via Launch Template user-data.
# Installs Docker, points the resolver at BIND, logs into ECR (via VPC endpoint),
# pulls the service image and runs it. SERVICE env selects game|player.
set -eu
SERVICE="${NP_SERVICE:?NP_SERVICE required (game-service|player-service)}"
export AWS_DEFAULT_REGION="${AWS_REGION:-us-east-1}"
APP_PORT="${NP_APP_PORT:-8000}"

# --- 1. Point the resolver at the BIND DNS servers (so redis/db/app resolve). ---
P_IP="$(aws ec2 describe-instances \
  --filters 'Name=tag:Name,Values=nexusplay-dns-primary' 'Name=instance-state-name,Values=running' \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text 2>/dev/null || true)"
S_IP="$(aws ec2 describe-instances \
  --filters 'Name=tag:Name,Values=nexusplay-dns-secondary' 'Name=instance-state-name,Values=running' \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text 2>/dev/null || true)"
rm -f /etc/resolv.conf
cat > /etc/resolv.conf <<EOF
nameserver ${P_IP}
nameserver ${S_IP}
nameserver 169.254.169.253
search ec2.internal
EOF
chattr +i /etc/resolv.conf 2>/dev/null || true

# --- 2. Install Docker. ---
dnf -y install docker
systemctl enable --now docker

# --- 3. Log in to ECR via the ecr.dkr VPC endpoint. ---
REG="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com"
aws ecr get-login-password --region "${AWS_DEFAULT_REGION}" | docker login --username AWS --password-stdin "${REG}"

# --- 4. Pull and run the service container. ---
TAG="${NP_IMAGE_TAG:-v1}"
IMAGE="${REG}/nexusplay/${SERVICE}:${TAG}"
docker pull "${IMAGE}"
docker run -d --restart=always --name nexusplay-${SERVICE} \
  --env REDIS_HOST=redis.nexusplay.lab \
  --env REDIS_PORT=6379 \
  --env DB_HOST=db.nexusplay.lab \
  --env DB_PORT=5432 \
  --env DB_USER=nexusplay \
  --env DB_NAME=postgres \
  --env AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION}" \
  --env NP_VERSION="${NP_VERSION:-${TAG}}" \
  --env NP_BUILD="${NP_BUILD:-local}" \
  -p ${APP_PORT}:${APP_PORT} \
  "${IMAGE}"

echo "[bootstrap] ${SERVICE} container started (tag ${TAG})"