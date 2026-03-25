#!/bin/bash
# parse-args.sh — Parse run-claude.sh flags and positional arguments.
# Sourced by run-claude.sh. Sets: WORKSPACE_NAME, COMMAND_SLUG, SESSION_KEY,
# SKIP_WORKTREE, PROMPT, PROMPT_FILE, MSG_TS

# Derive a deterministic UUID v5 from a human-readable session key.
session_key_to_uuid() {
  python3 -c "import uuid, sys; print(uuid.uuid5(uuid.NAMESPACE_URL, sys.argv[1]))" "$1"
}

WORKSPACE_NAME=""
COMMAND_SLUG=""
SESSION_KEY=""
SKIP_WORKTREE=0

# Parse named flags (order-independent)
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --workspace)
      WORKSPACE_NAME="${2:?--workspace requires a workspace name}"
      WORKSPACE_NAME="${WORKSPACE_NAME//[^a-zA-Z0-9_-]/_}"
      COMMAND_SLUG="ws-${WORKSPACE_NAME}"
      shift 2
      ;;
    --session)
      SESSION_KEY="${2:?--session requires a session key}"
      shift 2
      ;;
    --no-worktree)
      SKIP_WORKTREE=1
      shift 1
      ;;
    *)
      break
      ;;
  esac
done

# Legacy positional: if no --workspace was found, first arg is COMMAND_SLUG
if [ -z "$COMMAND_SLUG" ]; then
  COMMAND_SLUG="${1//[^a-zA-Z0-9_-]/_}"
  shift 1
fi

PROMPT="${1:-}"
PROMPT_FILE="${2:-}"
MSG_TS="${3:-}"
