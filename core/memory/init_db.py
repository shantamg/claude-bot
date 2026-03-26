#!/usr/bin/env python3
"""Initialize the sqlite-vec memory database.

Creates the schema at DATA_DIR/memory.db (default: /opt/claude-bot/data/memory.db).
Safe to run multiple times — uses IF NOT EXISTS throughout.
"""

import os
import sqlite3
import sqlite_vec

DATA_DIR = os.environ.get("CLAUDE_BOT_DATA_DIR", "/opt/claude-bot/data")
DB_PATH = os.path.join(DATA_DIR, "memory.db")
EMBEDDING_DIM = 1024  # Titan Embed Text V2 default


def init_db(db_path: str = DB_PATH) -> sqlite3.Connection:
    """Create the memory database and return an open connection."""
    os.makedirs(os.path.dirname(db_path), exist_ok=True)

    db = sqlite3.connect(db_path)
    db.enable_load_extension(True)
    sqlite_vec.load(db)
    db.enable_load_extension(False)

    db.executescript(f"""
        CREATE TABLE IF NOT EXISTS embeddings (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            collection    TEXT    NOT NULL,
            source_type   TEXT    NOT NULL,
            source_ref    TEXT    NOT NULL,
            content_hash  TEXT    NOT NULL,
            content_snippet TEXT  NOT NULL,
            updated_at    TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        );

        CREATE INDEX IF NOT EXISTS idx_embeddings_collection
            ON embeddings(collection);

        CREATE INDEX IF NOT EXISTS idx_embeddings_content_hash
            ON embeddings(content_hash);

        CREATE VIRTUAL TABLE IF NOT EXISTS vec_embeddings USING vec0(
            embedding float[{EMBEDDING_DIM}]
        );
    """)

    db.commit()
    return db


if __name__ == "__main__":
    db = init_db()
    # Verify tables exist
    tables = [r[0] for r in db.execute(
        "SELECT name FROM sqlite_master WHERE type IN ('table','view') ORDER BY name"
    ).fetchall()]
    print(f"Database initialized at {DB_PATH}")
    print(f"Tables: {', '.join(tables)}")
    db.close()
