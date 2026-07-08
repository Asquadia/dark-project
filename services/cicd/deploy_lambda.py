"""Deploy lambda — triggered by ECR image push.

Per service (game / player):
  1) describe the latest launch template version to clone its user-data
  2) render a new user-data with NP_IMAGE_TAG=<image_tag>
  3) create-launch-template-version
  4) modify-launch-template --default-version
  5) update-auto-scaling-group to point at the new version
  6) start-instance-refresh on the ASG
"""
import os, re, json, boto3

REGISTRY    = os.environ["REGISTRY"]
GAME_LT     = os.environ["GAME_LT"]
PLAYER_LT   = os.environ["PLAYER_LT"]
GAME_ASG    = os.environ["GAME_ASG"]
PLAYER_ASG  = os.environ["PLAYER_ASG"]

EC2 = boto3.client("ec2")
ASG = boto3.client("autoscaling")


def service_for_image(repo, tag):
    if repo == "game-service":
        return GAME_LT, GAME_ASG, "game-service"
    if repo == "player-service":
        return PLAYER_LT, PLAYER_ASG, "player-service"
    raise ValueError(f"unknown repo {repo}")


def extract_tag(event):
    detail = event["detail"]
    repo   = detail["repository-name"]
    # Image tag appears in image-digest or we pick from the pushed image; the rule only matches nexusplay/*
    # ECR doesn't include the tag in the event. We use "latest" because the build script pushes
    # only the commit-SHA tag — the deploy must know which tag triggered it.
    # Easiest: look at last 3 images in the repo and pick the most recent one not equal to v1/v2.
    images = EC2.describe_launch_templates  # noop; placeholder
    raise NotImplementedError("need to derive tag")


def lambda_handler(event, context):
    # The ECR push event gives us repo + image digest; not the tag.
    # Our build script always pushes under the commit SHA tag — but to stay generic,
    # we read the most recent image from the repo and use its imageTag.
    detail = event["detail"]
    repo_name = detail["repository-name"]                  # e.g. nexusplay/game-service
    short     = repo_name.split("/")[-1]                   # game-service
    lt_name, asg_name, svc = service_for_image(short, None)

    ecr = boto3.client("ecr")
    images = ecr.describe_images(repositoryName=repo_name, maxResults=50)["imageDetails"]
    # Find the most recently pushed image that has a real version tag (not "latest", not "v1"/seed).
    # Tags are pushed as [<commit-sha>, "latest"] by the build script; we want the SHA tag.
    chosen = None
    for img in sorted(images, key=lambda i: i.get("imagePushedAt", ""), reverse=True):
        tags = [t for t in img.get("imageTags", []) if t not in ("latest", "v1", "v2")]
        if tags:
            chosen = tags[0]
            break
    if chosen is None:
        # fall back to the newest image's first tag
        for img in sorted(images, key=lambda i: i.get("imagePushedAt", ""), reverse=True):
            if img.get("imageTags"):
                chosen = img["imageTags"][0]
                break
    if chosen is None:
        return {"status": "no-image-tag-found"}

    # Clone the latest LT user-data and bump NP_IMAGE_TAG + NP_VERSION
    cur = EC2.describe_launch_template_versions(LaunchTemplateName=lt_name, Versions=["$Latest"])
    user_data = cur["LaunchTemplateVersions"][0]["LaunchTemplateData"]["UserData"]
    # decode, replace tags, re-encode
    import base64
    raw = base64.b64decode(user_data).decode("utf-8")
    raw = re.sub(r"export NP_IMAGE_TAG=\S+",   f"export NP_IMAGE_TAG={chosen}",   raw)
    raw = re.sub(r"export NP_VERSION=\S+",     f"export NP_VERSION={chosen}",     raw)
    new_ud = base64.b64encode(raw.encode("utf-8")).decode("utf-8")

    new_ver = EC2.create_launch_template_version(
        LaunchTemplateName=lt_name,
        VersionDescription=f"{svc} @ {chosen} via CI/CD",
        SourceVersion="$Latest",
        LaunchTemplateData={"UserData": new_ud},
    )["LaunchTemplateVersion"]["VersionNumber"]

    EC2.modify_launch_template(LaunchTemplateName=lt_name, DefaultVersion=str(new_ver))
    lt_id = EC2.describe_launch_template_versions(LaunchTemplateName=lt_name)["LaunchTemplateVersions"][0]["LaunchTemplateId"]
    ASG.update_auto_scaling_group(
        AutoScalingGroupName=asg_name,
        LaunchTemplate={"LaunchTemplateId": lt_id, "Version": str(new_ver)},
    )
    refresh = ASG.start_instance_refresh(
        AutoScalingGroupName=asg_name,
        Preferences={"MinHealthyPercentage": 50, "InstanceWarmup": 300},
    )
    return {"service": svc, "imageTag": chosen, "ltVersion": new_ver, "instanceRefreshId": refresh["InstanceRefreshId"]}