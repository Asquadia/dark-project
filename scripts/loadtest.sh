#!/bin/bash
# loadtest.sh — Apache Bench load test against the NexusPlay ALB.
# Ramps from a low baseline to a sustained peak to trigger ASG scale-out.
# Usage: source ./setenv.sh && bash scripts/loadtest.sh [target_url] [duration_sec]
set -u
URL="${1:-}"
DUR="${2:-300}"
if [ -z "$URL" ]; then
  URL="http://$(aws cloudformation describe-stacks --stack-name nexusplay-70-alb \
    --query 'Stacks[0].Outputs[?ExportName==`NexusPlay-AlbDnsName`].OutputValue' --output text)/game/state/1"
fi
echo "=== target: $URL ==="
echo "=== phase 1: baseline 5 RPS for 60s ==="
ab -n 300 -c 5 -q "$URL" 2>&1 | tail -15
echo "=== phase 2: ramp to 50 RPS for 90s ==="
ab -n 4500 -c 50 -q "$URL" 2>&1 | tail -15
echo "=== phase 3: peak 100 RPS for 90s ==="
ab -n 9000 -c 100 -q "$URL" 2>&1 | tail -15
echo "LOADTEST_DONE"