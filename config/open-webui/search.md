# Open WebUI search configuration

Agent Lab uses the keyless DuckDuckGo backend bundled with Open WebUI 0.10.2.
`apply-profile.sh` writes only fields supported by that pinned image. It does
not configure a hosted model, search API credential, proxy, external loader, or
permanent knowledge collection.

- `offline`: search disabled and no engine selected.
- `online-manual`: DuckDuckGo is available after the user explicitly chooses
  web search in Open WebUI.
- `online-automatic`: the same local search tool may be offered to a qualified
  model for tool selection.

Fetched pages are transient search context. Persisting one requires a separate,
explicit document or URL ingestion action in Open WebUI.
