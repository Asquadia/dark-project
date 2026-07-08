#!/bin/bash
# verify-redis-via-dns.sh — connect to Redis via the nexusplay.lab DNS name (proves DNS→cache wiring)
set -u
export AWS_DEFAULT_REGION=us-east-1
# Configure resolver to use BIND (primary first, secondary backup), then Amazon DNS fallback.
P_IP="$(aws ec2 describe-instances --filters 'Name=tag:Name,Values=nexusplay-dns-primary' 'Name=instance-state-name,Values=running' --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)"
S_IP="$(aws ec2 describe-instances --filters 'Name=tag:Name,Values=nexusplay-dns-secondary' 'Name=instance-state-name,Values=running' --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)"
printf 'nameserver %s\nnameserver %s\nnameserver 169.254.169.253\nsearch ec2.internal\n' "$P_IP" "$S_IP" > /etc/resolv.conf
RC=/usr/bin/redis6-cli
TOKEN="$(aws secretsmanager get-secret-value --secret-id nexusplay-redis-auth --query SecretString --output text)"
echo "=== resolve redis.nexusplay.lab ==="
getent hosts redis.nexusplay.lab
echo "=== PING via DNS name ==="
timeout 10 "$RC" -h redis.nexusplay.lab --tls --insecure --no-auth-warning -a "$TOKEN" PING
echo "=== SET/GET via DNS name ==="
timeout 10 "$RC" -h redis.nexusplay.lab --tls --insecure --no-auth-warning -a "$TOKEN" SET via-dns yes
timeout 10 "$RC" -h redis.nexusplay.lab --tls --insecure --no-auth-warning -a "$TOKEN" GET via-dns
echo "DONE"