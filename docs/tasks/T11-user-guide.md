# T11 User guide

- Depends on: T08
- Design sections: 6.5, 7.4, 7.5, 9
- Size: small (docs only)

## Goal

A first-time user can follow the guide to a working setup within 30 minutes (excluding the model download) and knows clearly what the service can and cannot do.

## Scope

In scope:

1. `docs/user-guide.md`:
   - Quick start: bootstrap → pull → gpu-limit apply → keys create → tunnel set-token → serve → first request.
   - Daily use: start and stop, check status, add and revoke keys, turn thinking on, local-only use (`--no-tunnel`).
   - Clients: link to T08's Cursor and opencode docs, plus generic settings for any tool that accepts a custom OpenAI base URL (base URL, key, model name, context limit, streaming required).
   - Expectations: speed, availability (down while the Mac sleeps or the lid is closed), Cursor's known limitations, which third parties see the data.
   - Uninstall: revert the GPU limit, delete the project directory, delete the tunnel in the Cloudflare dashboard.
   - Troubleshooting: out of memory, port in use, 401, 524, slow responses, interrupted model download, tunnel not connecting.
2. Update the quick start in `README.md`.

Out of scope: a web UI; auto-start configuration.

## Acceptance criteria

- [ ] Device test: follow the guide from scratch, record the actual time, and confirm every command can be copied and run as written.
- [ ] Every command and setting mentioned in the guide matches the current code.
