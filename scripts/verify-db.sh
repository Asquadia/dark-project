#!/bin/bash
# verify-db.sh — connect to PostgreSQL via psql, run a SELECT, create+query a table.
set -u
export AWS_DEFAULT_REGION=us-east-1
DB_EP="db.nexusplay.lab"
P_IP="$(aws ec2 describe-instances --filters 'Name=tag:Name,Values=nexusplay-dns-primary' 'Name=instance-state-name,Values=running' --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)"
S_IP="$(aws ec2 describe-instances --filters 'Name=tag:Name,Values=nexusplay-dns-secondary' 'Name=instance-state-name,Values=running' --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)"
printf 'nameserver %s\nnameserver %s\nnameserver 169.254.169.253\nsearch ec2.internal\n' "$P_IP" "$S_IP" > /etc/resolv.conf
dnf -y install postgresql15 >/dev/null 2>&1
PW="$(aws secretsmanager get-secret-value --secret-id nexusplay-db-password --query SecretString --output text)"
echo "=== resolve db.nexusplay.lab ==="
getent hosts db.nexusplay.lab
echo "=== psql SELECT version ==="
PGPASSWORD="$PW" psql -h "$DB_EP" -U nexusplay -d postgres -c "SELECT version();" 2>&1
echo "=== CREATE+INSERT+SELECT ==="
PGPASSWORD="$PW" psql -h "$DB_EP" -U nexusplay -d postgres <<EOF
CREATE TABLE IF NOT EXISTS nexusplay_probe (id int, msg text);
INSERT INTO nexusplay_probe VALUES (1, 'hello from app instance via dns');
SELECT * FROM nexusplay_probe;
EOF
echo "DONE"