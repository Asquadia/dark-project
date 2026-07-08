#!/bin/bash
# install-cwagent.sh — install CloudWatch agent on an app instance, configure it to
# ship the service container's stdout logs to /aws/nexusplay/app, and start it.
set -u
export AWS_DEFAULT_REGION="${AWS_REGION:-us-east-1}"
dnf -y install amazon-cloudwatch-agent >/dev/null 2>&1 || true
# docker container logs (json-file) live here
LOG_PATH="/var/lib/docker/containers"
# pick the running container's log file
CID_FILE="/var/run/nexusplay-cid"
docker inspect --format='{{.LogPath}}' "$(docker ps -q --filter name=nexusplay-)" 2>/dev/null | head -1 > "$CID_FILE"
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<EOF
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/lib/docker/containers/*/*.log",
            "log_group_name": "/aws/nexusplay/app",
            "log_stream_name": "{instance_id}",
            "timezone": "UTC"
          }
        ]
      }
    }
  }
}
EOF
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
systemctl enable --now amazon-cloudwatch-agent
sleep 5
systemctl is-active amazon-cloudwatch-agent
echo CWAGENT_DONE