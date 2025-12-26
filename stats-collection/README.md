# Stats Collection (Local)

This is a minimal FastAPI service that accepts anonymized performance stats
and stores them in a local SQLite database.

## Run

```bash
docker compose up --build
```

The service listens on `http://localhost:8001` and stores data in `./data/stats.db`.

## Endpoints

- `GET /health` -> `{"status":"ok"}`
- `POST /ingest` -> stores a run payload in SQLite

The gobx client posts to `http://localhost:8001/ingest` when stats are enabled.
