# Jira-to-claude-mem Ingestion Script Design

**Date**: 2026-02-16
**Status**: Approved

## Goal

Make ~500 INFRA Jira tickets searchable in claude-mem for institutional memory ("how did we solve X?") and domain discovery ("what work have we done in area Z?").

## Architecture

A single bash script (`jira-to-mem.sh`) with an ETL pipeline:

```
jira CLI (JQL + --raw)  →  jq (parse ADF → plain text)  →  curl (POST to claude-mem worker)
```

### Extract

- Source: `jira issue list -p INFRA --raw --paginate <offset>:100 --order-by updated --reverse`
- Pages through all tickets in batches of 100 (Jira CLI max)
- Raw JSON output gives access to all fields

### Transform

Each ticket is formatted as a text blob:

```
[INFRA-1234] Short summary here
Status: Done | Resolution: Done | Type: Task | Priority: P2
Assignee: Matt Williams | Labels: kubernetes, networking

Description:
Plain text extracted from ADF description...
```

ADF-to-text extraction via jq: `jq -r '[.. | .text? // empty] | join("")'`

Fields extracted: summary, status, resolution, type, priority, assignee, labels, description.

### Load

- POST to `http://127.0.0.1:37777/api/memory/save`
- Body: `{"text": "<formatted blob>", "title": "[INFRA-1234] Summary", "project": "jira-infra"}`
- Separate project name (`jira-infra`) keeps ingested data filterable from organic memories

## Dedup Strategy

Before inserting, search claude-mem for existing observation with same ticket key in title. Skip if found. `--force` flag overrides to re-import all.

## On-Demand Refresh

Re-run the script anytime. Dedup ensures only new/missing tickets get imported. No cron or automation needed.

## Prerequisites

- `jira` CLI (installed, configured for your Atlassian instance)
- `jq` 1.7+ (installed)
- claude-mem worker running on port 37777

## Error Handling

- Health check on worker before starting (fail fast)
- Per-ticket error logging (continue on failure)
- Summary output: "Imported X new, skipped Y existing, Z failed"

## Storage Estimate

~500 tickets x 250-500 tokens each = 125K-250K tokens total in claude-mem.

## Decisions

- **Approach 1 chosen** (save_memory API) over direct SQLite (loses vector search) and flat files (separate system)
- **Summary + description + resolution** only — no comments, keeping it lean
- **Project name `jira-infra`** to separate from organic claude-mem data
