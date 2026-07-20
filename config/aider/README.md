# Aider configuration seed

This directory pins the repository-aware coding client and its qualified local
model settings for the default `ollama` backend. Prefer
`agent-lab backend use <id>` / `agent-lab apply-inference`, which write
`.agent-lab/aider/aider.conf.yml` for the active backend (Ollama `/v1` or
another loopback OpenAI-compatible `/v1`).

Manual copy (ollama path only):

```sh
cp /path/to/agent-lab/config/aider/aider.conf.yml .aider.conf.yml
cp /path/to/agent-lab/config/aider/aider.model.settings.yml \
  .aider.model.settings.yml
cp /path/to/agent-lab/config/aider/aider.model.metadata.json \
  .aider.model.metadata.json
mkdir -p .agent-lab/aider
```

The ollama seed selects `openai/gemma4:12b` through Ollama's loopback-only `/v1`
endpoint. `ollama` is a local compatibility placeholder accepted as the OpenAI
API key; it is not a secret or hosted credential. The 4,096-token context and
1,024-token completion budget are the settings qualified by Agent Lab, not the
artifact's theoretical maximum context.

`whole` is the qualified edit format for the local Gemma model. Repository maps
are disabled to preserve room in the tested context. Aider edits the worktree
but never auto-commits, commits dirty state, modifies `.gitignore`, runs shell
suggestions, or contacts analytics/update services. Review with `git diff` and
run the repository's tests before committing yourself. Conversation history is
written beneath the ignored `.agent-lab/aider/` runtime directory. Keep it and
any copied local configuration private according to the target repository's
policy; never add hosted API credentials to this seed.
