# jira-to-mem

Ingest Jira tickets into [claude-mem](https://github.com/thedotmack/claude-mem) for searchable institutional memory in Claude Code sessions.

## Why

When you ask Claude "how did we solve X before?" or "what work have we done in area Y?", it can search your ingested Jira tickets via claude-mem's FTS5 keyword search and ChromaDB semantic search.

## Prerequisites

- [jira-cli](https://github.com/ankitpokhrel/jira-cli) configured with your Atlassian credentials
- [jq](https://jqlang.github.io/jq/) 1.7+
- [claude-mem](https://github.com/thedotmack/claude-mem) worker running (start a Claude Code session with claude-mem enabled)
- `sqlite3`

## Usage

```bash
# Import 500 most recent tickets from INFRA (default)
./jira-to-mem.sh

# Import from a specific project
./jira-to-mem.sh DEVOPS

# Import with options
./jira-to-mem.sh INFRA -l 1000 -v

# Force reimport (skip dedup, overwrite existing)
./jira-to-mem.sh INFRA --force
```

### Options

| Flag | Description | Default |
|------|-------------|---------|
| `-p, --project` | Jira project key (or pass as first positional arg) | `INFRA` |
| `-m, --mem-project` | claude-mem project namespace | `jira-<project>` |
| `-l, --limit` | Max tickets to fetch | `500` |
| `-f, --force` | Re-import all tickets, skip dedup | `false` |
| `-v, --verbose` | Show per-ticket progress | `false` |

## How it works

1. **Extract** -- Fetches tickets from Jira using cursor-based pagination (`key < LAST_KEY`)
2. **Transform** -- Parses JSON, extracts plain text from Atlassian Document Format descriptions, formats each ticket as a searchable text blob
3. **Load** -- POSTs each ticket to claude-mem's worker API (`POST /api/memory/save`)

Each ticket is stored as:
```
[INFRA-1234] Short summary here
Status: Done | Resolution: Done | Type: Task | Priority: P2
Assignee: Matt Williams | Labels: kubernetes, networking

Description:
Plain text extracted from the ticket description...
```

### Dedup

On re-runs, the script checks SQLite directly for existing tickets by title prefix. Only new tickets are imported. Use `--force` to reimport everything.

### Searchability

Tickets are indexed in both FTS5 (keyword) and ChromaDB (semantic vector), so you can search by exact terms ("SSL cert rotation") or by meaning ("how did we handle certificate expiry").

Each Jira project gets its own claude-mem namespace (e.g. `jira-infra`, `jira-devops`) so you can filter searches by project.

## Performance

| Tickets | Fetch time | Import time | Total |
|---------|-----------|-------------|-------|
| 100 | ~2s | ~12s | ~14s |
| 500 | ~10s | ~85s | ~95s |

## Refreshing

Run the script again anytime. Dedup ensures only new tickets get imported. There's no automation -- just run it when you want fresh data.
