# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A single bash script (`jira-to-mem.sh`) that ingests Jira tickets into claude-mem for searchable institutional memory. ETL pipeline: jira CLI → jq → curl to claude-mem worker API.

## Running

```bash
# Requires claude-mem worker running on port 37777 (start a Claude Code session with claude-mem enabled)
./jira-to-mem.sh INFRA              # import 500 tickets from INFRA project
./jira-to-mem.sh DEVOPS -l 200 -v   # different project, limit, verbose
./jira-to-mem.sh --force             # reimport all, skip dedup
```

## Dependencies

- `jira` CLI (jira-cli by ankitpokhrel) — configured at `~/.config/.jira/.config.yml`
- `jq` 1.7+
- `sqlite3`
- claude-mem worker on `http://127.0.0.1:37777`

## Key Architecture Decisions

- **Cursor-based pagination**: jira-cli's `--paginate` offset is broken; we use JQL `key < LAST_KEY` instead
- **SQLite dedup over search API**: claude-mem's search API matches broadly across sessions/prompts/observations; direct SQLite query on `~/.claude-mem/claude-mem.db` with `WHERE project = X AND title LIKE '[KEY]%'` is precise
- **stderr for logging**: `log()` writes to stderr so `TICKETS=$(fetch_tickets)` doesn't mix diagnostics with JSON data
- **ADF-to-text via jq**: `[.. | .text? // empty] | join(" ")` recursively extracts text from Atlassian Document Format
- **Per-project namespacing**: each Jira project gets its own claude-mem project (e.g. `jira-infra`, `jira-devops`)

## claude-mem Worker API

- `POST /api/memory/save` — `{text, title, project}` → saves observation, indexes in FTS5 + ChromaDB
- `GET /api/health` — health check
- Observations land in `~/.claude-mem/claude-mem.db` table `observations` with `project` column
