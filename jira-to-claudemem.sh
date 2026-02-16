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
Usage: $(basename "$0") [PROJECT] [OPTIONS]

Ingest Jira tickets into claude-mem for searchable institutional memory.

Examples:
  $(basename "$0") INFRA
  $(basename "$0") DEVOPS -l 200 -v

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
    -*) echo "Unknown option: $1"; usage ;;
    *) PROJECT="$1"; shift ;;
  esac
done

# Auto-derive mem project from Jira project if not explicitly set
if [[ "$MEM_PROJECT" == "jira-infra" ]] && [[ "$PROJECT" != "INFRA" ]]; then
  MEM_PROJECT="jira-$(echo "$PROJECT" | tr '[:upper:]' '[:lower:]')"
fi

log() { echo "[$(date +%H:%M:%S)] $*" >&2; }
vlog() { [[ "$VERBOSE" == true ]] && log "$*" || true; }

# Health check
if ! curl -sf "$WORKER_URL/api/health" > /dev/null 2>&1; then
  echo "ERROR: claude-mem worker not running on $WORKER_URL"
  echo "Start a Claude Code session with claude-mem enabled first."
  exit 1
fi
log "claude-mem worker is healthy"

# Fetch tickets using cursor-based pagination (key < last_key)
# The jira-cli --paginate offset is broken, so we use JQL key filtering instead
fetch_tickets() {
  local page_size=100
  local total_fetched=0
  local all_tickets="[]"
  local cursor=""

  log "Fetching up to $LIMIT tickets from $PROJECT..."

  while [[ $total_fetched -lt $LIMIT ]]; do
    local remaining=$((LIMIT - total_fetched))
    local fetch_count=$((remaining < page_size ? remaining : page_size))

    vlog "Fetching page (cursor: ${cursor:-start}, limit $fetch_count)..."

    local page
    if [[ -n "$cursor" ]]; then
      page=$(jira issue list -p "$PROJECT" --raw --paginate "0:$fetch_count" \
        -q "key < $cursor" 2>/dev/null)
    else
      page=$(jira issue list -p "$PROJECT" --raw --paginate "0:$fetch_count" \
        2>/dev/null)
    fi

    if [[ $? -ne 0 ]] || [[ -z "$page" ]]; then
      log "WARNING: Failed to fetch page at cursor ${cursor:-start}"
      break
    fi

    local count
    count=$(echo "$page" | jq 'length')

    if [[ "$count" -eq 0 ]]; then
      vlog "No more tickets"
      break
    fi

    # Get the last key for cursor-based pagination
    cursor=$(echo "$page" | jq -r '.[-1].key')

    all_tickets=$(echo "$all_tickets $page" | jq -s '.[0] + .[1]')
    total_fetched=$((total_fetched + count))

    vlog "Fetched $count tickets (total: $total_fetched, next cursor: $cursor)"
  done

  log "Fetched $total_fetched tickets total"
  echo "$all_tickets"
}

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

  cat <<EOF
[$key] $summary
Status: $status | Resolution: $resolution | Type: $type | Priority: $priority
Assignee: $assignee | Labels: ${labels:-none}

Description:
$description
EOF
}

TICKETS=$(fetch_tickets)
TICKET_COUNT=$(echo "$TICKETS" | jq 'length')
log "Processing $TICKET_COUNT tickets..."

# Check if a ticket already exists in claude-mem (direct SQLite query for precision)
CLAUDE_MEM_DB="$HOME/.claude-mem/claude-mem.db"
ticket_exists() {
  local key="$1"

  local count
  count=$(sqlite3 "$CLAUDE_MEM_DB" \
    "SELECT COUNT(*) FROM observations WHERE project = '$MEM_PROJECT' AND title LIKE '[${key}]%';" 2>/dev/null) || return 1

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
echo "" >&2
log "Done! Imported: $imported | Skipped: $skipped | Failed: $failed"
