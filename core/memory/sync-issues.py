#!/usr/bin/env python3
"""Sync GitHub issues into the vector memory 'issues' collection.

Fetches open issues and issues closed within the last 90 days,
embeds title+body and comments, and upserts into sqlite-vec.
Supports incremental sync via a last-run timestamp file.

Usage:
    # Full sync
    python3 sync-issues.py --repo LvlyAI/lovely

    # Incremental (default — only issues updated since last run)
    python3 sync-issues.py --repo LvlyAI/lovely

    # Force full sync (ignore last-run timestamp)
    python3 sync-issues.py --repo LvlyAI/lovely --full

    # Dry run (no writes)
    python3 sync-issues.py --repo LvlyAI/lovely --dry-run
"""

import argparse
import json
import logging
import os
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone

# Add parent dir to path so we can import sibling modules
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from embed import get_embeddings
from init_db import DB_PATH
from query import MemoryStore

COLLECTION = "issues"
SOURCE_TYPE_ISSUE = "issue"
SOURCE_TYPE_COMMENT = "comment"
ARCHIVE_DAYS = 90
STATE_DIR = os.environ.get("CLAUDE_BOT_DATA_DIR", "/opt/claude-bot/data")
LAST_RUN_FILE = os.path.join(STATE_DIR, "sync-issues-last-run.txt")
GH_PAGE_SIZE = 100  # GitHub API max per page
EMBED_BATCH_LOG = 50  # Log progress every N embeddings

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [sync-issues] %(levelname)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%SZ",
)
log = logging.getLogger(__name__)


def gh_api(endpoint: str, paginate: bool = False) -> list | dict:
    """Call the GitHub API via the gh CLI."""
    cmd = ["gh", "api", endpoint, "--header", "Accept: application/vnd.github+json"]
    if paginate:
        cmd.append("--paginate")
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    if result.returncode != 0:
        raise RuntimeError(f"gh api failed: {result.stderr.strip()}")
    # --paginate concatenates JSON arrays, so we may get multiple arrays
    text = result.stdout.strip()
    if not text:
        return []
    if paginate and text.startswith("["):
        # gh --paginate outputs concatenated JSON arrays: [...][...]
        # Parse them and merge
        items = []
        decoder = json.JSONDecoder()
        pos = 0
        while pos < len(text):
            if text[pos] in (" ", "\n", "\r", "\t"):
                pos += 1
                continue
            obj, end = decoder.raw_decode(text, pos)
            if isinstance(obj, list):
                items.extend(obj)
            else:
                items.append(obj)
            pos = end
        return items
    return json.loads(text)


def fetch_issues(repo: str, since: str | None = None) -> list[dict]:
    """Fetch open issues + recently closed issues from GitHub.

    Args:
        repo: Owner/repo string (e.g. "LvlyAI/lovely")
        since: ISO-8601 timestamp — only fetch issues updated after this time

    Returns:
        List of issue dicts from the GitHub API.
    """
    issues = []

    # Fetch open issues
    endpoint = f"/repos/{repo}/issues?state=open&per_page={GH_PAGE_SIZE}&sort=updated&direction=desc"
    if since:
        endpoint += f"&since={since}"
    log.info("Fetching open issues%s...", f" (since {since})" if since else "")
    open_issues = gh_api(endpoint, paginate=True)
    # Filter out pull requests (GitHub API returns PRs in /issues)
    open_issues = [i for i in open_issues if "pull_request" not in i]
    issues.extend(open_issues)
    log.info("  Found %d open issues", len(open_issues))

    # Fetch closed issues (updated within archive window)
    cutoff = datetime.now(timezone.utc) - timedelta(days=ARCHIVE_DAYS)
    closed_since = since if since else cutoff.strftime("%Y-%m-%dT%H:%M:%SZ")
    endpoint = f"/repos/{repo}/issues?state=closed&per_page={GH_PAGE_SIZE}&sort=updated&direction=desc&since={closed_since}"
    log.info("Fetching closed issues (since %s)...", closed_since)
    closed_issues = gh_api(endpoint, paginate=True)
    closed_issues = [i for i in closed_issues if "pull_request" not in i]
    # Only keep issues closed within the archive window
    closed_issues = [
        i for i in closed_issues
        if i.get("closed_at") and datetime.fromisoformat(i["closed_at"].replace("Z", "+00:00")) >= cutoff
    ]
    issues.extend(closed_issues)
    log.info("  Found %d recently closed issues", len(closed_issues))

    # Deduplicate by issue number (an issue could appear in both queries
    # if it was reopened/closed during the window)
    seen = set()
    deduped = []
    for issue in issues:
        num = issue["number"]
        if num not in seen:
            seen.add(num)
            deduped.append(issue)

    return deduped


def fetch_comments(repo: str, issue_number: int) -> list[dict]:
    """Fetch all comments for an issue."""
    endpoint = f"/repos/{repo}/issues/{issue_number}/comments?per_page={GH_PAGE_SIZE}"
    return gh_api(endpoint, paginate=True)


def build_issue_text(issue: dict) -> str:
    """Build the embeddable text for an issue's title + body."""
    title = issue.get("title", "").strip()
    body = (issue.get("body") or "").strip()
    labels = ", ".join(l["name"] for l in issue.get("labels", []))
    state = issue.get("state", "unknown")

    parts = [f"#{issue['number']}: {title}"]
    if labels:
        parts.append(f"Labels: {labels}")
    parts.append(f"State: {state}")
    if body:
        parts.append(f"\n{body}")

    return "\n".join(parts)


def build_comment_text(issue: dict, comment: dict) -> str:
    """Build the embeddable text for a comment."""
    author = comment.get("user", {}).get("login", "unknown")
    body = (comment.get("body") or "").strip()
    return f"Comment on #{issue['number']} ({issue.get('title', '')}) by {author}:\n{body}"


def load_last_run() -> str | None:
    """Load the timestamp of the last successful sync."""
    try:
        with open(LAST_RUN_FILE) as f:
            ts = f.read().strip()
            return ts if ts else None
    except FileNotFoundError:
        return None


def save_last_run(ts: str):
    """Save the current sync timestamp."""
    os.makedirs(os.path.dirname(LAST_RUN_FILE), exist_ok=True)
    with open(LAST_RUN_FILE, "w") as f:
        f.write(ts)


def prune_archived(store: MemoryStore, repo: str, active_refs: set[str], dry_run: bool = False) -> int:
    """Remove embeddings for issues no longer in the active set.

    An issue is pruned if its source_ref exists in the collection but is not
    in the set of currently active issue references.
    """
    # Get all source_refs currently in the collection
    rows = store.db.execute(
        "SELECT DISTINCT source_ref FROM embeddings WHERE collection = ?",
        (COLLECTION,),
    ).fetchall()

    existing_refs = {r[0] for r in rows}
    stale_refs = existing_refs - active_refs

    if not stale_refs:
        return 0

    pruned = 0
    for ref in stale_refs:
        if dry_run:
            log.info("  [dry-run] Would prune: %s", ref)
            pruned += 1
            continue
        ids = [r[0] for r in store.db.execute(
            "SELECT id FROM embeddings WHERE collection = ? AND source_ref = ?",
            (COLLECTION, ref),
        ).fetchall()]
        if ids:
            placeholders = ",".join("?" * len(ids))
            store.db.execute(f"DELETE FROM vec_embeddings WHERE rowid IN ({placeholders})", ids)
            store.db.execute(f"DELETE FROM embeddings WHERE id IN ({placeholders})", ids)
            pruned += len(ids)

    if not dry_run:
        store.db.commit()

    return pruned


def sync(repo: str, full: bool = False, dry_run: bool = False):
    """Run the sync pipeline."""
    start_time = time.time()
    sync_ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    # Determine since timestamp for incremental sync
    since = None
    if not full:
        since = load_last_run()
        if since:
            log.info("Incremental sync (since %s)", since)
        else:
            log.info("No previous run found — performing full sync")

    # Fetch issues
    issues = fetch_issues(repo, since=since)
    log.info("Total issues to process: %d", len(issues))

    if not issues and since:
        log.info("No updated issues since last run. Done.")
        save_last_run(sync_ts)
        return

    # Collect all texts and their metadata for batch embedding
    chunks = []  # list of (source_ref, text)

    for issue in issues:
        num = issue["number"]
        # Issue body chunk
        issue_text = build_issue_text(issue)
        chunks.append((f"issue#{num}", issue_text))

        # Fetch and add comments
        if issue.get("comments", 0) > 0:
            comments = fetch_comments(repo, num)
            for comment in comments:
                comment_text = build_comment_text(issue, comment)
                ref = f"issue#{num}/comment#{comment['id']}"
                chunks.append((ref, comment_text))

    log.info("Total chunks to embed: %d (%d issues + %d comments)",
             len(chunks), len(issues),
             len(chunks) - len(issues))

    if dry_run:
        log.info("[dry-run] Would embed %d chunks. Skipping.", len(chunks))
        return

    # Generate embeddings
    texts = [c[1] for c in chunks]

    def on_progress(done, total):
        log.info("  Embedded %d/%d chunks", done, total)

    log.info("Generating embeddings...")
    embeddings = get_embeddings(texts, on_progress=on_progress, batch_size=EMBED_BATCH_LOG)

    # Upsert into store
    store = MemoryStore()
    inserted = 0
    for (source_ref, text), embedding in zip(chunks, embeddings):
        source_type = SOURCE_TYPE_COMMENT if "/comment#" in source_ref else SOURCE_TYPE_ISSUE
        store.insert(COLLECTION, source_type, source_ref, text, embedding)
        inserted += 1

    log.info("Upserted %d chunks into '%s' collection", inserted, COLLECTION)

    # Prune archived issues (only on full sync to avoid removing
    # issues that simply weren't in the incremental fetch)
    pruned = 0
    if full or not since:
        # Build the set of active refs from the issues we just fetched
        active_refs = set()
        for source_ref, _ in chunks:
            active_refs.add(source_ref)
        pruned = prune_archived(store, repo, active_refs)
        if pruned:
            log.info("Pruned %d stale embeddings", pruned)

    store.close()

    # Save last-run timestamp
    save_last_run(sync_ts)

    elapsed = time.time() - start_time
    log.info("Sync complete in %.1fs: %d issues processed, %d chunks embedded, %d pruned",
             elapsed, len(issues), inserted, pruned)


def main():
    parser = argparse.ArgumentParser(
        description="Sync GitHub issues into vector memory"
    )
    parser.add_argument(
        "--repo", required=True,
        help="GitHub repo (owner/repo format, e.g. LvlyAI/lovely)"
    )
    parser.add_argument(
        "--full", action="store_true",
        help="Force full sync (ignore last-run timestamp)"
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Fetch and log but don't write to database"
    )
    args = parser.parse_args()

    sync(repo=args.repo, full=args.full, dry_run=args.dry_run)


if __name__ == "__main__":
    main()
