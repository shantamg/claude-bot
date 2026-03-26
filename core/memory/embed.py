#!/usr/bin/env python3
"""Generate embeddings via AWS Bedrock Titan Embeddings V2.

Usage:
    # Single text
    python3 embed.py "some text to embed"

    # Read from stdin (one text per line)
    echo -e "line one\\nline two" | python3 embed.py --stdin

    # As a library
    from embed import get_embeddings
    vectors = get_embeddings(["hello", "world"])
"""

import argparse
import json
import sys
import time
from typing import Optional

import boto3
from botocore.exceptions import ClientError

MODEL_ID = "amazon.titan-embed-text-v2:0"
REGION = "us-west-2"
EMBEDDING_DIM = 1024
BATCH_SIZE = 20  # Titan accepts one text per call; we batch to limit concurrency
MAX_RETRIES = 5
BASE_DELAY = 0.5  # seconds


def _get_client(region: str = REGION):
    return boto3.client("bedrock-runtime", region_name=region)


def _embed_single(client, text: str, dimensions: int = EMBEDDING_DIM) -> list[float]:
    """Embed a single text string. Retries on throttling."""
    body = json.dumps({
        "inputText": text,
        "dimensions": dimensions,
        "normalize": True,
    })

    for attempt in range(MAX_RETRIES):
        try:
            resp = client.invoke_model(modelId=MODEL_ID, body=body)
            result = json.loads(resp["body"].read())
            return result["embedding"]
        except ClientError as e:
            code = e.response["Error"]["Code"]
            if code in ("ThrottlingException", "TooManyRequestsException") and attempt < MAX_RETRIES - 1:
                delay = BASE_DELAY * (2 ** attempt)
                time.sleep(delay)
                continue
            raise


def get_embeddings(
    texts: list[str],
    region: str = REGION,
    dimensions: int = EMBEDDING_DIM,
    batch_size: int = BATCH_SIZE,
    on_progress: Optional[callable] = None,
) -> list[list[float]]:
    """Embed a list of texts, returning vectors in the same order.

    Args:
        texts: List of strings to embed.
        region: AWS region for Bedrock.
        dimensions: Embedding vector dimensions (default 1024).
        batch_size: Number of texts to process before yielding control.
        on_progress: Optional callback(completed, total) for progress reporting.

    Returns:
        List of float vectors, one per input text.
    """
    client = _get_client(region)
    embeddings = []

    for i, text in enumerate(texts):
        vec = _embed_single(client, text, dimensions)
        embeddings.append(vec)

        if on_progress and (i + 1) % batch_size == 0:
            on_progress(i + 1, len(texts))

    if on_progress and len(texts) % batch_size != 0:
        on_progress(len(texts), len(texts))

    return embeddings


def main():
    parser = argparse.ArgumentParser(description="Generate embeddings via Bedrock Titan V2")
    parser.add_argument("text", nargs="?", help="Text to embed")
    parser.add_argument("--stdin", action="store_true", help="Read texts from stdin, one per line")
    parser.add_argument("--dim", type=int, default=EMBEDDING_DIM, help="Embedding dimensions")
    parser.add_argument("--region", default=REGION, help="AWS region")
    args = parser.parse_args()

    if args.stdin:
        texts = [line.strip() for line in sys.stdin if line.strip()]
    elif args.text:
        texts = [args.text]
    else:
        parser.error("Provide text as an argument or use --stdin")

    def progress(done, total):
        print(f"  [{done}/{total}]", file=sys.stderr)

    vectors = get_embeddings(texts, region=args.region, dimensions=args.dim, on_progress=progress)

    # Output as JSON array of arrays
    json.dump(vectors, sys.stdout)
    print()


if __name__ == "__main__":
    main()
