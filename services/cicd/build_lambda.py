"""Build lambda — triggered by a GitHub push webhook (Lambda Function URL).

Verifies the X-Hub-Signature-256 HMAC, extracts the head commit, then drives the
build via SSM RunCommand on the build EC2 instance:
  1) git clone git@github.com:Asquadia/dark-project.git  (deploy key in /root/.ssh)
  2) checkout the head commit SHA
  3) docker build + push both service images to ECR (tag = commit SHA + :latest)

Pushes to ECR fire the deploy lambda automatically (EventBridge).
"""
import os, json, hmac, hashlib, base64, boto3

REPO        = "Asquadia/dark-project"
CLONE_URL   = f"git@github.com:{REPO}.git"
INSTANCE_ID = os.environ["BUILD_INSTANCE_ID"]
REGISTRY    = os.environ["REGISTRY"]
REGION      = os.environ.get("AWS_REGION", "us-east-1")

SSM  = boto3.client("ssm")
SM   = boto3.client("secretsmanager")


def get_webhook_secret() -> str:
    return SM.get_secret_value(SecretId="nexusplay-webhook-secret")["SecretString"]


def verify_signature(raw_body: bytes, sig_header: str) -> bool:
    if not sig_header or not sig_header.startswith("sha256="):
        return False
    expected = hmac.new(get_webhook_secret().encode(), raw_body, hashlib.sha256).hexdigest()
    got = sig_header.removeprefix("sha256=")
    return hmac.compare_digest(expected, got)


def build_script(commit_sha: str) -> str:
    # The deploy key lives in /root/.ssh/id_ed25519 (installed once at provision time).
    return f"""#!/bin/bash
set -e
export AWS_DEFAULT_REGION={REGION}
mkdir -p /opt/build && cd /opt/build
rm -rf dark-project
GIT_SSH_COMMAND="ssh -o IdentitiesOnly=yes -i /root/.ssh/id_ed25519" \\
  git clone {CLONE_URL} dark-project
cd dark-project
git checkout {commit_sha}
echo "=== Building game-service ==="
docker build -t {REGISTRY}/nexusplay/game-service:{commit_sha} -f services/game-service/Dockerfile services
docker tag  {REGISTRY}/nexusplay/game-service:{commit_sha} {REGISTRY}/nexusplay/game-service:latest
docker push {REGISTRY}/nexusplay/game-service:{commit_sha}
docker push {REGISTRY}/nexusplay/game-service:latest
echo "=== Building player-service ==="
docker build -t {REGISTRY}/nexusplay/player-service:{commit_sha} -f services/player-service/Dockerfile services
docker tag  {REGISTRY}/nexusplay/player-service:{commit_sha} {REGISTRY}/nexusplay/player-service:latest
docker push {REGISTRY}/nexusplay/player-service:{commit_sha}
docker push {REGISTRY}/nexusplay/player-service:latest
echo "BUILD_DONE {commit_sha}"
"""


def respond(status: int, body: dict):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def lambda_handler(event, context):
    # Lambda Function URL wraps the HTTP event: event['requestContext']['http'], event['body'], event['headers'].
    headers = {k.lower(): v for k, v in event.get("headers", {}).items()}
    raw = event.get("body", "") or ""
    # Function URL can base64-encode the body if isBase64Encoded=true
    if event.get("isBase64Encoded"):
        raw = base64.b64decode(raw)
    else:
        raw = raw.encode() if isinstance(raw, str) else raw

    # ping events from GitHub webhooks (shouldn't happen for push, but be safe)
    if headers.get("x-github-event") == "ping":
        return respond(200, {"ok": True, "event": "ping"})

    if not verify_signature(raw, headers.get("x-hub-signature-256", "")):
        return respond(403, {"error": "bad signature"})

    if headers.get("x-github-event") != "push":
        return respond(202, {"ignored": headers.get("x-github-event")})

    payload = json.loads(raw)
    commit_sha = payload.get("after") or payload.get("head_commit", {}).get("id")
    ref = payload.get("ref", "")
    if ref != "refs/heads/main":
        return respond(202, {"ignored": ref})

    cmd = SSM.send_command(
        InstanceIds=[INSTANCE_ID],
        DocumentName="AWS-RunShellScript",
        Parameters={"commands": [build_script(commit_sha)]},
        Comment=f"nexusplay CI build @ {commit_sha[:8]}",
        CloudWatchOutputConfig={"CloudWatchLogGroupName": "/aws/nexusplay/cicd", "CloudWatchOutputEnabled": True},
    )
    return respond(200, {"commit": commit_sha, "commandId": cmd["Command"]["CommandId"]})