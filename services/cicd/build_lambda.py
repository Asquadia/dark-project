"""Build lambda — triggered by CodeCommit push on main.

Drives the build via SSM RunCommand on the build EC2 instance:
  1) git pull CodeCommit
  2) docker build + push both service images to ECR (tag = commit SHA)

Pushes to ECR fire the deploy lambda automatically (EventBridge).
"""
import os, json, boto3

CODE_REPO   = os.environ["CODECOMMIT_REPO"]
INSTANCE_ID = os.environ["BUILD_INSTANCE_ID"]
REGISTRY    = os.environ["REGISTRY"]
BUCKET      = os.environ["ARTIFACT_BUCKET"]
REGION      = os.environ["AWS_REGION"]

SSM = boto3.client("ssm")
CODECOMMIT = boto3.client("codecommit")


def get_commit_sha(event):
    """Extract commit SHA from the CodeCommit event payload."""
    try:
        return event["detail"]["commitId"]
    except (KeyError, TypeError):
        # fall back to repo head
        b = CODECOMMIT.get_branch(repositoryName=CODE_REPO, branchName="main")
        return b["branch"]["commitId"]


def build_script(commit_sha):
    """The shell script the build instance will run."""
    return f"""#!/bin/bash
set -e
export AWS_DEFAULT_REGION={REGION}
mkdir -p /opt/build && cd /opt/build
rm -rf nexusplay-app
git clone --depth 50 codecommit::us-east-1://{CODE_REPO}
cd nexusplay-app
git checkout {commit_sha}
echo "=== Building game-service ==="
docker build -t {REGISTRY}/nexusplay/game-service:{commit_sha} -f services/game-service/Dockerfile services
docker push   {REGISTRY}/nexusplay/game-service:{commit_sha}
echo "=== Building player-service ==="
docker build -t {REGISTRY}/nexusplay/player-service:{commit_sha} -f services/player-service/Dockerfile services
docker push   {REGISTRY}/nexusplay/player-service:{commit_sha}
echo "BUILD_DONE {commit_sha}"
"""


def lambda_handler(event, context):
    commit_sha = get_commit_sha(event)
    script     = build_script(commit_sha)

    resp = SSM.send_command(
        InstanceIds=[INSTANCE_ID],
        DocumentName="AWS-RunShellScript",
        Parameters={"commands": [script]},
        Comment=f"nexusplay CI build @ {commit_sha}",
        CloudWatchOutputConfig={"CloudWatchLogGroupName": "/aws/nexusplay/cicd", "CloudWatchOutputEnabled": True},
    )
    return {"commit": commit_sha, "commandId": resp["Command"]["CommandId"]}