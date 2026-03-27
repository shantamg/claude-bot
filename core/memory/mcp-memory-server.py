#!/usr/bin/env python3
"""MCP memory server with persona-scoped semantic search.

Exposes vector memory search to Claude agents via the MCP protocol.
Reads CLAUDE_PERSONA from the environment to restrict collection access
per memory-scope.yaml.

Usage:
    python3 mcp-memory-server.py          # stdio transport (default)
    CLAUDE_PERSONA=engineer python3 mcp-memory-server.py
"""

import os
import sys

import yaml

# Defer heavy imports (boto3, sqlite_vec) to first tool call to keep
# startup memory under 50MB.  FastMCP + yaml alone are ~30MB.

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _SCRIPT_DIR)

# ── Configuration ────────────────────────────────────────────────────────────

SCOPE_FILE = os.path.join(_SCRIPT_DIR, "memory-scope.yaml")


def _load_scope() -> dict:
    """Load persona -> collections mapping from memory-scope.yaml."""
    with open(SCOPE_FILE) as f:
        data = yaml.safe_load(f)
    return data.get("personas", {})


def _allowed_collections() -> list[str]:
    """Return collections the current persona may access."""
    persona = os.environ.get("CLAUDE_PERSONA", "default")
    scopes = _load_scope()
    return scopes.get(persona, scopes.get("default", ["issues", "docs"]))


def _check_collections(requested: list[str]) -> list[str]:
    """Filter requested collections to only those allowed for this persona."""
    allowed = set(_allowed_collections())
    return [c for c in requested if c in allowed]


# ── Lazy-loaded heavy dependencies ──────────────────────────────────────────

_store = None
_get_embeddings = None


def _lazy_init():
    """Import embed/query modules on first use to keep idle memory low."""
    global _store, _get_embeddings
    if _get_embeddings is None:
        from embed import get_embeddings
        from query import MemoryStore
        _get_embeddings = get_embeddings
        _store = MemoryStore()


# ── MCP Server ───────────────────────────────────────────────────────────────

from mcp.server.fastmcp import FastMCP

mcp = FastMCP(
    "memory",
    instructions="Semantic search over the project knowledge base. "
    "Use search_memory for general queries, search_project_history for "
    "issues+docs, and search_code for code.",
)


@mcp.tool()
def search_memory(query: str, collections: list[str], top_k: int = 5) -> list[dict]:
    """Search memory across one or more collections.

    Returns top-k matching chunks ranked by similarity. Each result includes:
    content snippet, source type, source reference, and similarity score.

    Collections are restricted by the calling agent's persona.
    """
    valid = _check_collections(collections)
    if not valid:
        allowed = _allowed_collections()
        return [{"error": f"No accessible collections in {collections}. Allowed: {allowed}"}]

    _lazy_init()
    query_vec = _get_embeddings([query])[0]

    results = []
    for collection in valid:
        hits = _store.search(collection, query_vec, limit=top_k)
        for hit in hits:
            results.append({
                "content": hit["content_snippet"],
                "source_type": hit["source_type"],
                "source_ref": hit["source_ref"],
                "collection": collection,
                "similarity": round(1.0 - hit["distance"], 4),
            })

    # Re-sort all results by similarity and trim to top_k
    results.sort(key=lambda r: r["similarity"], reverse=True)
    return results[:top_k]


@mcp.tool()
def search_project_history(query: str, top_k: int = 5) -> list[dict]:
    """Search issues and docs collections for project history.

    Convenience wrapper around search_memory that targets the issues and
    docs collections. Useful for finding past decisions, bug reports,
    feature requests, and documentation.
    """
    return search_memory(query, ["issues", "docs"], top_k)


@mcp.tool()
def search_code(query: str, top_k: int = 5) -> list[dict]:
    """Search the code collection for relevant code snippets.

    Convenience wrapper around search_memory that targets the code
    collection. Useful for finding implementations, patterns, and
    function signatures.
    """
    return search_memory(query, ["code"], top_k)


if __name__ == "__main__":
    mcp.run(transport="stdio")
