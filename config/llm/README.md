# LLM CLI configuration seed

These files are the versioned source for Agent Lab's LLM CLI configuration.
Copy the seed files into a private runtime directory before invoking `llm`:

```sh
mkdir -p .agent-lab/llm
cp config/llm/aliases.json config/llm/default_model.txt \
  config/llm/logs-off .agent-lab/llm/
export LLM_USER_PATH="$PWD/.agent-lab/llm"
export OLLAMA_HOST=http://127.0.0.1:11434
export LLM_LOAD_PLUGINS=llm-ollama
```

`LLM_USER_PATH` must not point at this source directory: `llm-ollama` writes a
capability cache beneath it. The runtime directory is ignored by Git. The
checked-in `logs-off` marker requests disabled SQLite logging by default.
Interactive chat in the pinned CLI can still create private conversation state,
so treat the entire runtime directory as sensitive. Delete the copied marker
only if you deliberately want logging enabled for all commands. Never copy
`keys.json`, `logs.db`, or plugin caches back here.
