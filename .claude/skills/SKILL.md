---
name: jira-to-claudemem
description: Import recent Jira tickets into claude-mem for searchable institutional memory. Use when the user wants to refresh Jira context, ingest tickets, or says "import Jira tickets" or "/jira-to-claudemem".
user-invocable: true
allowed-tools: Bash
---

# Jira to claude-mem

Imports recent Jira tickets into claude-mem so they're searchable via FTS5 keyword and ChromaDB semantic search.

## Prerequisites

- `jira` CLI configured (`~/.config/.jira/.config.yml`)
- `jq` 1.7+
- `sqlite3`
- claude-mem worker running on `http://127.0.0.1:37777`

## Usage

The script is installed at `~/.local/bin/jira-to-claudemem`.

### Quick refresh (default behavior for this skill)

When invoked as `/jira-to-claudemem` without arguments, import the **last 10 tickets** from INFRA with verbose output:

```bash
jira-to-claudemem INFRA -l 10 -v
```

### If the user specifies a project or options

Pass them through directly:

```bash
# Different project
jira-to-claudemem DEVOPS -l 10 -v

# More tickets
jira-to-claudemem INFRA -l 100 -v

# Force reimport (skip dedup)
jira-to-claudemem INFRA -l 10 -v --force
```

### Full options

| Flag | Description | Default |
|------|-------------|---------|
| `-p, --project` | Jira project key (or positional arg) | `INFRA` |
| `-m, --mem-project` | claude-mem project namespace | `jira-<project>` |
| `-l, --limit` | Max tickets to fetch | `500` |
| `-f, --force` | Re-import all, skip dedup | `false` |
| `-v, --verbose` | Show per-ticket progress | `false` |

## Workflow

1. Check that claude-mem worker is healthy (the script does this automatically and exits with a clear error if not)
2. Run the command
3. Report the results summary to the user (imported / skipped / failed counts from the script output)

## Notes

- Dedup is built in: re-running only imports new tickets. No harm in running often.
- Each Jira project maps to a claude-mem namespace (e.g. `jira-infra`, `jira-devops`)
- Tickets are indexed in both FTS5 and ChromaDB for keyword and semantic search
