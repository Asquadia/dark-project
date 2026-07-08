# game-service — game state with Redis cache-aside backed by PostgreSQL.
import os, json, time
from fastapi import FastAPI
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from common.config import redis_client, db_conn, health

app = FastAPI(title="NexusPlay Game Service")

VERSION = os.environ.get("NP_VERSION", "v1")
BUILD = os.environ.get("NP_BUILD", "local")

CACHE_TTL_STATE = 60
CACHE_TTL_LEADERBOARD = 30


def _ensure_scores_table(cur):
    cur.execute(
        "CREATE TABLE IF NOT EXISTS nexusplay_scores ("
        "player_id int PRIMARY KEY, best_score int NOT NULL DEFAULT 0, "
        "level int NOT NULL DEFAULT 1, updated_at timestamp NOT NULL DEFAULT now())"
    )


def _ensure_players_table(cur):
    cur.execute(
        "CREATE TABLE IF NOT EXISTS nexusplay_players ("
        "id int PRIMARY KEY, name text NOT NULL, level int NOT NULL DEFAULT 1)"
    )


@app.get("/healthz")
def healthz():
    return health("game")


@app.get("/version")
def version():
    return {"service": "game", "version": VERSION, "build": BUILD, "stage": "ci-cd", "ts": time.time()}


@app.get("/game/state/{player_id}")
def get_state(player_id: str):
    r = redis_client()
    key = f"game:state:{player_id}"
    cached = r.get(key)
    if cached:
        return {"player_id": player_id, "state": json.loads(cached), "source": "cache"}
    c = db_conn(); cur = c.cursor()
    _ensure_scores_table(cur); c.commit()
    cur.execute(
        "SELECT best_score, level FROM nexusplay_scores WHERE player_id=%s", (int(player_id) if player_id.isdigit() else 0,)
    )
    row = cur.fetchone(); cur.close(); c.close()
    state = {"best": row[0], "level": row[1]} if row else {"best": 0, "level": 1}
    r.set(key, json.dumps(state), ex=CACHE_TTL_STATE)
    return {"player_id": player_id, "state": state, "source": "db"}


@app.post("/game/move/{player_id}")
def move(player_id: str, body: dict | None = None):
    body = body or {}
    score = int(body.get("score", 0))
    pid = int(player_id) if player_id.isdigit() else 0
    c = db_conn(); cur = c.cursor()
    _ensure_scores_table(cur); c.commit()
    cur.execute(
        "INSERT INTO nexusplay_scores (player_id, best_score, level) VALUES (%s, %s, %s) "
        "ON CONFLICT (player_id) DO UPDATE SET "
        "best_score = GREATEST(nexusplay_scores.best_score, EXCLUDED.best_score), "
        "level = GREATEST(nexusplay_scores.level, EXCLUDED.level), "
        "updated_at = now()",
        (pid, score, max(1, score // 5)),
    )
    c.commit()
    cur.execute("SELECT best_score, level FROM nexusplay_scores WHERE player_id=%s", (pid,))
    row = cur.fetchone(); cur.close(); c.close()
    redis_client().delete(f"game:state:{player_id}")
    return {"player_id": player_id, "best": row[0], "level": row[1], "moved": True}


@app.get("/game/leaderboard")
def leaderboard():
    r = redis_client()
    cached = r.get("game:leaderboard")
    if cached:
        return {"leaderboard": json.loads(cached), "source": "cache"}
    c = db_conn(); cur = c.cursor()
    _ensure_scores_table(cur); _ensure_players_table(cur); c.commit()
    cur.execute(
        "SELECT s.player_id, COALESCE(p.name, 'player-' || s.player_id), s.best_score, s.level "
        "FROM nexusplay_scores s LEFT JOIN nexusplay_players p ON p.id = s.player_id "
        "ORDER BY s.best_score DESC LIMIT 10"
    )
    rows = cur.fetchall(); cur.close(); c.close()
    lb = [{"id": r[0], "name": r[1], "best": r[2], "level": r[3]} for r in rows]
    r.set("game:leaderboard", json.dumps(lb), ex=CACHE_TTL_LEADERBOARD)
    return {"leaderboard": lb, "source": "db"}


# ── Frontend (static) ──
@app.get("/")
def index():
    return FileResponse("static/index.html")

app.mount("/static", StaticFiles(directory="static"), name="static")// mer. 08 juil. 2026 15:34:04 CEST
