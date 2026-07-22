# Backup and recovery

Agent Lab backups contain the Open WebUI data volume and versioned runtime
configuration. They can include the private `.env`, password hashes, chat
history, uploaded documents, and vectors, so store them like credentials.
Ollama model weights and container images are excluded because their immutable
identifiers make them reproducible.

Before an upgrade, profile experiment, or risky recovery operation, confirm
the stack is healthy and choose an encrypted destination outside the repository.
Estimate available space from the Docker volume; backups are full snapshots,
not incremental archives. Retention and secure deletion are operator policy.

Create a consistent backup in an explicit location with enough free space:

```sh
bin/agent-lab backup --destination "/Volumes/Secure Backups/Agent Lab"
```

The script temporarily stops Open WebUI while snapshotting the volume and
restarts it on exit. Ollama remains available. The archive includes a manifest,
per-file SHA-256 hashes, component version, profile, timestamp, inclusion list,
and exclusions. A sidecar hash protects the outer archive.

Immediately verify the sidecar and store both files together:

```sh
shasum -a 256 -c /path/to/agent-lab-backup-TIMESTAMP.tar.gz.sha256
```

Restore is non-destructive by default and creates a new Docker volume:

```sh
bin/agent-lab restore --archive /path/to/agent-lab-backup-TIMESTAMP.tar.gz
```

Use `--target-volume` to choose a new name and `--config-destination` to extract
configuration into an existing empty directory. Restore rejects traversal,
unexpected members, corrupt hashes, incompatible versions, existing volumes,
nonempty config destinations, and the live volume name.

Restoring the configuration can expose the original local administrator
credentials. Restrict the destination before inspection, never restore into a
shared directory, and do not publish manifests or directory listings that may
reveal private filenames. Model weights must be recovered separately with the
catalog-verified online pull procedure below.

## Guarded live recovery drill

Live replacement is intentionally not automated. This prevents a typo or
malicious archive from deleting the only copy of user data. To recover:

1. Create and verify a fresh pre-restore backup in a different directory.
2. Run restore into a new volume and inspect its manifest and contents.
3. Start a disposable Open WebUI container on another loopback port with the
   restored volume; verify sign-in, a conversation, and a RAG query.
4. Stop Agent Lab. Rename neither volume: update a reviewed Compose override to
   point at the restored volume, then start and repeat health/smoke tests.
5. Retain the old live volume and pre-restore archive until the recovery is
   accepted. Deleting them is a separate, explicit operator action.

Never copy a running SQLite database directly and never delete the live volume
as a first recovery step.

## Model download and integrity recovery

Ollama model weights are reproducible and excluded from Agent Lab backups. The
catalog is the authority for the exact manifest and blob digests. Diagnose with
read-only commands first:

```sh
bin/agent-lab models list
bin/agent-lab models verify
bin/agent-lab status --json | jq '.models'
```

### Interrupted model pull

An interrupted pull must not change the catalog. Ollama may retain partial or
content-addressed data that a later pull can reuse.

1. Confirm that the alias is `missing` or fails verification and that there is
   enough free disk space.
2. In an online profile, rerun the supported **network action** and confirm the
   displayed tag and approximate size before accepting it:

   ```sh
   bin/agent-lab models pull qwen-4b
   bin/agent-lab models verify qwen-4b
   ```

   Substitute only another executable alias listed by
   `bin/agent-lab models list`. Pulls remain prohibited in the offline profile.
3. If a second attempt is interrupted or the final digest differs, preserve the
   files and logs for diagnosis. Do not clear the whole Ollama store; blobs may
   be shared by other verified models.

### Model digest mismatch

A digest mismatch can mean local corruption or that a mutable upstream tag no
longer resolves to the qualified artifact. Do not load the artifact, change the
expected digest, or silently approve the new bytes.

1. Record the alias, expected digest, actual digest, Ollama version, and free
   disk reported by `bin/agent-lab status --json`.
2. Run `bin/agent-lab models pull ALIAS` once during an explicit online
   maintenance window. The command verifies every downloaded blob and preserves
   an unapproved result for inspection.
3. If verification still fails, stop. A newly resolved upstream artifact needs
   the full model-qualification process and a reviewed catalog change. Continue
   with another already-verified approved model.
4. Removing a tag with `ollama rm TAG` is **destructive** and is not a repair or
   first response. Use it only after the mismatch has been recorded, a verified
   alternative is available, shared data implications have been reviewed, and
   the operator explicitly chooses to discard that local artifact. Never remove
   files directly from `~/.ollama/models`.

Failed loads with valid digests are runtime incidents; follow
[An approved model fails to load](operations.md#an-approved-model-fails-to-load).

## Corrupted Open WebUI data

Treat repeated SQLite errors, failed migrations, or failures tied to one
persistent volume as possible corruption. A merely unhealthy container is not
proof of corruption; first follow [Open WebUI is unhealthy](operations.md#open-webui-is-unhealthy).

1. Stop writes with the non-destructive `bin/agent-lab stop` **service action**.
2. Preserve the suspect state before repair attempts. Create an archive in an
   explicit secure destination; label it as possibly corrupt and retain its
   sidecar hash.

   ```sh
   bin/agent-lab backup --destination "/Volumes/Secure Backups/Agent Lab"
   ```

3. Select the most recent known-good archive and verify its outer hash before
   restore:

   ```sh
   shasum -a 256 -c /path/to/agent-lab-backup-TIMESTAMP.tar.gz.sha256
   bin/agent-lab restore --archive /path/to/agent-lab-backup-TIMESTAMP.tar.gz
   ```

   Restore creates a new volume and does not modify the live one.
4. Follow the guarded live recovery drill above: test sign-in, an existing
   conversation, a document retrieval with citations, and the embedding cache
   on a disposable loopback port before reviewing any Compose override.
5. Retain the original volume, the suspect-state archive, and the pre-restore
   archive until a second operator accepts recovery.

Do not run SQLite repair commands against the only copy, copy individual Chroma
directories between volumes, or let Open WebUI initialize an empty replacement
under the live volume name.

## Disposable recovery drill checklist

A second operator should exercise these high-risk paths using disposable data,
never the live volume:

- restore rejects a corrupted outer archive, a bad nested hash, unexpected
  members, path traversal, and an incompatible Open WebUI version;
- restore refuses the live volume name, an existing target volume, and a
  nonempty configuration destination;
- an interrupted model pull can be resumed and must pass catalog verification
  before use;
- a deliberately altered model manifest is detected without deleting it;
- the restored temporary WebUI preserves sign-in, conversations, settings,
  documents, vectors, RAG citations, and the pinned embedding cache; and
- switching a reviewed Compose override back to the original volume recovers
  the prior state without renaming or deleting either volume.

Record who performed the drill, archive/volume identifiers, versions, commands,
results, and cleanup decisions. Cleanup of disposable volumes and archives is a
separate **destructive** operator action after evidence has been reviewed.
