# Decision 0008: Defer advanced document extraction

Status: accepted

## Decision

The MVP keeps Open WebUI 0.10.2's built-in document loaders and does not add
Docling, Tika, an OCR service, or a custom extraction gateway.

The required acceptance denominator passes with the built-in path: Markdown,
Python source, and text PDF fixtures are extracted, embedded locally with the
pinned `all-MiniLM-L6-v2` snapshot, retrieved by hybrid search, and returned
with source metadata. The near-duplicate offline/online policy cases remain
distinguishable, and data persists through a container restart.

The scanned-PDF control was ingested successfully but returned an empty
retrieval result for its known `SCAN-8842` content. The fixture's source image
and generation recipe confirm the text exists, so this is an extraction/OCR
gap rather than a retrieval or generation failure. That case was intentionally
declared `extraction_control` with `rag_denominator: false`: OCR of scanned
documents is useful, but it is not required for the local chat/code/image and
common-document MVP.

Adding an extraction service for one optional control would introduce another
runtime, image, update stream, resource budget, and offline artifact set. The
measured gap therefore does not justify that cost in this release.

## Revisit criteria

Open a separate design and qualification plan for Docling or another maintained
extractor when scanned PDFs, complex tables/layout, or an unsupported required
format enters the acceptance denominator. The candidate must improve a
versioned failing corpus, fit the 24 GB host alongside one inference model, run
fully offline after explicit setup, expose a supported Open WebUI integration,
and preserve source/page metadata needed for citations.
