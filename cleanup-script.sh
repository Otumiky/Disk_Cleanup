#!/bin/bash

set -euo pipefail

# ==============================
# CONFIGURATION
# ==============================
LOG_DIR="/var/log"
# Fix #4: Targeted cache paths instead of broad /var/cache
CACHE_DIRS=("/tmp" "/var/tmp" "/var/cache/apt/archives" "/var/cache/nginx")
DAYS_OLD=7
LOG_FILE="/var/log/cleanup-script.log"
DRY_RUN=false

# ==============================
# ARGUMENT PARSING
# ==============================
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --days=*)  DAYS_OLD="${arg#--days=}" ;;
    --help)
      echo "Usage: sudo bash $0 [--dry-run] [--days=N]"
      echo "  --dry-run     Preview deletions without removing anything"
      echo "  --days=N      Target files older than N days (default: 7)"
      exit 0
      ;;
  esac
done

# ==============================
# FIX #2: ROOT CHECK
# ==============================
if [[ $EUID -ne 0 ]]; then
  echo "Error: This script must be run as root. Use: sudo bash $0"
  exit 1
fi

# ==============================
# HELPERS
# ==============================
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

run_or_dry() {
  local desc="$1"; local cmd="$2"
  if $DRY_RUN; then
    log "  [DRY-RUN] $desc"
  else
    eval "$cmd"
  fi
}

free_space() { df -h / | awk 'NR==2 {print $4}'; }

# ==============================
# FIX #10: ROTATE OWN LOG FILE
# ==============================
if [[ -f "$LOG_FILE" ]] && [[ $(du -m "$LOG_FILE" | cut -f1) -ge 10 ]]; then
  mv "$LOG_FILE" "${LOG_FILE}.1"
fi
touch "$LOG_FILE"

# ==============================
# START
# ==============================
log "================================================"
$DRY_RUN && log "DRY-RUN MODE — no files will be deleted"
log "Cleanup started"
log "Target: files older than ${DAYS_OLD} days"
# Fix #7: Report free space before
log "Free space BEFORE: $(free_space)"
log "================================================"

# ==============================
# DELETE OLD LOG FILES
# ==============================
log "--- Deleting log files older than $DAYS_OLD days ---"

# Fix #1: Exclude the script's own log file with ! -path
# Fix #3: Quote all variables used in find
# Fix #6: Honour dry-run mode
if $DRY_RUN; then
  find "$LOG_DIR" -type f -name "*.log" -mtime +"$DAYS_OLD" \
    ! -path "$LOG_FILE" -print | while read -r f; do
      log "  [DRY-RUN] Would delete: $f"
    done
else
  find "$LOG_DIR" -type f -name "*.log" -mtime +"$DAYS_OLD" \
    ! -path "$LOG_FILE" -exec rm -f {} \; -print | while read -r f; do
      log "  Deleted: $f"
    done
fi

# ==============================
# CLEAN CACHE DIRECTORIES
# ==============================
log "--- Cleaning cache directories ---"

for dir in "${CACHE_DIRS[@]}"; do
  # Fix #3: Validate and quote dir before use
  if [[ ! -d "$dir" ]]; then
    log "  Skipping $dir — directory not found"
    continue
  fi

  log "  Cleaning $dir (files older than ${DAYS_OLD}d)..."

  if $DRY_RUN; then
    # Fix #9: mindepth 1 prevents deleting the top-level dir itself
    find "$dir" -mindepth 1 -type f -mtime +"$DAYS_OLD" -print | while read -r f; do
      log "  [DRY-RUN] Would delete: $f"
    done
  else
    find "$dir" -mindepth 1 -type f -mtime +"$DAYS_OLD" \
      -exec rm -f {} \; -print | while read -r f; do
        log "  Deleted: $f"
      done
  fi
done

# ==============================
# TRUNCATE LARGE LOG FILES (>100MB)
# ==============================
log "--- Truncating large log files (>100MB) ---"

# Fix #1: Exclude own log file
# Fix #8: Log the file size before truncating
find "$LOG_DIR" -type f -name "*.log" -size +100M \
  ! -path "$LOG_FILE" -print | while read -r f; do
    size=$(du -sh "$f" 2>/dev/null | cut -f1)
    if $DRY_RUN; then
      log "  [DRY-RUN] Would truncate: $f (currently ${size})"
    else
      log "  Truncating: $f (was ${size})"
      truncate -s 0 "$f"
    fi
  done

# ==============================
# REMOVE EMPTY DIRECTORIES
# ==============================
log "--- Removing empty directories ---"

# Fix #9: mindepth 1 so the top-level dirs (/tmp, /var/tmp etc.) are never removed
run_or_dry \
  "Remove empty dirs in $LOG_DIR" \
  "find '$LOG_DIR' -mindepth 1 -type d -empty -delete 2>/dev/null || true"

for dir in "${CACHE_DIRS[@]}"; do
  [[ -d "$dir" ]] || continue
  run_or_dry \
    "Remove empty dirs in $dir" \
    "find '$dir' -mindepth 1 -type d -empty -delete 2>/dev/null || true"
done

# ==============================
# END
# ==============================
log "================================================"
# Fix #7: Report free space after
log "Free space AFTER:  $(free_space)"
$DRY_RUN && log "DRY-RUN complete — re-run without --dry-run to apply changes"
log "Cleanup completed"
log "================================================"