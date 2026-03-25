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
  WORKTREE_BRANCH="feat/${COMMAND_SLUG}-$(date +%Y%m%d-%H%M%S)"
  WORKTREE_DIR="/tmp/${BOT_NAME}-worktree-${COMMAND_SLUG}-$$"
  echo "[$(date)] On $DEFAULT_BRANCH — creating worktree at $WORKTREE_DIR on branch $WORKTREE_BRANCH" >> "$LOGFILE"
  cd "$PROJECT_CHECKOUT"
  git worktree add "$WORKTREE_DIR" -b "$WORKTREE_BRANCH" 2>> "$LOGFILE"
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
