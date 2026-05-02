# AAASP Elixir — Claude Code Guide

## Project

Standalone Elixir service (Phoenix + Oban + Finch + PostgreSQL). Runs on rising as `eudaimonia-aaasp` container on `:8002`. `POST /v1/runs` returns 202 async (add `sync=true` to block).

## Quick Commands

```bash
mix deps.get          # Install dependencies
mix test              # Run tests
mix phx.server        # Start Phoenix server

# Deploy
./scripts/deploy.sh --update
```

## Shared Work Queue

This project's work queue (`company_id="aaasp"`) lives in the **shared PostgreSQL** on rising — not a local SQLite file and not behind the kernel REST API at `:8000`.

**Check pending tasks:**
```bash
ssh rising "docker exec eudaimonia-eudaimonia-postgres-1 psql -U eudaimonia -c \
  \"SELECT id, title, status, priority FROM work_items WHERE company_id='aaasp' AND status='pending' ORDER BY priority DESC\""
```

**Mark a task done:**
```bash
ssh rising "docker exec eudaimonia-eudaimonia-postgres-1 psql -U eudaimonia -c \
  \"UPDATE work_items SET status='done', completion_note='<note>' WHERE id='<uuid>'\""
```

**Do NOT** rely on `http://eudaimonia.win:8000` for work queue access — the kernel restarts frequently during upgrades and the API will timeout. Use PostgreSQL directly.
