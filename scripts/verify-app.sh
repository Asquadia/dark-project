#!/bin/bash
# verify-app.sh — exercise cache-aside + DB write/read on the local app instance.
set -u
echo "=== GAME get_state first (cache MISS -> DB) ==="
curl -s -m8 http://localhost:8000/game/state/1; echo
echo "=== GAME get_state again (cache HIT) ==="
curl -s -m8 http://localhost:8000/game/state/1; echo
echo "=== GAME move (write + cache invalidate) ==="
curl -s -m8 -X POST http://localhost:8000/game/move/1; echo
echo "=== GAME get_state after move (re-read from DB) ==="
curl -s -m8 http://localhost:8000/game/state/1; echo
echo "=== PLAYER create ==="
curl -s -m8 -X POST http://localhost:8000/players -H "Content-Type: application/json" -d '{"id":42,"name":"alice","level":5}'; echo
echo "=== PLAYER list ==="
curl -s -m8 http://localhost:8000/players; echo
echo "=== PLAYER get 42 ==="
curl -s -m8 http://localhost:8000/players/42; echo
echo "DONE"