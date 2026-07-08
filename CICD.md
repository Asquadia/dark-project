# CI/CD — GitHub Actions to NexusPlay

The repo's `.github/workflows/deploy.yml` builds the FastAPI services on every push
to `main` (when `services/**` or the workflow file changes), pushes the images
to ECR with a short SHA tag, creates a new launch-template version, and triggers
an ASG instance refresh for a rolling deploy.

## What's automated

| Step                          | How                                                         |
|-------------------------------|-------------------------------------------------------------|
| Build game-service image      | `docker build -f services/game-service/Dockerfile`          |
| Build player-service image    | `docker build -f services/player-service/Dockerfile`        |
| Push to ECR                   | `aws-actions/amazon-ecr-login@v2` + `docker push`          |
| Rotate launch template        | `aws ec2 create-launch-template-version` + `modify-launch-template --default-version` |
| Update ASG to new LT version  | `aws autoscaling update-auto-scaling-group --launch-template` |
| Rolling deploy                | `aws autoscaling start-instance-refresh`                    |

## One-time setup (account admin)

The workflow authenticates to AWS via **GitHub OIDC**, which avoids storing long-lived
access keys in GitHub. The OIDC trust + the deploy role are provisioned by
`cloudformation/110-github-oidc.yaml`:

```bash
# As an account admin (requires iam:CreateRole + iam:CreateOpenIDConnectProvider):
source ./setenv.sh
aws cloudformation deploy --stack-name nexusplay-110-github-oidc \
  --template-file cloudformation/110-github-oidc.yaml \
  --capabilities CAPABILITY_NAMED_IAM

# Note the role ARN from the stack outputs, then add it as a GitHub Actions secret:
#   AWS_DEPLOY_ROLE_ARN = <DeployRole.Arn output>
# (Settings → Secrets and variables → Actions → New repository secret)
```

In a CI-restricted environment (e.g. the Voclabs AWS Academy sandbox used for this POC),
`iam:Create*` is denied for the student user, so the OIDC role cannot be provisioned by
the deploy script. The pipeline artefacts (workflow + role template + helper `scripts/deploy.sh`)
are committed and ready; an account admin runs the one command above to enable CI/CD.

## Operator fallback — `scripts/deploy.sh`

When the CI role is not available (or you want a manual deploy from your workstation),
`scripts/deploy.sh` does the same thing with the credentials you already have:

```bash
source ./setenv.sh
bash scripts/deploy.sh player-service v3    # build + push + rolling deploy
```

The script assumes `scripts/app-bootstrap.sh` is already uploaded to S3 and the
`nexusplay-*` launch templates + ASGs exist.

## Pipeline architecture

```
   ┌──────────────┐  OIDC    ┌──────────────────────────┐  push   ┌─────────────────┐
   │ GitHub       │ token →  │ IAM Role                 │ ──────► │ ECR             │
   │ Actions      │          │ nexusplay-github-deploy  │         │ nexusplay/      │
   │ (ubuntu-ltr) │          │ (least-priv: ECR push,   │         │  game-service   │
   │              │          │  LT update, ASG refresh)  │         │  player-service │
   └──────────────┘          └──────────────────────────┘         └─────────────────┘
                                                                       │
                                                            docker pull on each instance
                                                                       ▼
                                                            ┌────────────────────────┐
                                                            │ Launch Templates       │
                                                            │  nexusplay-game-lt v2  │
                                                            │  nexusplay-player-lt v2│
                                                            └────────────────────────┘
                                                                       │ instance refresh
                                                                       ▼
                                                            ┌────────────────────────┐
                                                            │ Auto Scaling Groups    │
                                                            │  nexusplay-game-asg    │
                                                            │  nexusplay-player-asg  │
                                                            └────────────────────────┘
```

## Verification performed in this POC

A real deploy was executed end-to-end via `scripts/deploy.sh` (after provisioning
the OIDC role was blocked by IAM restrictions):

1. Added `/version` endpoint to both services, built `:v2` + `:latest`.
2. Created LT v2 for `nexusplay-player-lt` with `NP_IMAGE_TAG=latest NP_VERSION=v2`.
3. Pointed `nexusplay-player-asg` at v2 and triggered instance refresh.
4. Refresh reached `Successful / 100%` with `MinHealthyPercentage=50` (zero downtime).
5. New player instance `i-0a0cdde9e1f709509` served:
   - `GET /version` → `{"version":"v2"}`
   - `docker inspect` → image `:latest`
   - `GET /healthz` → `cache:up db:up`
6. Repeated the same flow for the game ASG (also reached v2).