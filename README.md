# bottled-opencode

[opencode](https://opencode.ai) — the SST/anomalyco terminal AI coding
agent — packaged as a self-hosted **web app** for
[Cloud in a Bottle](https://github.com/imbue-openhost/Cloud in a Bottle).

The Cloud in a Bottle zone owner opens `https://opencode.<zone>/` and lands
straight in opencode's browser IDE (sessions, chat, file browsing,
integrated terminal) with no login screen — Cloud in a Bottle SSO carries them
in. The agent talks to Anthropic Claude using an API key pulled from
the Cloud in a Bottle secrets service at boot.

## Architecture

```
browser
  -> OpenHost router  (opencode.<zone>; verifies owner zone_auth,
                       stamps X-OpenHost-Is-Owner: true, blocks anon)
  -> container :8080  (nginx front proxy — SSE + PTY WebSocket aware)
  -> 127.0.0.1:4096   (opencode serve — the same binary that serves the
                       browser SPA, the JSON/OpenAPI API, the /event SSE
                       stream, and the PTY terminal endpoints)
```

`opencode serve` hosts the identical web UI that `opencode web` opens;
we run `serve` so nothing tries to launch a browser inside the
container.

## Auth model (Pattern E — no in-app auth, router + nginx gate)

opencode's HTTP server has **no authentication** in this deployment
(`OPENCODE_SERVER_PASSWORD` is intentionally left unset). Two
independent gates protect it instead:

1. **The Cloud in a Bottle router.** There are no `public_paths`, so the router
   rejects every anonymous request before it reaches the container and
   only forwards requests from the authenticated zone owner.
2. **nginx, in-container.** It denies any request that does not carry
   the router-stamped `X-OpenHost-Is-Owner: true` header (which the
   router sets itself and strips from client input, so it can't be
   spoofed). This is defence in depth: even a future misconfigured
   `public_paths` entry could never expose what is effectively remote
   shell access.

opencode binds `127.0.0.1` only, so it is never reachable except
through nginx.

Every opencode session can run arbitrary shell commands, read/write
files, and open interactive terminals **inside this container as the
`agent` user**. That is the whole point of the app, but it means the
app is strictly owner-only — there is deliberately no read-only or
public mode.

## Credential handling

The Anthropic API key is provisioned through the Cloud in a Bottle **secrets
service**, never baked into the image or written to disk:

1. The owner stores `ANTHROPIC_API_KEY` in the secrets app.
2. This app declares it consumes that key
   (`[[services.v2.consumes]]` with `grants = [{ key = "ANTHROPIC_API_KEY" }]`).
3. At boot, `start.sh` fetches it via the router service proxy
   (`POST $OPENHOST_ROUTER_URL/api/services/v2/call/secrets/get`) using
   the app's `OPENHOST_APP_TOKEN`, and exports it into the opencode
   process environment only.

The key is **never** written under `app_data` / `app_temp_data` (both
are bind-mounted into apps with `access_all_data`, so neither isolates
a credential), and opencode's own `auth.json` is kept out of the
persistent tier — auth is driven purely by the env var.

If the secrets fetch fails, the app falls back to an `ANTHROPIC_API_KEY`
environment variable if one is present, and otherwise still starts so
the owner can see the UI; the agent simply can't run until a key is
configured (store it in the secrets app and reload this app).

## Persistent state

Under `/data/app_data/opencode/`:

- `share/opencode/` — `XDG_DATA_HOME`: `opencode.db` (sessions +
  messages), `storage/`, logs. Sessions survive restarts.
- `config/opencode/opencode.json` — `XDG_CONFIG_HOME`: the default
  model config. Seeded once with `anthropic/claude-sonnet-4-5`; owner
  edits persist and are never overwritten.
- `projects/` — the agent's working directory.

## Changing the model

Edit `config/opencode/opencode.json` (visible in a file-browser app or
via the opencode UI) and set `"model"` to any
`anthropic/<model>` id, then reload the app. Run `opencode models
anthropic` locally to see valid ids.

## Deploying

```
oh app deploy https://github.com/imbue-openhost/bottled-opencode --name opencode --wait
```

Make sure `ANTHROPIC_API_KEY` is stored in the secrets app and that
this app is granted the `{ key = "ANTHROPIC_API_KEY" }` permission at
install time (approve the permission prompt, or pass
`--grant-permissions-v2`).
