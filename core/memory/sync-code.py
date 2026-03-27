#!/usr/bin/env python3
"""Sync codebase files into the 'code' vector memory collection.

Runs incrementally: only re-embeds files changed since the last sync commit.
Designed to run after git pull on main via a post-pull hook.

Usage:
    # Full initial sync
    python3 sync-code.py --repo /path/to/repo

    # Incremental sync (default — reads last sync commit from state file)
    python3 sync-code.py --repo /path/to/repo

    # Force full re-sync
    python3 sync-code.py --repo /path/to/repo --full
"""

import argparse
import hashlib
import logging
import os
import subprocess
import sys
import time
from pathlib import Path

# Add parent directory so we can import sibling modules
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from embed import get_embeddings
from init_db import DB_PATH, init_db
from query import MemoryStore

# ── Configuration ────────────────────────────────────────────────────────────

COLLECTION = "code"
SOURCE_TYPE = "file"

# File extensions to index
INCLUDE_EXTENSIONS = {
    ".ts", ".tsx", ".py", ".sh", ".md", ".json", ".yaml", ".yml",
    ".js", ".jsx", ".mjs", ".css", ".sql", ".prisma", ".toml",
}

# Directories to skip
SKIP_DIRS = {
    "node_modules", ".git", "dist", "build", ".next", "__pycache__",
    ".expo", ".turbo", "coverage", ".nyc_output", "vendor",
}

# Files to skip
SKIP_FILES = {
    "package-lock.json", "yarn.lock", "pnpm-lock.yaml",
}

# Max file size to index (skip very large generated files)
MAX_FILE_SIZE = 100_000  # 100KB

# Chunking parameters
# ~500 tokens ≈ ~2000 chars for code (code tokens are shorter than prose)
CHUNK_SIZE = 2000  # characters
CHUNK_OVERLAP = 200  # characters of overlap between chunks

DATA_DIR = os.environ.get("CLAUDE_BOT_DATA_DIR", "/opt/claude-bot/data")
STATE_FILE = os.path.join(DATA_DIR, "code-sync-last-commit")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [sync-code] %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%SZ",
)
log = logging.getLogger(__name__)


# ── Helpers ──────────────────────────────────────────────────────────────────

def get_head_commit(repo_path: str) -> str:
    """Get the current HEAD commit SHA."""
    result = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=repo_path, capture_output=True, text=True, check=True,
    )
    return result.stdout.strip()


def get_last_sync_commit() -> str | None:
    """Read the last synced commit SHA from the state file."""
    if os.path.exists(STATE_FILE):
        return Path(STATE_FILE).read_text().strip() or None
    return None


def save_sync_commit(sha: str):
    """Write the synced commit SHA to the state file."""
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    Path(STATE_FILE).write_text(sha + "\n")


def get_changed_files(repo_path: str, since_commit: str | None) -> list[str]:
    """Get list of files changed since the given commit.

    If since_commit is None, returns all tracked files (full sync).
    Returns paths relative to repo root.
    """
    if since_commit is None:
        # Full sync: list all tracked files
        result = subprocess.run(
            ["git", "ls-files"],
            cwd=repo_path, capture_output=True, text=True, check=True,
        )
        return [f for f in result.stdout.strip().split("\n") if f]

    result = subprocess.run(
        ["git", "diff", "--name-only", f"{since_commit}..HEAD"],
        cwd=repo_path, capture_output=True, text=True, check=True,
    )
    return [f for f in result.stdout.strip().split("\n") if f]


def get_deleted_files(repo_path: str, since_commit: str) -> list[str]:
    """Get list of files deleted since the given commit."""
    result = subprocess.run(
        ["git", "diff", "--name-only", "--diff-filter=D", f"{since_commit}..HEAD"],
        cwd=repo_path, capture_output=True, text=True, check=True,
    )
    return [f for f in result.stdout.strip().split("\n") if f]


def should_index(file_path: str) -> bool:
    """Check if a file should be indexed based on extension and path."""
    path = Path(file_path)

    # Check extension
    if path.suffix.lower() not in INCLUDE_EXTENSIONS:
        return False

    # Check skip directories
    parts = path.parts
    for part in parts:
        if part in SKIP_DIRS:
            return False

    # Check skip files
    if path.name in SKIP_FILES:
        return False

    return True


def chunk_text(text: str, file_path: str) -> list[str]:
    """Split text into overlapping chunks of ~CHUNK_SIZE characters.

    Each chunk is prefixed with the file path for context.
    """
    header = f"# File: {file_path}\n\n"

    if len(text) <= CHUNK_SIZE:
        return [header + text]

    chunks = []
    start = 0
    while start < len(text):
        end = start + CHUNK_SIZE

        # Try to break at a newline boundary for cleaner chunks
        if end < len(text):
            newline_pos = text.rfind("\n", start + CHUNK_SIZE // 2, end + 200)
            if newline_pos > start:
                end = newline_pos + 1

        chunk = text[start:end]
        chunk_num = len(chunks) + 1
        chunks.append(f"{header}[chunk {chunk_num}]\n{chunk}")

        start = end - CHUNK_OVERLAP
        if start <= 0 and len(chunks) > 0:
            break

    return chunks


def content_hash(text: str) -> str:
    """Compute a short hash for deduplication."""
    return hashlib.sha256(text.encode()).hexdigest()[:16]


# ── Main sync logic ─────────────────────────────────────────────────────────

def sync(repo_path: str, full: bool = False):
    """Run the code sync pipeline."""
    start_time = time.time()
    repo_path = os.path.abspath(repo_path)

    if not os.path.isdir(os.path.join(repo_path, ".git")):
        log.error(f"Not a git repository: {repo_path}")
        sys.exit(1)

    head_commit = get_head_commit(repo_path)
    last_commit = None if full else get_last_sync_commit()

    if last_commit == head_commit and not full:
        log.info("Already up to date (HEAD = last sync commit)")
        return

    mode = "full" if last_commit is None else "incremental"
    log.info(f"Starting {mode} sync: repo={repo_path}")
    if last_commit:
        log.info(f"  since={last_commit[:12]} head={head_commit[:12]}")
    else:
        log.info(f"  head={head_commit[:12]}")

    store = MemoryStore()

    # ── Handle deleted files ─────────────────────────────────────────────
    deleted_count = 0
    if last_commit and not full:
        deleted_files = get_deleted_files(repo_path, last_commit)
        for file_path in deleted_files:
            if not should_index(file_path):
                continue
            # Delete all chunks for this file
            rows = store.db.execute(
                "SELECT id FROM embeddings WHERE collection = ? AND source_ref = ?",
                (COLLECTION, file_path),
            ).fetchall()
            if rows:
                ids = [r[0] for r in rows]
                placeholders = ",".join("?" * len(ids))
                store.db.execute(
                    f"DELETE FROM vec_embeddings WHERE rowid IN ({placeholders})", ids
                )
                store.db.execute(
                    f"DELETE FROM embeddings WHERE id IN ({placeholders})", ids
                )
                deleted_count += len(ids)
        if deleted_count:
            store.db.commit()
            log.info(f"Deleted {deleted_count} embeddings for removed files")

    # ── Find changed files to process ────────────────────────────────────
    changed_files = get_changed_files(repo_path, last_commit)
    files_to_process = []
    skipped = 0

    for file_path in changed_files:
        if not should_index(file_path):
            skipped += 1
            continue

        abs_path = os.path.join(repo_path, file_path)
        if not os.path.isfile(abs_path):
            continue

        # Skip files that are too large
        if os.path.getsize(abs_path) > MAX_FILE_SIZE:
            skipped += 1
            continue

        files_to_process.append(file_path)

    log.info(f"Files to process: {len(files_to_process)} (skipped: {skipped})")

    if not files_to_process and deleted_count == 0:
        log.info("Nothing to do")
        save_sync_commit(head_commit)
        store.close()
        return

    # ── Read and chunk files ─────────────────────────────────────────────
    all_chunks = []  # (file_path, chunk_text)

    for file_path in files_to_process:
        abs_path = os.path.join(repo_path, file_path)
        try:
            text = Path(abs_path).read_text(encoding="utf-8", errors="replace")
        except (OSError, UnicodeDecodeError):
            continue

        if not text.strip():
            continue

        # Before adding new chunks, delete old chunks for this file
        rows = store.db.execute(
            "SELECT id FROM embeddings WHERE collection = ? AND source_ref = ?",
            (COLLECTION, file_path),
        ).fetchall()
        if rows:
            ids = [r[0] for r in rows]
            placeholders = ",".join("?" * len(ids))
            store.db.execute(
                f"DELETE FROM vec_embeddings WHERE rowid IN ({placeholders})", ids
            )
            store.db.execute(
                f"DELETE FROM embeddings WHERE id IN ({placeholders})", ids
            )

        chunks = chunk_text(text, file_path)
        for chunk in chunks:
            all_chunks.append((file_path, chunk))

    if rows_deleted := store.db.total_changes:
        store.db.commit()

    log.info(f"Total chunks to embed: {len(all_chunks)}")

    if not all_chunks:
        save_sync_commit(head_commit)
        store.close()
        return

    # ── Embed in batches ─────────────────────────────────────────────────
    chunk_texts = [c[1] for c in all_chunks]

    def on_progress(done, total):
        log.info(f"  Embedding progress: {done}/{total}")

    embeddings = get_embeddings(chunk_texts, on_progress=on_progress)

    # ── Insert into store ────────────────────────────────────────────────
    for (file_path, chunk_text_val), embedding in zip(all_chunks, embeddings):
        store.insert(
            collection=COLLECTION,
            source_type=SOURCE_TYPE,
            source_ref=file_path,
            content=chunk_text_val,
            embedding=embedding,
        )

    # ── Save state and report ────────────────────────────────────────────
    save_sync_commit(head_commit)
    store.close()

    elapsed = time.time() - start_time
    log.info(f"Sync complete in {elapsed:.1f}s")
    log.info(f"  Mode: {mode}")
    log.info(f"  Files processed: {len(files_to_process)}")
    log.info(f"  Chunks embedded: {len(all_chunks)}")
    log.info(f"  Deleted embeddings: {deleted_count}")


def main():
    parser = argparse.ArgumentParser(description="Sync codebase into vector memory")
    parser.add_argument(
        "--repo", required=True,
        help="Path to the git repository to sync",
    )
    parser.add_argument(
        "--full", action="store_true",
        help="Force full re-sync (ignore last sync commit)",
    )
    args = parser.parse_args()

    sync(args.repo, full=args.full)


if __name__ == "__main__":
    main()
