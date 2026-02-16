# Jira-to-claude-mem Ingestion Script Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** A repeatable bash script that fetches INFRA Jira tickets and ingests them into claude-mem for searchable institutional memory.

**Architecture:** Single bash script using `jira` CLI for extraction, `jq` for ADF-to-text transformation, and `curl` to POST to claude-mem's worker API on port 37777. Dedup by searching for existing ticket keys before inserting.

**Tech Stack:** Bash, jira-cli, jq 1.7, curl, claude-mem worker HTTP API

---

### Task 1: Initialize project and create script skeleton

**Files:**
- Create: `jira-to-mem.sh`

**Step 1: Create the script with argument parsing, usage, and health check**

```bash
#!/usr/bin/env bash
set -euo pipefail

# Defaults
PROJECT="INFRA"
MEM_PROJECT="jira-infra"
WORKER_URL="http://127.0.0.1:37777"
LIMIT=500
FORCE=false
VERBOSE=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Ingest Jira tickets into claude-mem for searchable institutional memory.

Options:
  -p, --project PROJECT    Jira project key (default: INFRA)
  -m, --mem-project NAME   claude-mem project name (default: jira-infra)
  -l, --limit N            Max tickets to fetch (default: 500)
  -f, --force              Re-import all tickets (skip dedup)
  -v, --verbose            Show detailed progress
  -h, --help               Show this help
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--project)    PROJECT="$2"; shift 2 ;;
    -m|--mem-project) MEM_PROJECT="$2"; shift 2 ;;
    -l|--limit)      LIMIT="$2"; shift 2 ;;
    -f|--force)      FORCE=true; shift ;;
    -v|--verbose)    VERBOSE=true; shift ;;
    -h|--help)       usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

log() { echo "[$(date +%H:%M:%S)] $*"; }
vlog() { [[ "$VERBOSE" == true ]] && log "$*" || true; }

# Health check
if ! curl -sf "$WORKER_URL/api/health" > /dev/null 2>&1; then
  echo "ERROR: claude-mem worker not running on $WORKER_URL"
  echo "Start a Claude Code session with claude-mem enabled first."
  exit 1
fi
log "claude-mem worker is healthy"
```

**Step 2: Verify the script runs and health check works**

Run: `chmod +x jira-to-mem.sh && bash jira-to-mem.sh --help`
Expected: Usage text displayed

Run: `bash jira-to-mem.sh`
Expected: Either "claude-mem worker is healthy" or the error message if worker is not running

**Step 3: Commit**

```bash
git init
git add jira-to-mem.sh docs/
git commit -m "feat: scaffold jira-to-mem script with arg parsing and health check"
```

---

### Task 2: Implement ticket fetching with pagination

**Files:**
- Modify: `jira-to-mem.sh`

**Step 1: Add the fetch function after the health check**

```bash
# Fetch tickets in pages of 100
fetch_tickets() {
  local offset=0
  local page_size=100
  local total_fetched=0
  local all_tickets="[]"

  log "Fetching up to $LIMIT tickets from $PROJECT..."

  while [[ $total_fetched -lt $LIMIT ]]; do
    local remaining=$((LIMIT - total_fetched))
    local fetch_count=$((remaining < page_size ? remaining : page_size))

    vlog "Fetching page at offset $offset (limit $fetch_count)..."

    local page
    page=$(jira issue list -p "$PROJECT" --raw --paginate "$offset:$fetch_count" \
      --order-by updated --reverse 2>/dev/null) || {
      log "WARNING: Failed to fetch page at offset $offset"
      break
    }

    local count
    count=$(echo "$page" | jq 'length')

    if [[ "$count" -eq 0 ]]; then
      vlog "No more tickets at offset $offset"
      break
    fi

    all_tickets=$(echo "$all_tickets $page" | jq -s '.[0] + .[1]')
    total_fetched=$((total_fetched + count))
    offset=$((offset + count))

    vlog "Fetched $count tickets (total: $total_fetched)"
  done

  log "Fetched $total_fetched tickets total"
  echo "$all_tickets"
}

TICKETS=$(fetch_tickets)
TICKET_COUNT=$(echo "$TICKETS" | jq 'length')
log "Processing $TICKET_COUNT tickets..."
```

**Step 2: Test with a small limit**

Run: `bash jira-to-mem.sh -l 3 -v`
Expected: Fetches 3 tickets, shows pagination progress

**Step 3: Commit**

```bash
git add jira-to-mem.sh
git commit -m "feat: add paginated ticket fetching from Jira CLI"
```

---

### Task 3: Implement ticket formatting (ADF-to-text + text blob)

**Files:**
- Modify: `jira-to-mem.sh`

**Step 1: Add the format function after fetch_tickets**

```bash
# Format a single ticket JSON into a searchable text blob
format_ticket() {
  local ticket_json="$1"

  local key summary status resolution type priority assignee labels description

  key=$(echo "$ticket_json" | jq -r '.key')
  summary=$(echo "$ticket_json" | jq -r '.fields.summary // "No summary"')
  status=$(echo "$ticket_json" | jq -r '.fields.status.name // "Unknown"')
  resolution=$(echo "$ticket_json" | jq -r '.fields.resolution.name // "Unresolved"')
  type=$(echo "$ticket_json" | jq -r '.fields.issueType.name // .fields.issuetype.name // "Unknown"')
  priority=$(echo "$ticket_json" | jq -r '.fields.priority.name // "None"')
  assignee=$(echo "$ticket_json" | jq -r '.fields.assignee.displayName // "Unassigned"')
  labels=$(echo "$ticket_json" | jq -r '(.fields.labels // []) | join(", ")')

  # Extract plain text from ADF description
  description=$(echo "$ticket_json" | jq -r '
    .fields.description
    | if . == null then "No description"
      else [.. | .text? // empty] | join(" ")
      end
  ')

  # Build the text blob
  cat <<EOF
[$key] $summary
Status: $status | Resolution: $resolution | Type: $type | Priority: $priority
Assignee: $assignee | Labels: ${labels:-none}

Description:
$description
EOF
}
```

**Step 2: Test the formatter on a real ticket**

Run: `bash -c 'source jira-to-mem.sh; echo "$TICKETS" | jq -c ".[0]" | xargs -0 -I{} bash -c "format_ticket \"{}\""'`

Actually, simpler test — add a temporary debug line after `TICKETS` that formats the first ticket:

```bash
# Temporary test
echo "$TICKETS" | jq -c '.[0]' | { read -r t; format_ticket "$t"; }
```

Expected: Formatted text blob with key, summary, metadata, and description

**Step 3: Commit**

```bash
git add jira-to-mem.sh
git commit -m "feat: add ADF-to-text extraction and ticket formatting"
```

---

### Task 4: Implement dedup check and save_memory POST

**Files:**
- Modify: `jira-to-mem.sh`

**Step 1: Add the dedup and save functions**

```bash
# Check if a ticket already exists in claude-mem
ticket_exists() {
  local key="$1"

  local result
  result=$(curl -sf -G "$WORKER_URL/api/search" \
    --data-urlencode "query=$key" \
    --data-urlencode "project=$MEM_PROJECT" \
    --data-urlencode "limit=1" 2>/dev/null) || return 1

  local count
  count=$(echo "$result" | jq '.results | length' 2>/dev/null) || return 1

  [[ "$count" -gt 0 ]]
}

# Save a formatted ticket to claude-mem
save_ticket() {
  local title="$1"
  local text="$2"

  local payload
  payload=$(jq -n \
    --arg text "$text" \
    --arg title "$title" \
    --arg project "$MEM_PROJECT" \
    '{text: $text, title: $title, project: $project}')

  local response
  response=$(curl -sf -X POST "$WORKER_URL/api/memory/save" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>/dev/null)

  echo "$response" | jq -r '.id // empty'
}
```

**Step 2: Test dedup check**

Run manually:
```bash
curl -sf -G "http://127.0.0.1:37777/api/search" \
  --data-urlencode "query=INFRA-1609" \
  --data-urlencode "project=jira-infra" \
  --data-urlencode "limit=1" | jq
```

Expected: Empty results (nothing imported yet)

**Step 3: Commit**

```bash
git add jira-to-mem.sh
git commit -m "feat: add dedup check and save_memory HTTP calls"
```

---

### Task 5: Wire up the main processing loop with counters and summary

**Files:**
- Modify: `jira-to-mem.sh`

**Step 1: Add the main loop after TICKET_COUNT**

```bash
# Process each ticket
imported=0
skipped=0
failed=0

for i in $(seq 0 $((TICKET_COUNT - 1))); do
  ticket_json=$(echo "$TICKETS" | jq -c ".[$i]")
  key=$(echo "$ticket_json" | jq -r '.key')
  summary=$(echo "$ticket_json" | jq -r '.fields.summary // "No summary"')
  title="[$key] $summary"

  # Dedup check
  if [[ "$FORCE" == false ]] && ticket_exists "$key"; then
    vlog "SKIP $key (already exists)"
    skipped=$((skipped + 1))
    continue
  fi

  # Format and save
  text=$(format_ticket "$ticket_json")
  obs_id=$(save_ticket "$title" "$text")

  if [[ -n "$obs_id" ]]; then
    vlog "SAVED $key -> observation #$obs_id"
    imported=$((imported + 1))
  else
    log "FAILED $key"
    failed=$((failed + 1))
  fi

  # Progress indicator every 25 tickets
  if (( (i + 1) % 25 == 0 )); then
    log "Progress: $((i + 1))/$TICKET_COUNT processed..."
  fi
done

# Summary
echo ""
log "Done! Imported: $imported | Skipped: $skipped | Failed: $failed"
```

**Step 2: End-to-end test with small batch**

Run: `bash jira-to-mem.sh -l 5 -v`
Expected: 5 tickets imported, summary shows "Imported: 5 | Skipped: 0 | Failed: 0"

Run again: `bash jira-to-mem.sh -l 5 -v`
Expected: "Imported: 0 | Skipped: 5 | Failed: 0" (dedup working)

Run with force: `bash jira-to-mem.sh -l 5 -v --force`
Expected: "Imported: 5 | Skipped: 0 | Failed: 0" (force reimport)

**Step 3: Verify searchability in claude-mem**

Run in a Claude session: search claude-mem for a known ticket keyword to confirm the data is findable.

**Step 4: Commit**

```bash
git add jira-to-mem.sh
git commit -m "feat: wire up main processing loop with dedup, progress, and summary"
```

---

### Task 6: Full import and verification

**Step 1: Run the full import**

Run: `bash jira-to-mem.sh -v`
Expected: Imports up to 500 tickets with progress updates

**Step 2: Verify search works**

Test searches in claude-mem:
- Search for a specific ticket key
- Search for a domain term (e.g., "kubernetes", "SSL", "migration")
- Search with project filter "jira-infra"

**Step 3: Final commit**

```bash
git add -A
git commit -m "docs: add implementation plan and design docs"
```
