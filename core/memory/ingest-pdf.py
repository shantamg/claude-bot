#!/usr/bin/env python3
"""Ingest a PDF into a vector memory collection using structure-aware chunking.

Converts PDF to markdown (preserving headings, tables, structure), then
chunks on heading boundaries so each chunk is a meaningful section with
its heading hierarchy as metadata.

Usage:
    # Ingest a single PDF
    python3 ingest-pdf.py --file /path/to/paper.pdf --collection science

    # Ingest with custom metadata
    python3 ingest-pdf.py --file paper.pdf --collection science \
        --title "DPICS Manual" --author "Eyberg" --tags "pcit,dpics,coding"

    # Ingest all PDFs in a directory
    python3 ingest-pdf.py --dir /path/to/papers/ --collection science

    # Dry run (show chunks without embedding)
    python3 ingest-pdf.py --file paper.pdf --dry-run

Requirements:
    pip install pymupdf4llm
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

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [ingest-pdf] %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%SZ",
)
log = logging.getLogger(__name__)

# Max chunk size — if a section exceeds this, split on paragraphs
MAX_CHUNK_CHARS = 3000
# Min chunk size — merge tiny sections with the next one
MIN_CHUNK_CHARS = 200


def pdf_to_markdown(pdf_path: str) -> str:
    """Convert PDF to markdown using pymupdf4llm."""
    try:
        import pymupdf4llm
    except ImportError:
        log.error("pymupdf4llm not installed. Run: pip install pymupdf4llm")
        sys.exit(1)

    return pymupdf4llm.to_markdown(pdf_path)


def parse_heading(line: str) -> tuple[int, str] | None:
    """Parse a markdown heading line. Returns (level, text) or None."""
    match = re.match(r"^(#{1,6})\s+(.+)$", line.strip())
    if match:
        return len(match.group(1)), match.group(2).strip()
    return None


def chunk_by_headings(markdown: str) -> list[dict]:
    """Split markdown into chunks based on heading structure.

    Each chunk contains:
    - text: the section content (heading + body)
    - heading: the section heading
    - parent_headings: list of ancestor headings (for context)
    - level: heading level (1-6)
    """
    lines = markdown.split("\n")
    chunks = []
    current_chunk_lines = []
    current_heading = ""
    current_level = 0
    # Track heading hierarchy for parent context
    heading_stack = []  # list of (level, heading)

    def flush_chunk():
        nonlocal current_chunk_lines, current_heading, current_level
        text = "\n".join(current_chunk_lines).strip()
        if not text:
            return
        # Build parent headings from stack
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
            # Flush previous chunk
            flush_chunk()
            # Update heading stack — remove headings at same or deeper level
            heading_stack = [(l, h) for l, h in heading_stack if l < level]
            heading_stack.append((level, heading_text))
            current_heading = heading_text
            current_level = level
            current_chunk_lines = [line]
        else:
            current_chunk_lines.append(line)

    # Flush last chunk
    flush_chunk()

    return chunks


def split_large_chunk(chunk: dict, max_chars: int = MAX_CHUNK_CHARS) -> list[dict]:
    """Split a chunk that exceeds max_chars on paragraph boundaries."""
    text = chunk["text"]
    if len(text) <= max_chars:
        return [chunk]

    # Split on double newlines (paragraphs)
    paragraphs = re.split(r"\n\n+", text)
    sub_chunks = []
    current_text = ""

    for para in paragraphs:
        if len(current_text) + len(para) > max_chars and current_text:
            sub_chunks.append({
                **chunk,
                "text": current_text.strip(),
                "heading": chunk["heading"],
                "sub_chunk": len(sub_chunks),
            })
            current_text = para
        else:
            current_text = current_text + "\n\n" + para if current_text else para

    if current_text.strip():
        sub_chunks.append({
            **chunk,
            "text": current_text.strip(),
            "heading": chunk["heading"],
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
        # If this chunk is tiny and there's a next chunk at the same or deeper level
        if len(chunk["text"]) < min_chars and i + 1 < len(chunks):
            next_chunk = chunks[i + 1]
            # Merge into next chunk
            merged_text = chunk["text"] + "\n\n" + next_chunk["text"]
            merged.append({
                **next_chunk,
                "text": merged_text,
            })
            i += 2  # skip both
        else:
            merged.append(chunk)
            i += 1

    return merged


def content_hash(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()[:16]


def ingest_pdf(
    pdf_path: str,
    collection: str = "science",
    title: str = "",
    author: str = "",
    tags: str = "",
    dry_run: bool = False,
):
    """Ingest a single PDF into the vector database."""
    pdf_path = os.path.abspath(pdf_path)
    filename = os.path.basename(pdf_path)
    title = title or filename.replace(".pdf", "").replace("_", " ").replace("-", " ")

    log.info(f"Converting to markdown: {filename}")
    markdown = pdf_to_markdown(pdf_path)
    if not markdown.strip():
        log.warning(f"No content extracted from {filename}")
        return 0

    log.info(f"Extracted {len(markdown)} chars of markdown")

    # Structure-aware chunking
    log.info("Chunking by headings...")
    raw_chunks = chunk_by_headings(markdown)
    log.info(f"Found {len(raw_chunks)} heading-based sections")

    # Split oversized chunks and merge tiny ones
    processed = []
    for chunk in raw_chunks:
        processed.extend(split_large_chunk(chunk))
    processed = merge_small_chunks(processed)
    log.info(f"After split/merge: {len(processed)} chunks")

    # Build final chunks with IDs and metadata
    file_hash = content_hash(pdf_path)
    final_chunks = []
    for i, chunk in enumerate(processed):
        # Build a rich context prefix for the embedding
        context_prefix = ""
        if chunk["parent_headings"]:
            context_prefix = " > ".join(chunk["parent_headings"]) + " > "
        if chunk["heading"]:
            context_prefix += chunk["heading"] + "\n\n"

        embed_text = context_prefix + chunk["text"]

        sub = chunk.get("sub_chunk", "")
        chunk_id = f"pdf:{file_hash}:s{i}" + (f":p{sub}" if sub else "")

        final_chunks.append({
            "id": chunk_id,
            "text": chunk["text"],
            "embed_text": embed_text,
            "metadata": json.dumps({
                "source": "pdf",
                "file": filename,
                "title": title,
                "author": author,
                "tags": tags,
                "heading": chunk["heading"],
                "parent_headings": chunk["parent_headings"],
                "level": chunk["level"],
            }),
        })

    log.info(f"Final: {len(final_chunks)} chunks ready to embed")

    if dry_run:
        for c in final_chunks[:5]:
            meta = json.loads(c["metadata"])
            parents = " > ".join(meta["parent_headings"]) if meta["parent_headings"] else ""
            heading = meta["heading"]
            path = f"{parents} > {heading}" if parents else heading
            log.info(f"  [{path}] ({len(c['text'])} chars): {c['text'][:80]}...")
        if len(final_chunks) > 5:
            log.info(f"  ... ({len(final_chunks)} total)")
        return len(final_chunks)

    # Embed and store
    db = init_db()

    # Embed using the context-enriched text (includes heading hierarchy)
    texts = [c["embed_text"] for c in final_chunks]
    log.info(f"Embedding {len(texts)} chunks via Bedrock Titan...")
    embeddings = get_embeddings(texts)

    for chunk, embedding in zip(final_chunks, embeddings):
        db.execute(
            f"""INSERT OR REPLACE INTO {collection}_chunks
                (id, content, metadata, embedding)
                VALUES (?, ?, ?, ?)""",
            (chunk["id"], chunk["text"], chunk["metadata"], embedding),
        )

    db.commit()
    log.info(f"Ingested {len(final_chunks)} chunks from {filename} into '{collection}' collection")
    return len(final_chunks)


def main():
    parser = argparse.ArgumentParser(description="Ingest PDFs into vector memory")
    parser.add_argument("--file", help="Path to a single PDF file")
    parser.add_argument("--dir", help="Path to a directory of PDFs")
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
        total = ingest_pdf(args.file, args.collection, args.title, args.author, args.tags, args.dry_run)
    elif args.dir:
        pdf_dir = Path(args.dir)
        for pdf_file in sorted(pdf_dir.glob("*.pdf")):
            total += ingest_pdf(str(pdf_file), args.collection, args.title, args.author, args.tags, args.dry_run)

    log.info(f"Total: {total} chunks ingested")


if __name__ == "__main__":
    main()
