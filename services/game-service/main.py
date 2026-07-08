# game-service — game state with Redis cache-aside backed by PostgreSQL.
import os, json, time
from fastapi import FastAPI
from common.config import redis_client, db_conn, health

app = FastAPI(title="NexusPlay Game Service")

VERSION = os.environ.get("NP_VERSION", "v1")
BUILD = os.environ.get("NP_BUILD", "local")

@app.get("/healthz")
def healthz():
    return health("game")

@app.get("/version")
def version():
    return {"service": "game", "version": VERSION, "build": BUILD, "ts": time.time()}

@app.get("/game/state/{player_id}")
def get_state(player_id: str):
    r = redis_client()
    key = f"game:state:{player_id}"
    cached = r.get(key)
    if cached:
        return {"player_id": player_id, "state": json.loads(cached), "source": "cache"}
    c = db_conn(); cur = c.cursor()
    cur.execute("SELECT id, msg FROM nexusplay_probe WHERE id=%s", (player_id,))
    row = cur.fetchone(); cur.close(); c.close()
    state = {"id": row[0], "msg": row[1]} if row else {"id": player_id, "msg": "default"}
    r.set(key, json.dumps(state), ex=60)
    return {"player_id": player_id, "state": state, "source": "db"}

@app.post("/game/move/{player_id}")
def move(player_id: str):
    c = db_conn(); cur = c.cursor()
    cur.execute(
        "INSERT INTO nexusplay_probe VALUES (%s, %s) ON CONFLICT DO NOTHING",
        (int(player_id) if player_id.isdigit() else 999, f"move at {time.time()}"),
    )
    c.commit(); cur.close(); c.close()
    redis_client().delete(f"game:state:{player_id}")
    return {"player_id": player_id, "moved": True}