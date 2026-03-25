#!/bin/bash
# setup-worktree.sh — Create git worktree (if on default branch) and cd into workspace.
# Sourced by run-claude.sh. Expects: SESSION_KEY, SKIP_WORKTREE, COMMAND_SLUG,
# WORKSPACE_NAME, LOGFILE, PROJECT_DIR, PROJECT_CHECKOUT, PROJECT_PATH,
# DEFAULT_BRANCH, BOT_NAME.
# Sets: WORKTREE_DIR, WORKTREE_BRANCH, WORKSPACE_DIR

cd "$PROJECT_DIR"
CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")

# Session-aware invocations need a stable directory for --resume to work
# (sessions are tied to the project path — different worktree = different project).
if [ -n "$SESSION_KEY" ]; then
  SKIP_WORKTREE=1
fi

WORKTREE_BRANCH=""
if [ "$SKIP_WORKTREE" -ne 1 ] && [ "$CURRENT_BRANCH" = "$DEFAULT_BRANCH" ]; then
  # Include ISSUE_NUMBER in branch name to avoid collisions when multiple agents
  # for the same workspace start within the same second (e.g., milestone dispatching
  # 8 issues to general-pr simultaneously).
  WORKTREE_BRANCH="feat/${COMMAND_SLUG}-${ISSUE_NUMBER:-$$}-$(date +%Y%m%d-%H%M%S)"
  WORKTREE_DIR="/tmp/${BOT_NAME}-worktree-${COMMAND_SLUG}-$$"
  echo "[$(date)] On $DEFAULT_BRANCH — creating worktree at $WORKTREE_DIR on branch $WORKTREE_BRANCH" >> "$LOGFILE"
  cd "$PROJECT_CHECKOUT"
  # Retry with jitter — concurrent git operations can fail due to git's internal
  # lock (.git/HEAD.lock, refs lock). When the dispatcher launches multiple agents
  # in rapid succession, they all compete for the same lock.
  WORKTREE_RETRIES=0
  WORKTREE_MAX_RETRIES=5
  while ! git worktree add "$WORKTREE_DIR" -b "$WORKTREE_BRANCH" 2>> "$LOGFILE"; do
    WORKTREE_RETRIES=$((WORKTREE_RETRIES + 1))
    if [ "$WORKTREE_RETRIES" -ge "$WORKTREE_MAX_RETRIES" ]; then
      echo "[$(date)] ERROR: git worktree add failed after $WORKTREE_MAX_RETRIES retries" >> "$LOGFILE"
      exit 1
    fi
    # Random delay 0.5-2.5s to spread out concurrent attempts
    JITTER=$(awk "BEGIN {srand($$+$WORKTREE_RETRIES); printf \"%.1f\", 0.5 + rand() * 2}")
    echo "[$(date)] git worktree add failed (attempt $WORKTREE_RETRIES/$WORKTREE_MAX_RETRIES), retrying in ${JITTER}s" >> "$LOGFILE"
    sleep "$JITTER"
  done
  # Navigate into the project path within the worktree
  if [ -n "$PROJECT_PATH" ]; then
    cd "$WORKTREE_DIR/$PROJECT_PATH"
  else
    cd "$WORKTREE_DIR"
  fi
fi

# ── Workspace mode: cd into the resolved workspace directory ──
WORKSPACE_DIR=""
if [ -n "$WORKSPACE_NAME" ]; then
  # Use cascade resolution: project workspaces first, then base-workspaces
  RESOLVED_WS=$(resolve_workspace "$WORKSPACE_NAME" 2>/dev/null || echo "")

  # If in a worktree, check workspace relative to the worktree root (bot/ lives
  # at the repo root, not inside the monorepo subpath)
  if [ -z "$RESOLVED_WS" ] && [ -n "$WORKTREE_DIR" ]; then
    WORKTREE_WS_DIR="$WORKTREE_DIR/bot/workspaces/$WORKSPACE_NAME"
    if [ -d "$WORKTREE_WS_DIR" ]; then
      RESOLVED_WS="$WORKTREE_WS_DIR"
    fi
  fi

  if [ -n "$RESOLVED_WS" ] && [ -d "$RESOLVED_WS" ]; then
    WORKSPACE_DIR="$RESOLVED_WS"
    cd "$WORKSPACE_DIR"
    echo "[$(date)] Workspace mode: cd into $WORKSPACE_DIR" >> "$LOGFILE"
  else
    echo "[$(date)] ERROR: Workspace directory not found: $WORKSPACE_NAME (checked project and base workspaces)" >> "$LOGFILE"
    exit 1
  fi
fi
