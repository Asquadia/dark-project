#!/bin/bash
# deploy.sh — Operator-runnable equivalent of the GitHub Actions deploy.yml workflow.
# Builds, pushes, rotates the launch template version, and triggers an ASG rolling refresh.
# Usage: source ./setenv.sh && bash scripts/deploy.sh [service] [tag]
# Example: bash scripts/deploy.sh player-service v3
set -eu
SERVICE="${1:-player-service}"
TAG="${2:-$(git -C "$(dirname "$0")/.." rev-parse --short HEAD 2>/dev/null || echo latest)}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
REG="${ACCOUNT}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com"
IMG="${REG}/nexusplay/${SERVICE}:${TAG}"

echo "== docker login ECR =="
aws ecr get-login-password --region "${AWS_DEFAULT_REGION}" \
  | docker login --username AWS --password-stdin "${REG}"

echo "== build ${SERVICE} ${TAG} =="
docker build -t "${IMG}" -f "services/${SERVICE}/Dockerfile" services

echo "== push =="
docker push "${IMG}"

case "${SERVICE}" in
  game-service)    LT=nexusplay-game-lt;    ASG=nexusplay-game-asg    ;;
  player-service)  LT=nexusplay-player-lt;  ASG=nexusplay-player-asg  ;;
  *) echo "unknown service: ${SERVICE}" >&2; exit 1 ;;
esac

echo "== create launch template version ${LT} =="
NEW_USERDATA=$(printf '#!/bin/bash\nset -x\nmkdir -p /opt/nexusplay-app\naws s3 cp s3://nexusplay-artifacts-534883687114-us-east-1/app/bootstrap.sh /opt/nexusplay-app/app-bootstrap.sh --region %s\nchmod +x /opt/nexusplay-app/app-bootstrap.sh\nexport NP_SERVICE=%s\nexport NP_APP_PORT=8000\nexport AWS_ACCOUNT_ID=%s\nexport NP_IMAGE_TAG=%s\nexport NP_VERSION=%s\nbash /opt/nexusplay-app/app-bootstrap.sh > /var/log/nexusplay-app-bootstrap.log 2>&1 || true' \
  "${AWS_DEFAULT_REGION}" "${SERVICE}" "${ACCOUNT}" "${TAG}" "${TAG}" | base64 -w0)
NEW_VER=$(aws ec2 create-launch-template-version \
  --launch-template-name "${LT}" \
  --version-description "${SERVICE} @ ${TAG}" \
  --source-version '$Latest' \
  --launch-template-data "{\"UserData\":\"${NEW_USERDATA}\"}" \
  --query 'LaunchTemplateVersion.VersionNumber' --output text)
echo "new ${LT} version=${NEW_VER}"

echo "== set default version =="
aws ec2 modify-launch-template --launch-template-name "${LT}" --default-version "${NEW_VER}" >/dev/null

echo "== point ASG at new version =="
LT_ID=$(aws ec2 describe-launch-templates --launch-template-names "${LT}" --query 'LaunchTemplates[0].LaunchTemplateId' --output text)
aws autoscaling update-auto-scaling-group --auto-scaling-group-name "${ASG}" \
  --launch-template "LaunchTemplateId=${LT_ID},Version=${NEW_VER}"

echo "== instance refresh (rolling) =="
aws autoscaling start-instance-refresh --auto-scaling-group-name "${ASG}" \
  --preferences MinHealthyPercentage=50,InstanceWarmup=300

echo "== done. Watching =="
aws autoscaling describe-instance-refreshes --auto-scaling-group-name "${ASG}" \
  --query 'InstanceRefreshes[0].[Status,PercentageComplete]' --output text