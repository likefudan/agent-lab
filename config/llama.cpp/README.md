# llama.cpp backend (detect / optional manage)

Agent Lab treats `llama_cpp` as a first-class OpenAI-compatible peer on
`127.0.0.1:11437` (see `config/backends.json` and decision 0011).

## Status

| State | Meaning |
| --- | --- |
| `missing` | No `llama-server` / `llama-cli` binary and no verified GGUF pin |
| `stopped` | Binary present but no healthy listener on the catalog port |
| `running` | Health probe `GET /v1/models` succeeds |
| `candidate` | Model pins in `config/models.json` remain unverified until a GGUF digest is recorded (decision 0012) |

## Optional start

`agent-lab backend start llama_cpp` only runs when:

1. A server binary is on `PATH` (`llama-server` preferred), and
2. `AGENT_LAB_LLAMA_CPP_MODEL` points at a local `.gguf` file (or
   `AGENT_LAB_LLAMA_CPP_MODEL` is set to an absolute path).

There is no Homebrew bottle or GGUF pin on the qualification host yet; do not
invent digests. Install llama.cpp and obtain a verified GGUF before promoting
`llama_cpp` slots from `candidate` to `executable`.

## LM Studio

`lm_studio` is detect-only: Agent Lab probes `127.0.0.1:1234/v1/models` (or the
catalog port) and never launches the GUI app.
