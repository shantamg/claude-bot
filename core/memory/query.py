#!/usr/bin/env python3
"""Query the memory database: insert embeddings and search by similarity.

Usage as library:
    from query import MemoryStore
    store = MemoryStore()
    store.insert("my-collection", "issue", "#123", "some content", vector)
    results = store.search("my-collection", query_vector, limit=5)
"""

import hashlib
import sqlite3
from typing import Optional

import sqlite_vec

from init_db import DB_PATH, EMBEDDING_DIM, init_db


def _content_hash(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()[:16]


class MemoryStore:
    """High-level interface for the vector memory database."""

    def __init__(self, db_path: str = DB_PATH):
        self.db = init_db(db_path)

    def insert(
        self,
        collection: str,
        source_type: str,
        source_ref: str,
        content: str,
        embedding: list[float],
    ) -> int:
        """Insert a memory entry. Returns the row id.

        If an entry with the same collection + content_hash already exists,
        it is updated instead of duplicated.
        """
        ch = _content_hash(content)
        snippet = content[:500]

        # Check for existing entry with same collection + hash
        existing = self.db.execute(
            "SELECT id FROM embeddings WHERE collection = ? AND content_hash = ?",
            (collection, ch),
        ).fetchone()

        if existing:
            row_id = existing[0]
            self.db.execute(
                """UPDATE embeddings
                   SET source_type = ?, source_ref = ?, content_snippet = ?,
                       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                   WHERE id = ?""",
                (source_type, source_ref, snippet, row_id),
            )
            # Update the vector
            self.db.execute(
                "DELETE FROM vec_embeddings WHERE rowid = ?", (row_id,)
            )
            self.db.execute(
                "INSERT INTO vec_embeddings(rowid, embedding) VALUES (?, ?)",
                (row_id, sqlite_vec.serialize_float32(embedding)),
            )
        else:
            cursor = self.db.execute(
                """INSERT INTO embeddings
                   (collection, source_type, source_ref, content_hash, content_snippet)
                   VALUES (?, ?, ?, ?, ?)""",
                (collection, source_type, source_ref, ch, snippet),
            )
            row_id = cursor.lastrowid
            self.db.execute(
                "INSERT INTO vec_embeddings(rowid, embedding) VALUES (?, ?)",
                (row_id, sqlite_vec.serialize_float32(embedding)),
            )

        self.db.commit()
        return row_id

    def search(
        self,
        collection: str,
        query_embedding: list[float],
        limit: int = 10,
    ) -> list[dict]:
        """Search for similar entries within a collection.

        Returns list of dicts with keys: id, source_type, source_ref,
        content_snippet, distance, updated_at.
        """
        rows = self.db.execute(
            """SELECT e.id, e.source_type, e.source_ref, e.content_snippet,
                      v.distance, e.updated_at
               FROM vec_embeddings v
               JOIN embeddings e ON e.id = v.rowid
               WHERE v.embedding MATCH ?
                 AND e.collection = ?
                 AND k = ?
               ORDER BY v.distance""",
            (sqlite_vec.serialize_float32(query_embedding), collection, limit),
        ).fetchall()

        return [
            {
                "id": r[0],
                "source_type": r[1],
                "source_ref": r[2],
                "content_snippet": r[3],
                "distance": r[4],
                "updated_at": r[5],
            }
            for r in rows
        ]

    def delete_collection(self, collection: str) -> int:
        """Delete all entries in a collection. Returns count deleted."""
        ids = [r[0] for r in self.db.execute(
            "SELECT id FROM embeddings WHERE collection = ?", (collection,)
        ).fetchall()]

        if ids:
            placeholders = ",".join("?" * len(ids))
            self.db.execute(
                f"DELETE FROM vec_embeddings WHERE rowid IN ({placeholders})", ids
            )
            self.db.execute(
                f"DELETE FROM embeddings WHERE id IN ({placeholders})", ids
            )
            self.db.commit()

        return len(ids)

    def close(self):
        self.db.close()
