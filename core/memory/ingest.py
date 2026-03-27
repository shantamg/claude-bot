#!/usr/bin/env python3
"""Ingest documents into a vector memory collection using structure-aware chunking.

Supports:
- Markdown files (.md) — chunked by headings directly
- PDF files (.pdf) — converted to markdown first, then chunked by headings
  Uses Marker (marker-pdf) if installed, falls back to pymupdf4llm

Usage:
    # Ingest a markdown file (best quality — use Marker to convert PDFs first)
    python3 ingest.py --file manual.md --collection science

    # Ingest a PDF (auto-converts to markdown)
    python3 ingest.py --file paper.pdf --collection science

    # Ingest with metadata
    python3 ingest.py --file paper.md --collection science \
        --title "DPICS Manual" --author "Eyberg" --tags "pcit,dpics,coding"

    # Ingest all files in a directory
    python3 ingest.py --dir /path/to/papers/ --collection science

    # Dry run (show chunks without embedding)
    python3 ingest.py --file paper.md --dry-run

PDF Conversion:
    For best results, convert PDFs to markdown using Marker before ingesting:
        marker_single /path/to/paper.pdf /path/to/output/
    Then ingest the resulting .md file.
"""

import argparse
import hashlib
import json
import logging
import os
import re
import sys
from pathlib import Path

# Add parent directory so we can import sibling modules
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from embed import get_embeddings
from init_db import DB_PATH, init_db
from query import MemoryStore

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [ingest] %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%SZ",
)
log = logging.getLogger(__name__)

# Chunk size limits
MAX_CHUNK_CHARS = 3000
MIN_CHUNK_CHARS = 200


def read_markdown(file_path: str) -> str:
    """Read a markdown file."""
    with open(file_path, "r", encoding="utf-8") as f:
        return f.read()


def pdf_to_markdown(pdf_path: str) -> str:
    """Convert PDF to markdown. Tries Marker first, falls back to pymupdf4llm."""
    # Try Marker (best quality)
    try:
        from marker.converters.pdf import PdfConverter
        from marker.models import create_model_dict

        log.info("Using Marker for PDF conversion (ML-based, best quality)")
        models = create_model_dict()
        converter = PdfConverter(artifact_dict=models)
        result = converter(pdf_path)
        return result.markdown
    except ImportError:
        pass

    # Fall back to pymupdf4llm
    try:
        import pymupdf4llm

        log.info("Using pymupdf4llm for PDF conversion (faster, lower quality)")
        return pymupdf4llm.to_markdown(pdf_path)
    except ImportError:
        pass

    log.error("No PDF converter available. Install marker-pdf or pymupdf4llm")
    sys.exit(1)


def parse_heading(line: str) -> tuple[int, str] | None:
    """Parse a markdown heading line. Returns (level, text) or None."""
    match = re.match(r"^(#{1,6})\s+(.+)$", line.strip())
    if match:
        return len(match.group(1)), match.group(2).strip()
    return None


def chunk_by_headings(markdown: str) -> list[dict]:
    """Split markdown into chunks based on heading structure."""
    lines = markdown.split("\n")
    chunks = []
    current_chunk_lines = []
    current_heading = ""
    current_level = 0
    heading_stack = []

    def flush_chunk():
        nonlocal current_chunk_lines, current_heading, current_level
        text = "\n".join(current_chunk_lines).strip()
        if not text:
            return
        parents = [h for _, h in heading_stack if _ < current_level] if current_level > 0 else []
        chunks.append({
            "text": text,
            "heading": current_heading,
            "parent_headings": parents,
            "level": current_level,
        })
        current_chunk_lines = []

    for line in lines:
        parsed = parse_heading(line)
        if parsed:
            level, heading_text = parsed
            flush_chunk()
            heading_stack = [(l, h) for l, h in heading_stack if l < level]
            heading_stack.append((level, heading_text))
            current_heading = heading_text
            current_level = level
            current_chunk_lines = [line]
        else:
            current_chunk_lines.append(line)

    flush_chunk()
    return chunks


def split_large_chunk(chunk: dict, max_chars: int = MAX_CHUNK_CHARS) -> list[dict]:
    """Split a chunk that exceeds max_chars on paragraph boundaries."""
    text = chunk["text"]
    if len(text) <= max_chars:
        return [chunk]

    paragraphs = re.split(r"\n\n+", text)
    sub_chunks = []
    current_text = ""

    for para in paragraphs:
        if len(current_text) + len(para) > max_chars and current_text:
            sub_chunks.append({
                **chunk,
                "text": current_text.strip(),
                "sub_chunk": len(sub_chunks),
            })
            current_text = para
        else:
            current_text = current_text + "\n\n" + para if current_text else para

    if current_text.strip():
        sub_chunks.append({
            **chunk,
            "text": current_text.strip(),
            "sub_chunk": len(sub_chunks),
        })

    return sub_chunks


def merge_small_chunks(chunks: list[dict], min_chars: int = MIN_CHUNK_CHARS) -> list[dict]:
    """Merge chunks smaller than min_chars with the next chunk."""
    if not chunks:
        return chunks

    merged = []
    i = 0
    while i < len(chunks):
        chunk = chunks[i]
        if len(chunk["text"]) < min_chars and i + 1 < len(chunks):
            next_chunk = chunks[i + 1]
            merged_text = chunk["text"] + "\n\n" + next_chunk["text"]
            merged.append({**next_chunk, "text": merged_text})
            i += 2
        else:
            merged.append(chunk)
            i += 1

    return merged


def content_hash(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()[:16]


def ingest_file(
    file_path: str,
    collection: str = "science",
    title: str = "",
    author: str = "",
    tags: str = "",
    dry_run: bool = False,
):
    """Ingest a single file (markdown or PDF) into the vector database."""
    file_path = os.path.abspath(file_path)
    filename = os.path.basename(file_path)
    ext = os.path.splitext(filename)[1].lower()
    title = title or filename.rsplit(".", 1)[0].replace("_", " ").replace("-", " ")

    # Get markdown content
    if ext in (".md", ".markdown", ".txt"):
        log.info(f"Reading markdown: {filename}")
        markdown = read_markdown(file_path)
    elif ext == ".pdf":
        log.info(f"Converting PDF to markdown: {filename}")
        markdown = pdf_to_markdown(file_path)
    else:
        log.warning(f"Unsupported file type: {ext} — skipping {filename}")
        return 0

    if not markdown.strip():
        log.warning(f"No content extracted from {filename}")
        return 0

    log.info(f"Content: {len(markdown)} chars")

    # Structure-aware chunking
    raw_chunks = chunk_by_headings(markdown)
    log.info(f"Found {len(raw_chunks)} heading-based sections")

    # Split oversized chunks and merge tiny ones
    processed = []
    for chunk in raw_chunks:
        processed.extend(split_large_chunk(chunk))
    processed = merge_small_chunks(processed)

    # Stats
    sizes = [len(c["text"]) for c in processed]
    large = sum(1 for s in sizes if s > MAX_CHUNK_CHARS)
    small = sum(1 for s in sizes if s < MIN_CHUNK_CHARS)
    log.info(f"After split/merge: {len(processed)} chunks ({large} still large, {small} still small)")

    # Build final chunks
    file_hash = content_hash(file_path)
    final_chunks = []
    for i, chunk in enumerate(processed):
        context_prefix = ""
        if chunk["parent_headings"]:
            context_prefix = " > ".join(chunk["parent_headings"]) + " > "
        if chunk["heading"]:
            context_prefix += chunk["heading"] + "\n\n"

        embed_text = context_prefix + chunk["text"]
        sub = chunk.get("sub_chunk", "")
        chunk_id = f"doc:{file_hash}:s{i}" + (f":p{sub}" if sub != "" else "")

        final_chunks.append({
            "id": chunk_id,
            "text": chunk["text"],
            "embed_text": embed_text,
            "metadata": json.dumps({
                "source": ext.lstrip("."),
                "file": filename,
                "title": title,
                "author": author,
                "tags": tags,
                "heading": chunk["heading"],
                "parent_headings": chunk["parent_headings"],
                "level": chunk["level"],
            }),
        })

    log.info(f"Final: {len(final_chunks)} chunks ready")

    if dry_run:
        for c in final_chunks[:8]:
            meta = json.loads(c["metadata"])
            parents = " > ".join(meta["parent_headings"]) if meta["parent_headings"] else ""
            path = f"{parents} > {meta['heading']}" if parents else meta["heading"]
            log.info(f"  [{len(c['text']):5} chars] {path[:80]}")
        if len(final_chunks) > 8:
            log.info(f"  ... ({len(final_chunks)} total)")
        return len(final_chunks)

    # Embed and store using MemoryStore (handles serialization and upsert)
    store = MemoryStore()
    texts = [c["embed_text"] for c in final_chunks]
    log.info(f"Embedding {len(texts)} chunks via Bedrock Titan...")
    embeddings = get_embeddings(texts)

    for chunk, embedding in zip(final_chunks, embeddings):
        meta = json.loads(chunk["metadata"])
        store.insert(
            collection=collection,
            source_type=meta.get("source", "md"),
            source_ref=chunk["id"],
            content=chunk["text"],
            embedding=embedding,
        )

    store.db.commit()
    store.close()
    log.info(f"Ingested {len(final_chunks)} chunks from {filename} into '{collection}'")
    return len(final_chunks)


def main():
    parser = argparse.ArgumentParser(description="Ingest documents into vector memory")
    parser.add_argument("--file", help="Path to a file (.md, .pdf, .txt)")
    parser.add_argument("--dir", help="Path to a directory of files")
    parser.add_argument("--collection", default="science", help="Collection name (default: science)")
    parser.add_argument("--title", default="", help="Document title (default: filename)")
    parser.add_argument("--author", default="", help="Document author")
    parser.add_argument("--tags", default="", help="Comma-separated tags")
    parser.add_argument("--dry-run", action="store_true", help="Show chunks without embedding")
    args = parser.parse_args()

    if not args.file and not args.dir:
        parser.error("Either --file or --dir is required")

    total = 0
    if args.file:
        total = ingest_file(args.file, args.collection, args.title, args.author, args.tags, args.dry_run)
    elif args.dir:
        p = Path(args.dir)
        for f in sorted(p.glob("*")):
            if f.suffix.lower() in (".md", ".markdown", ".txt", ".pdf"):
                total += ingest_file(str(f), args.collection, args.title, args.author, args.tags, args.dry_run)

    log.info(f"Total: {total} chunks ingested")


if __name__ == "__main__":
    main()
