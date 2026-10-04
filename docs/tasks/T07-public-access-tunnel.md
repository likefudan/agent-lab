# T07 Public access: api.llmat.dev (Cloudflare Tunnel)

- Depends on: T06 (needs only T05 technically; going public after the profile is stable is safer)
- Design sections: 6.5, 7.1, 7.2, 7.3, 7.5, 8.1, 9
- Size: medium

## Goal

Make `https://api.llmat.dev/v1` reach the gateway on the Mac from the internet, without opening any inbound port, without leaving files outside the project directory, and without registering system services.

## Scope

In scope:

1. A guide for the one-time manual steps, `docs/setup-cloudflare.md` (done by the owner in the Cloudflare dashboard):
   - create the tunnel `agent-lab` in Zero Trust;
   - add the Public Hostname `api.llmat.dev` → `http://127.0.0.1:8000`;
   - add a Cache Rule for `api.llmat.dev` (bypass cache);
   - add one WAF rate-limiting rule (threshold chosen in this task from T06's measured throughput, well above normal use);
   - confirm no bot protection that shows a challenge page is enabled for the subdomain;
   - copy the tunnel token.
2. `alab tunnel set-token`: reads the token from stdin (no echo) and saves it to `var/secrets/tunnel-token` (mode 600).
3. Once the gateway is healthy, `alab serve` starts `cloudflared tunnel run`:
   - using the pinned binary T01 downloaded into `.tools/bin/`;
   - passing the token through the `TUNNEL_TOKEN` environment variable, never as a command-line argument;
   - pointing cloudflared's logs and config under `var/`, so it never reads or writes `~/.cloudflared`;
   - with cloudflared's auto-update disabled;
   - `--no-tunnel` serves locally only.
4. Sleep prevention: while `alab serve` runs, it keeps a `caffeinate -i` child process, which `stop` ends.
5. `alab status` shows the tunnel connection state; `alab tunnel check` requests `https://api.llmat.dev/healthz` and an authenticated `/v1/models` through Cloudflare and reports the results.
6. New `doctor` checks: cloudflared binary integrity, whether a token is set, and whether `api.llmat.dev` resolves.
7. Heartbeat check: with a request that only starts producing output after 150 seconds (a fake backend in test mode, or a long prompt), confirm the streaming connection through Cloudflare stays open.

Out of scope: client configuration (T08); creating the tunnel or DNS records automatically (would need extra Cloudflare API credentials for little benefit).

## Acceptance criteria

- [ ] Isolation check: `~/.cloudflared` is never created or modified; `launchctl list` shows no new services; the tunnel token never appears in `ps` output.
- [ ] Device test: after `alab serve`, from another device on a different network (for example a laptop on a phone hotspot), curl `https://api.llmat.dev/v1/models`: 401 without a key, `qwen3.8-27b` with one.
- [ ] Device test: a streaming request through `api.llmat.dev` that waits more than 100 seconds before the first token stays connected (paste timestamps).
- [ ] Device test: after `alab stop`, public requests get Cloudflare's error page, local ports 8000/8100 are free, and the cloudflared and caffeinate processes have exited.
- [ ] Unit tests: token file permissions, no token in command-line arguments, `--no-tunnel` behaviour.
- [ ] CI passes (CI never connects a real tunnel).
