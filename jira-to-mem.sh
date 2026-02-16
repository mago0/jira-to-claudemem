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
