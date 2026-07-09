#!/bin/bash
# scripts/game-deploy.sh — Operator-runnable equivalent of .github/workflows/game.yml.
# Lets you deploy the game service from your laptop without GitHub Actions.
#
#   1. Builds services/game-service into a Docker image
#   2. Tags it with the given tag (default: git short SHA) + :latest
#   3. Pushes to GHCR (ghcr.io/<owner>/game-service) — canonical source
#   4. Mirrors the same image to ECR (lab instances pull from here — private subnet, no internet)
#   5. Tells every running nexusplay-game-* instance via SSM to pull + restart from ECR
#
# Requirements:
#   - source ./setenv.sh          # exports AWS env, sets AWS_PROFILE
#   - docker                      # local
#   - gh auth login               # so docker can push to ghcr.io as you
#   - GH_OWNER=<gh user/org>      # exported by this script or the env
#
# Usage:
#   bash scripts/game-deploy.sh                         # tag = git short SHA
#   bash scripts/game-deploy.sh latest                  # tag = latest (overwrites)
#   bash scripts/game-deploy.sh v4                      # tag = v4
#   GH_OWNER=my-org bash scripts/game-deploy.sh latest

set -euo pipefail

GH_OWNER="${GH_OWNER:-}"            # GitHub user/org that owns the ghcr.io package
TAG="${1:-$(git rev-parse --short HEAD 2>/dev/null || echo latest)}"
SERVICE="game-service"
GHCR_REGISTRY="ghcr.io/${GH_OWNER}/game-service"
AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-534883687114}"
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
ECR_IMAGE="${ECR_REGISTRY}/nexusplay/${SERVICE}"
ARTIFACTS_BUCKET="nexusplay-artifacts-${AWS_ACCOUNT_ID}-${AWS_REGION}"

if [ -z "${GH_OWNER}" ]; then
  echo "GH_OWNER not set. Export it first:  export GH_OWNER=your-gh-user" >&2
  exit 1
fi

echo "== tag:     ${TAG} =="
echo "== GHCR:    ${GHCR_REGISTRY}:${TAG} (canonical) =="
echo "== ECR:     ${ECR_IMAGE}:${TAG} (lab mirror) =="
echo

# ── 1. Build ────────────────────────────────────────────────────────────────────
echo "[1/5] build"
docker build \
  -t "${GHCR_REGISTRY}:${TAG}" \
  -t "${GHCR_REGISTRY}:latest" \
  -f services/${SERVICE}/Dockerfile \
  services

# ── 2. Push to GHCR ─────────────────────────────────────────────────────────────
echo "[2/5] push to GHCR (uses your local gh auth)"
docker push "${GHCR_REGISTRY}:${TAG}"
docker push "${GHCR_REGISTRY}:latest"

# ── 3. Mirror to ECR ────────────────────────────────────────────────────────────
echo "[3/5] mirror to ECR (lab instances pull from here)"
aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${ECR_REGISTRY}"
docker tag "${GHCR_REGISTRY}:${TAG}" "${ECR_IMAGE}:${TAG}"
docker tag "${GHCR_REGISTRY}:${TAG}" "${ECR_IMAGE}:latest"
docker push "${ECR_IMAGE}:${TAG}"
docker push "${ECR_IMAGE}:latest"

# ── 4. Discover game instances ──────────────────────────────────────────────────
echo "[4/5] discover game instances"
mapfile -t INSTANCES < <(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=nexusplay-game-*" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[*].Instances[*].InstanceId' --output text \
  | tr '\t' ' ')

if [ "${#INSTANCES[@]}" -eq 0 ]; then
  echo "no running game instances found" >&2
  exit 1
fi
echo "    instances: ${INSTANCES[*]}"

# ── 5. SSM deploy (pull from ECR + restart) ─────────────────────────────────────
echo "[5/5] SSM deploy (pull from ECR + restart)"

# Upload the restart script (no secrets in it — uses instance's own ECR read role)
cat > /tmp/restart-game.sh <<'SCRIPT'
#!/bin/bash
set -eu
IMAGE_TAG="${1:?usage: restart-game.sh <image_tag>}"
REGION="${AWS_REGION:-us-east-1}"
REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
IMAGE="${REGISTRY}/nexusplay/game-service:${IMAGE_TAG}"

echo "[deploy] image=${IMAGE}"
aws ecr get-login-password --region "${REGION}" \
  | docker login --username AWS --password-stdin "${REGISTRY}"

docker pull "${IMAGE}"

docker rm -f nexusplay-game-service 2>/dev/null || true
docker run -d --restart=always --name nexusplay-game-service \
  --env REDIS_HOST=redis.nexusplay.lab \
  --env REDIS_PORT=6379 \
  --env DB_HOST=db.nexusplay.lab \
  --env DB_PORT=5432 \
  --env DB_USER=nexusplay \
  --env DB_NAME=postgres \
  --env AWS_DEFAULT_REGION="${REGION}" \
  -p 8000:8000 \
  "${IMAGE}"

docker ps --filter name=nexusplay-game-service --format '{{.Image}} {{.Status}}'
SCRIPT
aws s3 cp /tmp/restart-game.sh "s3://${ARTIFACTS_BUCKET}/game/restart-game.sh"

for INSTANCE in "${INSTANCES[@]}"; do
  echo "    -> ${INSTANCE}"
  CMD_ID=$(aws ssm send-command \
    --instance-ids "${INSTANCE}" \
    --document-name "AWS-RunShellScript" \
    --timeout-seconds 180 \
    --parameters "{\"commands\":[\"aws s3 cp s3://${ARTIFACTS_BUCKET}/game/restart-game.sh /tmp/restart-game.sh\",\"AWS_REGION=${AWS_REGION} AWS_ACCOUNT_ID=${AWS_ACCOUNT_ID} bash /tmp/restart-game.sh ${TAG}\"]}" \
    --query 'Command.CommandId' --output text)
  echo "       cmd=${CMD_ID}"
done

echo
echo "== done. ${SERVICE}:${TAG} deployed to ${#INSTANCES[@]} instance(s). =="
echo "    GHCR: ${GHCR_REGISTRY}:${TAG}"
echo "    ECR : ${ECR_IMAGE}:${TAG}"