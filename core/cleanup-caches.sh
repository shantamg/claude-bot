#!/bin/bash
# cleanup-caches.sh — Clean build/package caches to prevent disk pressure.
# Runs weekly via cron. Also called by run-claude.sh on disk-related resource failures.
#
# Safe to run at any time — only deletes package manager caches that will be
# re-downloaded on demand. Does NOT touch node_modules, .local/share/pnpm store,
# or application data.

set -euo pipefail

LOGFILE="${BOT_LOG_DIR:-/var/log/lovely-bot}/cleanup-caches.log"

log() { echo "[$(date)] $*" >> "$LOGFILE"; }

log "Starting cache cleanup..."

FREED=0

# npm cache
if command -v npm &>/dev/null; then
  BEFORE=$(du -sm ~/.npm 2>/dev/null | awk '{print $1}' || echo 0)
  npm cache clean --force 2>/dev/null || true
  AFTER=$(du -sm ~/.npm 2>/dev/null | awk '{print $1}' || echo 0)
  DELTA=$((BEFORE - AFTER))
  [ "$DELTA" -gt 0 ] && FREED=$((FREED + DELTA))
  log "npm cache: freed ${DELTA}MB"
fi

# pip cache
if command -v pip &>/dev/null; then
  BEFORE=$(du -sm ~/.cache/pip 2>/dev/null | awk '{print $1}' || echo 0)
  pip cache purge 2>/dev/null || true
  AFTER=$(du -sm ~/.cache/pip 2>/dev/null | awk '{print $1}' || echo 0)
  DELTA=$((BEFORE - AFTER))
  [ "$DELTA" -gt 0 ] && FREED=$((FREED + DELTA))
  log "pip cache: freed ${DELTA}MB"
fi

# pnpm cache (not the store — just the HTTP cache)
if [ -d "$HOME/.cache/pnpm" ]; then
  BEFORE=$(du -sm ~/.cache/pnpm 2>/dev/null | awk '{print $1}' || echo 0)
  rm -rf "$HOME/.cache/pnpm"
  FREED=$((FREED + BEFORE))
  log "pnpm cache: freed ${BEFORE}MB"
fi

# node-gyp cache
if [ -d "$HOME/.cache/node-gyp" ]; then
  BEFORE=$(du -sm ~/.cache/node-gyp 2>/dev/null | awk '{print $1}' || echo 0)
  rm -rf "$HOME/.cache/node-gyp"
  FREED=$((FREED + BEFORE))
  log "node-gyp cache: freed ${BEFORE}MB"
fi

# whisper model cache (re-downloads on demand)
if [ -d "$HOME/.cache/whisper" ]; then
  BEFORE=$(du -sm ~/.cache/whisper 2>/dev/null | awk '{print $1}' || echo 0)
  rm -rf "$HOME/.cache/whisper"
  FREED=$((FREED + BEFORE))
  log "whisper cache: freed ${BEFORE}MB"
fi

# systemd journal — keep 200MB
if command -v journalctl &>/dev/null; then
  sudo journalctl --vacuum-size=200M 2>/dev/null || true
  log "journalctl vacuumed to 200MB"
fi

# git gc on the project repo (if configured)
if [ -n "${PROJECT_CHECKOUT:-}" ] && [ -d "${PROJECT_CHECKOUT}/.git" ]; then
  cd "$PROJECT_CHECKOUT"
  git gc --prune=now 2>/dev/null || true
  log "git gc completed on $PROJECT_CHECKOUT"
fi

DISK_PCT=$(df / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}' || echo "?")
log "Cleanup complete. Freed ~${FREED}MB total. Disk now at ${DISK_PCT}%."

echo "$FREED"
