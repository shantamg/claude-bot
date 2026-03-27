#!/bin/bash
# List documents in the vector memory knowledge base.
# Used by the scientist persona to report what's in its library.
#
# Usage:
#   list-knowledge.sh                    # list all collections
#   list-knowledge.sh --collection science  # list science docs only

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB_PATH="${CLAUDE_BOT_DATA_DIR:-/opt/claude-bot/data}/memory.db"

COLLECTION=""
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --collection) COLLECTION="$2"; shift 2 ;;
    *) shift ;;
  esac
done

python3 - "$DB_PATH" "$COLLECTION" << 'PYEOF'
import sqlite3, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)) or ".")

db_path = sys.argv[1]
collection_filter = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else None

db = sqlite3.connect(db_path)

# Get collection summary
if collection_filter:
    collections = [(collection_filter,)]
else:
    collections = db.execute("SELECT DISTINCT collection FROM embeddings ORDER BY collection").fetchall()

for (collection,) in collections:
    total = db.execute("SELECT COUNT(*) FROM embeddings WHERE collection = ?", (collection,)).fetchone()[0]
    print(f"\n## {collection} ({total} chunks)")

    if collection == "science":
        # Group by document and show titles
        rows = db.execute("""
            SELECT source_ref, content_snippet, COUNT(*) as chunks
            FROM embeddings WHERE collection = 'science'
            GROUP BY SUBSTR(source_ref, 1, INSTR(source_ref || ':', ':') + 16)
        """).fetchall()
        # Deduplicate by doc hash
        docs = {}
        for ref, snippet, count in rows:
            parts = ref.split(":")
            doc_hash = parts[1] if len(parts) > 1 else ref
            if doc_hash not in docs:
                # Extract title from first heading in snippet
                for line in snippet.split("\n"):
                    line = line.strip().lstrip("#").strip()
                    if line and not line.startswith("![") and not line.startswith("|"):
                        docs[doc_hash] = {"title": line[:80], "chunks": 0}
                        break
                if doc_hash not in docs:
                    docs[doc_hash] = {"title": "(untitled)", "chunks": 0}
            docs[doc_hash]["chunks"] += count

        for doc_hash, info in docs.items():
            print(f"  - **{info['title']}** ({info['chunks']} sections)")

    elif collection == "code":
        # Show file count
        files = db.execute("""
            SELECT COUNT(DISTINCT source_ref) FROM embeddings WHERE collection = 'code'
        """).fetchone()[0]
        print(f"  {files} source files indexed")

    elif collection == "issues":
        issues = db.execute("SELECT COUNT(*) FROM embeddings WHERE collection = 'issues' AND source_type = 'issue'").fetchone()[0]
        comments = db.execute("SELECT COUNT(*) FROM embeddings WHERE collection = 'issues' AND source_type = 'comment'").fetchone()[0]
        print(f"  {issues} issues + {comments} comments indexed")

    else:
        print(f"  {total} entries")

db.close()
PYEOF
