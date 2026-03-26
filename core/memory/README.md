# Memory: sqlite-vec Embedding Pipeline

Vector memory store for persona-scoped knowledge. Uses sqlite-vec for storage and AWS Bedrock Titan Embeddings V2 for vector generation.

## Architecture Decisions

**Why sqlite-vec?** Single-file database, no external service, ~2MB overhead. Fits the t3.medium memory budget easily. The `vec0` virtual table provides fast cosine-distance KNN search without a separate vector DB process.

**Why Bedrock Titan Embeddings V2?** Already in AWS (no additional vendor), no local GPU/model needed, 1024-dimension vectors with normalization. Pricing is low (~$0.00002 per 1K tokens). Stays well within t3.medium memory since embedding happens server-side.

**Why not a local model?** t3.medium has 4GB RAM. Even small local embedding models (e.g., all-MiniLM) need ~300MB resident. Bedrock offloads that entirely.

## Schema

```
embeddings (SQLite table)
├── id              INTEGER PRIMARY KEY AUTOINCREMENT
├── collection      TEXT NOT NULL          -- scoped namespace (e.g. "engineer", "pm")
├── source_type     TEXT NOT NULL          -- "issue", "slack", "pr", "doc", etc.
├── source_ref      TEXT NOT NULL          -- "#123", "C07ABC/1234", etc.
├── content_hash    TEXT NOT NULL          -- SHA-256 prefix for dedup
├── content_snippet TEXT NOT NULL          -- first 500 chars of source content
└── updated_at      TEXT NOT NULL          -- ISO-8601 UTC timestamp

vec_embeddings (sqlite-vec virtual table)
└── embedding       float[1024]           -- Titan V2 vector, cosine-normalized

Indexes: collection, content_hash
```

The `embeddings` and `vec_embeddings` tables are linked by rowid. Every metadata row in `embeddings` has a corresponding vector in `vec_embeddings` at the same rowid.

## Files

| File | Purpose |
|------|---------|
| `init_db.py` | Create/migrate the database schema |
| `embed.py` | Generate embeddings via Bedrock Titan V2 |
| `query.py` | Insert, search, and delete operations |

## Usage

### Initialize the database

```bash
python3 /opt/claude-bot/scripts/memory/init_db.py
```

### Generate embeddings

```bash
# Single text
python3 /opt/claude-bot/scripts/memory/embed.py "some text"

# Batch from stdin
echo -e "line one\nline two" | python3 /opt/claude-bot/scripts/memory/embed.py --stdin
```

### Library usage

```python
from memory.embed import get_embeddings
from memory.query import MemoryStore

store = MemoryStore()

# Insert
vectors = get_embeddings(["Bug in auth flow causes 500 on login"])
store.insert("engineer", "issue", "#456", "Bug in auth flow causes 500 on login", vectors[0])

# Search
query_vec = get_embeddings(["authentication error"])[0]
results = store.search("engineer", query_vec, limit=5)
for r in results:
    print(f"{r['source_ref']}: {r['content_snippet'][:80]}  (dist={r['distance']:.4f})")

store.close()
```

## Prerequisites

- **Python packages:** `sqlite-vec`, `boto3`
- **AWS IAM:** The EC2 instance role needs `bedrock:InvokeModel` permission for `amazon.titan-embed-text-v2:0` in `us-west-2`
- **Database directory:** Created automatically at `/opt/claude-bot/data/` (override with `CLAUDE_BOT_DATA_DIR` env var)

## Deployment

Scripts are deployed to `/opt/claude-bot/scripts/memory/` via the standard `deploy.sh` flow. The `data/` directory is created on first `init_db.py` run.
