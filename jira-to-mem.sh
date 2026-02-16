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

log() { echo "[$(date +%H:%M:%S)] $*" >&2; }
vlog() { [[ "$VERBOSE" == true ]] && log "$*" || true; }

# Health check
if ! curl -sf "$WORKER_URL/api/health" > /dev/null 2>&1; then
  echo "ERROR: claude-mem worker not running on $WORKER_URL"
  echo "Start a Claude Code session with claude-mem enabled first."
  exit 1
fi
log "claude-mem worker is healthy"

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
