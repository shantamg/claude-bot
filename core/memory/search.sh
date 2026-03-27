#!/bin/bash
# Shell wrapper for MCP memory search.
# For workspaces that prefer shell-based access over MCP tool calls.
#
# Usage:
#   search.sh "authentication error"                    # search project history (issues+docs)
#   search.sh --code "authentication error"             # search code collection
#   search.sh --collections "issues,code" "auth error"  # search specific collections
#   search.sh --top-k 10 "query"                        # return more results
#
# Environment:
#   CLAUDE_PERSONA  — persona name for collection scoping (default: "default")
#   CLAUDE_BOT_DATA_DIR — override data directory (default: /opt/claude-bot/data)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
TOP_K=5
COLLECTIONS=""
MODE="history"

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --code)
      MODE="code"
      shift
      ;;
    --collections)
      COLLECTIONS="$2"
      shift 2
      ;;
    --top-k)
      TOP_K="$2"
      shift 2
      ;;
    -*)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
    *)
      QUERY="$1"
      shift
      ;;
  esac
done

if [ -z "${QUERY:-}" ]; then
  echo "Usage: search.sh [--code|--collections LIST] [--top-k N] QUERY" >&2
  exit 1
fi

# Build the Python command based on mode
python3 -c "
import sys, os, json
sys.path.insert(0, '$SCRIPT_DIR')

from embed import get_embeddings
from query import MemoryStore

import yaml

SCOPE_FILE = os.path.join('$SCRIPT_DIR', 'memory-scope.yaml')

def load_allowed():
    with open(SCOPE_FILE) as f:
        data = yaml.safe_load(f)
    personas = data.get('personas', {})
    persona = os.environ.get('CLAUDE_PERSONA', 'default')
    return personas.get(persona, personas.get('default', ['issues', 'docs']))

# Determine collections
collections_arg = '$COLLECTIONS'
mode = '$MODE'
if collections_arg:
    requested = [c.strip() for c in collections_arg.split(',')]
elif mode == 'code':
    requested = ['code']
else:
    requested = ['issues', 'docs']

allowed = set(load_allowed())
collections = [c for c in requested if c in allowed]

if not collections:
    print(json.dumps({'error': f'No accessible collections. Allowed: {sorted(allowed)}'}))
    sys.exit(1)

query_vec = get_embeddings(['''$QUERY'''])[0]
store = MemoryStore()
results = []
for coll in collections:
    for hit in store.search(coll, query_vec, limit=$TOP_K):
        results.append({
            'content': hit['content_snippet'],
            'source_type': hit['source_type'],
            'source_ref': hit['source_ref'],
            'collection': coll,
            'similarity': round(1.0 - hit['distance'], 4),
        })
store.close()

results.sort(key=lambda r: r['similarity'], reverse=True)
results = results[:$TOP_K]

for r in results:
    print(f\"[{r['similarity']:.4f}] ({r['collection']}/{r['source_type']}) {r['source_ref']}\")
    print(f\"  {r['content'][:200]}\")
    print()
"
