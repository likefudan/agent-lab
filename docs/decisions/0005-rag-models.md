# 0005 — Local RAG embedding and reranking models

- **Status:** Accepted
- **Qualified:** 2026-07-18
- **Application:** Open WebUI `0.10.2`
- **Image:** `ghcr.io/open-webui/open-webui@sha256:9fcea9c6e32ab60b0498f3986c6cdf651ddbe61db48d2213a3d28048ddd673d4`

## Decision

Use Open WebUI's local SentenceTransformers engine with
`sentence-transformers/all-MiniLM-L6-v2`. Pin Hugging Face revision
`1110a243fdf4706b3f48f1d95db1a4f5529b4d41`, disable model auto-update, and
retain the model in Open WebUI's persistent data volume. Do not configure a
reranker for the MVP: the embedding-only baseline already passed every fixed
queryable retrieval and citation case, so a cross-encoder cannot produce the
minimum justified gain.

The executable settings for a fresh, environment-authoritative Open WebUI
profile are:

```text
RAG_EMBEDDING_ENGINE=
RAG_EMBEDDING_MODEL=sentence-transformers/all-MiniLM-L6-v2
RAG_EMBEDDING_MODEL_AUTO_UPDATE=false
RAG_RERANKING_ENGINE=
RAG_RERANKING_MODEL=
RAG_RERANKING_MODEL_AUTO_UPDATE=false
```

Open WebUI `0.10.2` treats the blank embedding engine as its in-process local
SentenceTransformers path and a blank reranking model as disabled. These keys
are database-backed when persistent configuration is enabled; later profile
work must follow the persistence rules in decision 0004 rather than assuming
that environment changes overwrite an existing database.

## Pinned embedding artifact

The exact Linux/arm64 Open WebUI image already contains the complete selected
snapshot, so a fresh named volume receives it without a model-registry request.
The selected model is Apache-2.0 licensed according to the model card bundled
in that snapshot.

| Property | Pinned value |
| --- | --- |
| Model ID | `sentence-transformers/all-MiniLM-L6-v2` |
| Hugging Face revision | `1110a243fdf4706b3f48f1d95db1a4f5529b4d41` |
| Dimensions | 384 |
| Snapshot size | 91,578,225 bytes |
| Weights | `model.safetensors`, 90,868,376 bytes |
| Weights SHA-256 | `53aa51172d142c89d9012cce15ae4d6cc0ca6895895114379cacb4fab128d9db` |
| Snapshot tree SHA-256 | `065c71c5a0d43f37f21ac7f6eddec9a25aff5d7f2ccbfb3021f776f525669f51` |
| Container cache path | `/app/backend/data/cache/embedding/models/models--sentence-transformers--all-MiniLM-L6-v2` |
| License | Apache-2.0 |

The tree digest is SHA-256 over one UTF-8 line per snapshot file, sorted by
relative path and formatted as `path byte_count content_sha256` with a trailing
newline. It covers ten files. `config/models.json` records this digest and the
independently verified weights digest; the pinned container OCI digests commit
the surrounding application and preloaded cache.

Model loading used `sentence-transformers` 5.5.1, `transformers` 5.5.4, and
`huggingface-hub` 1.21.0 from the selected image. In an isolated offline
container, loading took 0.0500 seconds and encoding 64 short strings took
0.0535 seconds. Process peak RSS was 633.0 MiB. This is whole-process RSS for
the Python runtime and libraries, not incremental model memory, so it is useful
as a repeatable upper-bound observation rather than a model-only measurement.

## Fixed corpus and assertions

P0-T05 generated a temporary, self-authored corpus inside the pinned container.
It is intentionally not the redistributable acceptance fixture owned by
P5-T01. The corpus contained:

| Source | Content exercised |
| --- | --- |
| `operations.md` | Markdown and a numeric battery threshold |
| `token_rotation.py` | Source-code function retrieval |
| `backup.pdf` | Extractable text PDF with a unique schedule |
| `scan.pdf` | Image-only PDF with a unique access code |
| `privacy-near-a.md` | Strict-offline policy |
| `privacy-near-b.md` | Deliberately near-duplicate online-search policy |
| `multilingual.md` | Chinese offline text and a Spanish backup sentence |

Seven queryable cases covered English Markdown, code, PDF text, both
near-duplicate policies, Chinese, and Spanish. A pass required the expected
source filename in top 3; the stricter top-1 result and reciprocal rank were
also recorded. Citation-source assertions compared the retrieved document's
source metadata to the expected filename rather than checking answer prose.

| Candidate | Revision | License | Snapshot size | Top 1 | Top 3 | Citation source | MRR | Offline load |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| `sentence-transformers/all-MiniLM-L6-v2` | `1110a243…` | Apache-2.0 | 91,578,225 B | 7/7 | 7/7 | 7/7 | 1.000 | Pass |
| `TaylorAI/bge-micro-v2` | `3edf6d7d…` | MIT | about 35 MiB | 7/7 | 7/7 | 7/7 | 1.000 | Pass |

Both candidates are bundled and supported by Open WebUI's local engine. The
selected MiniLM artifact is the release's configured upstream default, has a
complete pinned snapshot and Apache-2.0 model card, and produced greater score
separation on most fixed cases. BGE Micro was smaller and faster in the short
CPU measurement, but did not improve a retrieval or citation assertion enough
to justify deviating from the upstream default.

The Chinese and Spanish cases are smoke tests only. They establish behavior for
the current small corpus, not broad multilingual quality. If P5 adds a
substantial non-English corpus and this model misses the fixed top-3 threshold,
a multilingual replacement must repeat this decision gate with its own exact
revision, hashes, license, storage, and offline proof.

## Image-only PDF boundary

Open WebUI's built-in `PyPDFLoader` extracted 57 characters from the text PDF
and zero characters from the image-only PDF. The scanned case was therefore an
explicit extraction assertion and was excluded from the embedding denominator:
an embedding model cannot retrieve text that the extractor never emits. This
is evidence for the later extraction decision P5-T03; it does not authorize
adding OCR, Docling, or a custom parser during model selection.

## Reranker gate

The embedding-only baseline was established before considering reranking. A
local cross-encoder would be enabled only if it improved fixed-corpus top-1 by
at least 10 percentage points or MRR by at least 0.05 without breaking citation
source assertions. The baseline is already 100% top-1 with MRR 1.000, so the
maximum possible gain is zero. No reranker was downloaded or configured.

P5 may reopen the gate only when its larger committed corpus demonstrates a
measurable miss. Any selected reranker must then pin its exact revision,
weights hashes, license, cache path, memory, storage, latency, and offline cold
start just as the embedding model is pinned here.

## Offline cold-start proof

The selected model first loaded with `local_files_only=true` in a container
whose network mode was `none`. A separate Open WebUI warm/restart test then:

1. started the exact arm64 image against a uniquely named temporary volume with
   offline mode and both model auto-update flags disabled;
2. reached `GET /health` successfully;
3. removed the warm container but retained its cache volume;
4. restarted against that volume with Docker network mode `none`;
5. reached `GET /health` again with zero restarts and verified the cached
   revision file exactly matched the pinned revision.

Only the `agent-lab-p0t05-*` containers and volume were removed afterward. No
unrelated Docker resource, Ollama artifact, or host cache was changed.

## Consequences

- P5-T02 can configure built-in RAG with this embedding model and no reranker.
- Offline profiles must set both model auto-update flags false and preserve the
  complete Open WebUI data volume, which owns the cache and vector database.
- The current image supplies the pinned snapshot; upgrades must recheck that
  the artifact and revision are still present before claiming first-run
  offline operation.
- The scanned-PDF result remains a document-extraction gap for P5-T03, not a
  reason to replace the embedding model or implement an Agent Lab RAG engine.
