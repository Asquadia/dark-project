# player-service — player CRUD backed by PostgreSQL.
import os, time
from fastapi import FastAPI
from pydantic import BaseModel
from common.config import db_conn, health

app = FastAPI(title="NexusPlay Player Service")

VERSION = os.environ.get("NP_VERSION", "v1")
BUILD = os.environ.get("NP_BUILD", "local")

class Player(BaseModel):
    id: int
    name: str
    level: int = 1

@app.get("/healthz")
def healthz():
    return health("player")

@app.get("/version")
def version():
    return {"service": "player", "version": VERSION, "build": BUILD, "ts": time.time()}
    return health("player")

@app.get("/players")
def list_players():
    c = db_conn(); cur = c.cursor()
    cur.execute("SELECT id, name, level FROM nexusplay_players ORDER BY id")
    rows = cur.fetchall(); cur.close(); c.close()
    return {"players": [{"id": r[0], "name": r[1], "level": r[2]} for r in rows]}

@app.get("/players/{player_id}")
def get_player(player_id: int):
    c = db_conn(); cur = c.cursor()
    cur.execute("SELECT id, name, level FROM nexusplay_players WHERE id=%s", (player_id,))
    r = cur.fetchone(); cur.close(); c.close()
    return {"player": {"id": r[0], "name": r[1], "level": r[2]}} if r else {"error": "not found"}

@app.post("/players")
def create_player(p: Player):
    c = db_conn(); cur = c.cursor()
    cur.execute(
        "CREATE TABLE IF NOT EXISTS nexusplay_players (id int primary key, name text, level int)"
    )
    cur.execute(
        "INSERT INTO nexusplay_players (id, name, level) VALUES (%s, %s, %s) "
        "ON CONFLICT (id) DO UPDATE SET name=EXCLUDED.name, level=EXCLUDED.level",
        (p.id, p.name, p.level),
    )
    c.commit(); cur.close(); c.close()
    return {"created": True, "player": p.model_dump(), "ts": time.time()}