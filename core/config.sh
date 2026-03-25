#!/bin/bash
# config.sh — Load claude-bot configuration from bot.yaml and export standard env vars.
#
# Every core script sources this file to get project-agnostic paths and settings.
# Requires: yq (lightweight YAML parser)
#
# Exported variables:
#   BOT_HOME           — Base directory on the instance (default: /opt/claude-bot)
#   BOT_NAME           — Instance name from bot.yaml (default: claude-bot)
#   BOT_LOG_DIR        — Log directory (default: /var/log/$BOT_NAME)
#   LOCK_PREFIX        — Lock file prefix (default: /tmp/$BOT_NAME)
#   SCRIPTS_DIR        — Path to core scripts
#   QUEUE_DIR          — Request queue directory
#   STATE_DIR          — Runtime state directory
#   HEARTBEAT_DIR      — Heartbeat files for activity tracking
#   CLAIMS_DIR         — Message deduplication claims
#   ACTIVE_DIR         — Active agent directories
#
#   PROJECT_REPO       — GitHub repo (owner/name)
#   PROJECT_PATH       — Subdirectory within the repo (for monorepos)
#   PROJECT_DIR        — Full path to the project working directory
#   PROJECT_CHECKOUT   — Path to the repo checkout on disk
#   BOT_USERNAME       — GitHub bot username
#   DEFAULT_BRANCH     — Branch to sync from (default: main)
#
#   WORKSPACES_DIR     — Project workspace directory
#   BASE_WORKSPACES_DIR — Framework base workspace directory
#
# Resource thresholds (read from bot.yaml, overridable via env):
#   RESOURCE_MEMORY_THRESHOLD, RESOURCE_LOAD_THRESHOLD,
#   RESOURCE_DISK_THRESHOLD, RESOURCE_DISK_WARN_THRESHOLD,
#   MAX_CONCURRENT, RESERVED_INTERACTIVE_SLOTS
#
# Process cleanup thresholds:
#   IDLE_THRESHOLD_MIN, TRIAGE_MIN_AGE, HARD_CAP_MIN, AGENT_ARCHIVE_TTL_MIN

# ── Base paths ──────────────────────────────────────────────────────────────────
BOT_HOME="${CLAUDE_BOT_HOME:-/opt/claude-bot}"

# Source secrets (non-fatal if missing — interactive/test runs may not have one)
# shellcheck disable=SC1091
source "$BOT_HOME/.env" 2>/dev/null || true

# ── Read bot.yaml ───────────────────────────────────────────────────────────────
_yaml() {
  yq -r "$1" "$BOT_HOME/bot.yaml" 2>/dev/null || echo "$2"
}

BOT_NAME=$(_yaml '.name // "claude-bot"' "claude-bot")
BOT_LOG_DIR="/var/log/$BOT_NAME"
LOCK_PREFIX="/tmp/$BOT_NAME"
SCRIPTS_DIR="$BOT_HOME/scripts"
QUEUE_DIR="$BOT_HOME/queue"
STATE_DIR="$BOT_HOME/state"
HEARTBEAT_DIR="$STATE_DIR/heartbeats"
CLAIMS_DIR="$STATE_DIR/claims"

# ── Project paths ───────────────────────────────────────────────────────────────
PROJECT_REPO=$(_yaml '.project.repo // ""' "")
PROJECT_PATH=$(_yaml '.project.path // ""' "")
PROJECT_CHECKOUT=$(_yaml '.project.checkout // ""' "")
BOT_USERNAME=$(_yaml '.project.bot_username // ""' "")
DEFAULT_BRANCH=$(_yaml '.project.default_branch // "main"' "main")

# Derive full project directory
if [ -n "$PROJECT_CHECKOUT" ]; then
  PROJECT_DIR="${PROJECT_CHECKOUT}${PROJECT_PATH:+/$PROJECT_PATH}"
else
  PROJECT_DIR=""
fi

# ── Workspace paths ─────────────────────────────────────────────────────────────
# bot/ config lives at the repo root (PROJECT_CHECKOUT), not inside the monorepo
# subpath (PROJECT_DIR). This matters for monorepos where path: is set.
if [ -n "$PROJECT_CHECKOUT" ]; then
  WORKSPACES_DIR="$PROJECT_CHECKOUT/bot/workspaces"
else
  WORKSPACES_DIR=""
fi
ACTIVE_DIR="$BOT_HOME/state/active"
BASE_WORKSPACES_DIR="${CLAUDE_BOT_FRAMEWORK_DIR:-$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")")}/base-workspaces"

# ── Resource thresholds (env overrides bot.yaml, bot.yaml overrides defaults) ──
RESOURCE_MEMORY_THRESHOLD="${RESOURCE_MEMORY_THRESHOLD:-$(_yaml '.resources.memory_threshold // 85' "85")}"
RESOURCE_LOAD_THRESHOLD="${RESOURCE_LOAD_THRESHOLD:-$(_yaml '.resources.load_threshold // 3.0' "3.0")}"
RESOURCE_DISK_THRESHOLD="${RESOURCE_DISK_THRESHOLD:-$(_yaml '.resources.disk_threshold // 90' "90")}"
RESOURCE_DISK_WARN_THRESHOLD="${RESOURCE_DISK_WARN_THRESHOLD:-$(_yaml '.resources.disk_warn_threshold // 80' "80")}"
MAX_CONCURRENT="${MAX_CONCURRENT:-$(_yaml '.resources.max_concurrent // 5' "5")}"
RESERVED_INTERACTIVE_SLOTS="${RESERVED_INTERACTIVE_SLOTS:-$(_yaml '.resources.reserved_interactive // 2' "2")}"

# ── Process cleanup thresholds ──────────────────────────────────────────────────
IDLE_THRESHOLD_MIN="${IDLE_THRESHOLD_MIN:-$(_yaml '.process_cleanup.idle_threshold_min // 5' "5")}"
TRIAGE_MIN_AGE="${TRIAGE_MIN_AGE:-$(_yaml '.process_cleanup.triage_min_age // 10' "10")}"
HARD_CAP_MIN="${HARD_CAP_MIN:-$(_yaml '.process_cleanup.hard_cap_min // 45' "45")}"
AGENT_ARCHIVE_TTL_MIN="${AGENT_ARCHIVE_TTL_MIN:-$(_yaml '.process_cleanup.agent_archive_ttl_min // 60' "60")}"

# ── Slack config ────────────────────────────────────────────────────────────────
OPS_CHANNEL_ENV=$(_yaml '.slack.ops_channel_env // "BOT_OPS_CHANNEL_ID"' "BOT_OPS_CHANNEL_ID")
BOT_OPS_CHANNEL_ID="${!OPS_CHANNEL_ENV:-${BOT_OPS_CHANNEL_ID:-}}"

# ── Export everything ───────────────────────────────────────────────────────────
export BOT_HOME BOT_NAME BOT_LOG_DIR LOCK_PREFIX SCRIPTS_DIR QUEUE_DIR STATE_DIR
export HEARTBEAT_DIR CLAIMS_DIR ACTIVE_DIR
export PROJECT_REPO PROJECT_PATH PROJECT_CHECKOUT PROJECT_DIR BOT_USERNAME DEFAULT_BRANCH
export WORKSPACES_DIR BASE_WORKSPACES_DIR
export RESOURCE_MEMORY_THRESHOLD RESOURCE_LOAD_THRESHOLD RESOURCE_DISK_THRESHOLD RESOURCE_DISK_WARN_THRESHOLD
export MAX_CONCURRENT RESERVED_INTERACTIVE_SLOTS
export IDLE_THRESHOLD_MIN TRIAGE_MIN_AGE HARD_CAP_MIN AGENT_ARCHIVE_TTL_MIN
export BOT_OPS_CHANNEL_ID

# ── Helper: resolve workspace path using cascade ───────────────────────────────
# Usage: resolve_workspace "health-check" → prints the absolute path to the workspace dir
resolve_workspace() {
  local ws_name="$1"
  # 1. Project workspaces (highest priority)
  if [ -n "$WORKSPACES_DIR" ] && [ -d "$WORKSPACES_DIR/$ws_name" ]; then
    echo "$WORKSPACES_DIR/$ws_name"
    return 0
  fi
  # 2. Base workspaces (framework default)
  if [ -d "$BASE_WORKSPACES_DIR/$ws_name" ]; then
    echo "$BASE_WORKSPACES_DIR/$ws_name"
    return 0
  fi
  return 1
}
