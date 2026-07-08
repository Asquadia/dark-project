# NexusPlay shared config — loads secrets from Secrets Manager, builds Redis + Postgres clients.
import os, json, boto3, redis, psycopg2

_region = os.environ.get("AWS_REGION", "us-east-1")
_sm = None

def _secret(name):
    global _sm
    if _sm is None:
        _sm = boto3.client("secretsmanager", region_name=_region)
    return _sm.get_secret_value(SecretId=name)["SecretString"]

REDIS_HOST = os.environ.get("REDIS_HOST", "redis.nexusplay.lab")
REDIS_PORT = int(os.environ.get("REDIS_PORT", "6379"))
DB_HOST = os.environ.get("DB_HOST", "db.nexusplay.lab")
DB_PORT = int(os.environ.get("DB_PORT", "5432"))
DB_USER = os.environ.get("DB_USER", "nexusplay")
DB_NAME = os.environ.get("DB_NAME", "postgres")

_redis = None
_db_pw = None
_redis_auth = None

def redis_client():
    global _redis, _redis_auth
    if _redis is None:
        _redis_auth = _secret("nexusplay-redis-auth")
        _redis = redis.Redis(
            host=REDIS_HOST, port=REDIS_PORT, ssl=True, ssl_cert_reqs=None,
            password=_redis_auth, decode_responses=True, socket_connect_timeout=3, socket_timeout=3,
        )
    return _redis

def db_conn():
    global _db_pw
    if _db_pw is None:
        _db_pw = _secret("nexusplay-db-password")
    return psycopg2.connect(
        host=DB_HOST, port=DB_PORT, user=DB_USER, password=_db_pw,
        dbname=DB_NAME, connect_timeout=3,
    )

def health(service):
    out = {"service": service, "status": "ok"}
    try:
        redis_client().ping(); out["cache"] = "up"
    except Exception as e:
        out["cache"] = "down"; out["cache_err"] = str(e)[:160]
    try:
        c = db_conn(); c.close(); out["db"] = "up"
    except Exception as e:
        out["db"] = "down"; out["db_err"] = str(e)[:160]
    return out