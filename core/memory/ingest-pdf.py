#!/usr/bin/env python3
"""Ingest a PDF into a vector memory collection.

Extracts text from each page, chunks by section/page, and embeds into
the specified collection (default: 'science').

Usage:
    # Ingest a single PDF
    python3 ingest-pdf.py --file /path/to/paper.pdf --collection science

    # Ingest with custom metadata
    python3 ingest-pdf.py --file paper.pdf --collection science \
        --title "PCIT Manual" --author "Eyberg" --tags "pcit,methodology"

    # Ingest all PDFs in a directory
    python3 ingest-pdf.py --dir /path/to/papers/ --collection science

    # Dry run (show chunks without embedding)
    python3 ingest-pdf.py --file paper.pdf --dry-run

Requirements:
    pip install pymupdf  (or: pip install PyMuPDF)
"""

import argparse
import hashlib
import json
import logging
import os
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

# Target chunk size in characters (aim for ~500 tokens ≈ 2000 chars)
CHUNK_SIZE = 2000
CHUNK_OVERLAP = 200


def extract_text_from_pdf(pdf_path: str) -> list[dict]:
    """Extract text from each page of a PDF. Returns list of {page, text}."""
    try:
        import fitz  # pymupdf
    except ImportError:
        log.error("pymupdf not installed. Run: pip install pymupdf")
        sys.exit(1)

    doc = fitz.open(pdf_path)
    pages = []
    for i, page in enumerate(doc):
        text = page.get_text().strip()
        if text:
            pages.append({"page": i + 1, "text": text})
    doc.close()
    return pages


def chunk_text(text: str, chunk_size: int = CHUNK_SIZE, overlap: int = CHUNK_OVERLAP) -> list[str]:
    """Split text into overlapping chunks."""
    if len(text) <= chunk_size:
        return [text]

    chunks = []
    start = 0
    while start < len(text):
        end = start + chunk_size
        # Try to break at a paragraph or sentence boundary
        if end < len(text):
            # Look for paragraph break
            para_break = text.rfind("\n\n", start + chunk_size // 2, end)
            if para_break > start:
                end = para_break
            else:
                # Look for sentence break
                sent_break = text.rfind(". ", start + chunk_size // 2, end)
                if sent_break > start:
                    end = sent_break + 1
        chunks.append(text[start:end].strip())
        start = end - overlap
    return [c for c in chunks if c]


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

    log.info(f"Extracting text from: {filename}")
    pages = extract_text_from_pdf(pdf_path)
    if not pages:
        log.warning(f"No text extracted from {filename}")
        return 0

    log.info(f"Extracted {len(pages)} pages")

    # Chunk all pages
    chunks = []
    for page_info in pages:
        page_chunks = chunk_text(page_info["text"])
        for i, chunk in enumerate(page_chunks):
            chunks.append({
                "id": f"pdf:{content_hash(pdf_path)}:p{page_info['page']}:c{i}",
                "text": chunk,
                "metadata": json.dumps({
                    "source": "pdf",
                    "file": filename,
                    "title": title,
                    "author": author,
                    "tags": tags,
                    "page": page_info["page"],
                    "chunk": i,
                }),
            })

    log.info(f"Created {len(chunks)} chunks from {len(pages)} pages")

    if dry_run:
        for c in chunks[:3]:
            log.info(f"  Chunk {c['id']}: {c['text'][:100]}...")
        log.info(f"  ... ({len(chunks)} total, dry run — not embedding)")
        return len(chunks)

    # Embed and store
    db = init_db()

    texts = [c["text"] for c in chunks]
    log.info(f"Embedding {len(texts)} chunks...")
    embeddings = get_embeddings(texts)

    for chunk, embedding in zip(chunks, embeddings):
        db.execute(
            f"""INSERT OR REPLACE INTO {collection}_chunks
                (id, content, metadata, embedding)
                VALUES (?, ?, ?, ?)""",
            (chunk["id"], chunk["text"], chunk["metadata"], embedding),
        )

    db.commit()
    log.info(f"Ingested {len(chunks)} chunks from {filename} into '{collection}' collection")
    return len(chunks)


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
