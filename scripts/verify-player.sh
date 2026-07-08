#!/bin/bash
# verify-player.sh — exercise player CRUD on a player-service instance.
set -u
echo "=== PLAYER create ==="
curl -s -m8 -X POST http://localhost:8000/players -H "Content-Type: application/json" -d '{"id":42,"name":"alice","level":5}'; echo
echo "=== PLAYER list ==="
curl -s -m8 http://localhost:8000/players; echo
echo "=== PLAYER get 42 ==="
curl -s -m8 http://localhost:8000/players/42; echo
echo "=== PLAYER get 999 (not found) ==="
curl -s -m8 http://localhost:8000/players/999; echo
echo "DONE"