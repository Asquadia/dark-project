#!/bin/bash
# stress-cpu.sh [seconds] — pin all vCPUs to induce ASG scale-out.
set -u
SECS="${1:-400}"
N=$(nproc)
echo "spawning $N stress-ng cpu workers for ${SECS}s on $(hostname)"
dnf -y install stress-ng >/dev/null 2>&1 || true
if command -v stress-ng >/dev/null 2>&1; then
  timeout "$SECS" stress-ng --cpu "$N" --cpu-method all --metrics-brief 2>&1 | tail -5
else
  # fallback: pure-bash CPU burn across N cores
  for c in $(seq 1 "$N"); do
    ( end=$((SECS)); while [ $SECONDS -lt $end ]; do :; done ) &
  done
  SECONDS=0; while [ $SECONDS -lt "$SECS" ]; do :; done
  echo "fallback burn done"
fi
echo "STRESS_DONE"