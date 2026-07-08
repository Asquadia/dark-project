#!/bin/bash
# verify-redis.sh EP — connect to Redis, PING/SET/GET, show keyspace_hits incrementing.
set -u
EP="${1:?usage: verify-redis.sh <redis-primary-endpoint>}"
export AWS_DEFAULT_REGION=us-east-1
RC=/usr/bin/redis6-cli
TOKEN="$(aws secretsmanager get-secret-value --secret-id nexusplay-redis-auth --query SecretString --output text)"
echo "TOKEN_LEN=${#TOKEN}"
RL() { timeout 10 "$RC" -h "$EP" --tls --insecure --no-auth-warning -a "$TOKEN" "$@"; }
echo "=== PING ==="; RL PING
echo "=== SET ==="; RL SET cache-test ok
echo "=== GET ==="; RL GET cache-test
echo "=== HITS_BEFORE ==="; RL INFO stats | grep keyspace_hits
RL GET cache-test >/dev/null
echo "=== HITS_AFTER ==="; RL INFO stats | grep keyspace_hits
echo "=== REPLICA INFO ==="; RL INFO replication | grep -E 'role|connected_slaves|slave'
echo "DONE"