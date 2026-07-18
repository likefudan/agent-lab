# Redistributable RAG acceptance corpus

This corpus is self-authored for Agent Lab. All fixture prose, facts, labels,
tokens, layout, and questions are dedicated to the public domain under
[CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/). No private user
material or third-party source text is included.

## What the corpus tests

Only the five `queryable_rag` cases count toward retrieval, answer, and citation
thresholds. Their expected source must appear within the recorded top-k rank,
all expected answer facts must be present, and each citation must expose the
fields in `citation_contract`. The two privacy passages deliberately repeat
phrasing while differing in the decisive policy fact. `irrelevant-garden.md` is
a ranking distractor.

The PNG is a direct-vision control, not a claim that Open WebUI knowledge-base
ingestion extracts images. `scanned-card.pdf` contains one raster image and no
PDF text operators. Its expected built-in extraction result is false, matching
the boundary established in decision 0005. It is excluded from the retrieval
denominator so an extraction failure cannot be mislabeled as an embedding,
generation, or citation failure. P5-T03 owns any later extractor decision; this
fixture does not add OCR, Docling, or a custom parser.

`questions.json` is the machine-readable source of truth. Every fixture entry
has an ID, relative path, media type, byte count, SHA-256, source label, unique
answer token, and role. Every case has an evaluation scope, question, expected
answer facts, expected filename, acceptable top-k rank (or `null` for a
control), and required citation fields. Queryable cases may also name sources
that must not outrank the expected source.

## Fixture generation

The Markdown, Python, and irrelevant/near-duplicate passages were written
directly as UTF-8 text. The binary assets were generated locally on macOS with
Python 3.12, Pillow 12.2.0, and ReportLab 4.4.9:

- `vision-card.png` is a 1000×600 RGB canvas containing only the source label,
  beacon fact, unique token, and simple geometric decoration.
- `archive-handbook.pdf` uses ReportLab's invariant mode and uncompressed text
  drawing, so its text is extractable and its metadata is stable.
- `scanned-card.pdf` uses ReportLab's invariant mode to place a generated
  1275×1650 RGB PNG as a single full-page image; the temporary PNG is not part
  of the corpus.

The fonts are macOS `/System/Library/Fonts/Helvetica.ttc`. Regeneration should
preserve semantic content, but the committed hashes are authoritative because
raster output can vary with font or imaging-library versions. Generated files
contain no network-derived assets.

## Integrity checks

From the repository root, verify the committed bytes against the manifest:

```sh
python3 - <<'PY'
import hashlib, json, pathlib

manifest = json.loads(pathlib.Path("evals/fixtures/rag/questions.json").read_text())
root = pathlib.Path(manifest["fixture_root"])
for fixture in manifest["fixtures"]:
    data = (root / fixture["path"]).read_bytes()
    assert len(data) == fixture["bytes"], fixture["path"]
    assert hashlib.sha256(data).hexdigest() == fixture["sha256"], fixture["path"]
print(f"verified {len(manifest['fixtures'])} fixture hashes")
PY
```

PDF parseability and the extraction boundary can be checked with `pdfinfo` and
any standard PDF text extractor. The text PDF must expose
`RAG-SOURCE-ARCHIVE-PDF` and `LANTERN-2746`; the scanned PDF must expose neither
`RAG-SOURCE-SCANNED-CARD` nor `SCAN-8842` without OCR.
