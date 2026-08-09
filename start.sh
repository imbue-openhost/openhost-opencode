#!/bin/bash
# Boot opencode + nginx front proxy for OpenHost.
#
# Topology:
#   browser
#     -> OpenHost router (subdomain opencode.<zone>; verifies owner
#        zone_auth, stamps X-OpenHost-Is-Owner: true, blocks anon)
#     -> container :8080          (nginx, SSE/WS-aware)
#     -> 127.0.0.1:4096           (opencode serve)
#
# Auth model:
#   opencode's own HTTP server has NO authentication in this deployment
#   (OPENCODE_SERVER_PASSWORD is intentionally unset). It binds
#   loopback-only (127.0.0.1) so nothing outside the container can
#   reach it directly. All external access flows through nginx, which
#   (a) is reached only via the OpenHost router, which blocks anonymous
#   traffic since there are no public_paths, and (b) additionally denies
#   any request lacking X-OpenHost-Is-Owner: true. Two independent gates
#   guard what is effectively remote shell access.
#
# Credential handling:
#   The Anthropic API key is fetched at boot from the OpenHost secrets
#   service via the router-mediated service proxy, using this app's
#   OPENHOST_APP_TOKEN. It is exported into the opencode process
#   environment ONLY. It is never written to any file under app_data /
#   app_temp_data (both are bind-mounted into apps with access_all_data,
#   e.g. file-browser, so neither isolates a credential) and never
#   committed to the image. If the secrets fetch fails, we fall back to
#   an ANTHROPIC_API_KEY env var if one happens to be present, else we
#   start anyway so the owner can configure auth from the UI.

set -euo pipefail

APP_USER="agent"
APP_UID="$(id -u "$APP_USER")"
APP_GID="$(id -g "$APP_USER")"

PERSIST="${OPENHOST_APP_DATA_DIR:-/data/app_data/opencode}"

# XDG dirs opencode honours. Sessions/auth DB under share, config under
# config, and the agent's working directory under projects.
XDG_DATA="$PERSIST/share"
XDG_CONFIG="$PERSIST/config"
PROJECT_DIR="$PERSIST/projects"

UPSTREAM_PORT=4096

# opencode default model. Overridable by the owner via the UI or by
# editing $XDG_CONFIG/opencode/opencode.json (which persists).
DEFAULT_MODEL="anthropic/claude-sonnet-4-5"

# ---------------------------------------------------------------------------
# Clean up any credential-bearing artifacts an earlier iteration of this
# app might have left under app_data (defence in depth; we never write
# them there now).
# ---------------------------------------------------------------------------
rm -f "$PERSIST/anthropic-api-key" "$PERSIST/api-key.txt" 2>/dev/null || true
# opencode's auth.json can hold provider credentials; keep it out of the
# bind-mounted persistent tier. We drive auth purely by env var instead.
rm -f "$XDG_DATA/opencode/auth.json" 2>/dev/null || true

mkdir -p "$XDG_DATA/opencode" "$XDG_CONFIG/opencode" "$PROJECT_DIR"

# The bind-mounted dirs are owned by root on first boot; hand them to
# the agent user so opencode (and its tool calls) can write.
chown -R "$APP_UID:$APP_GID" "$PERSIST" 2>/dev/null || true

# nginx scratch dirs (all under /tmp per nginx.conf.tmpl).
mkdir -p /tmp/nginx-client-body /tmp/nginx-proxy /tmp/nginx-fastcgi \
         /tmp/nginx-uwsgi /tmp/nginx-scgi

# ---------------------------------------------------------------------------
# Fetch the Anthropic API key from the OpenHost secrets service.
# ---------------------------------------------------------------------------
# POST {"keys":["ANTHROPIC_API_KEY"]} to the router service proxy; the
# router injects our identity + granted permissions and forwards to the
# secrets provider, which returns {"secrets":{"ANTHROPIC_API_KEY":"..."}}.
fetch_secret() {
    local router="${OPENHOST_ROUTER_URL:-}"
    local apptok="${OPENHOST_APP_TOKEN:-}"
    if [ -z "$router" ] || [ -z "$apptok" ]; then
        echo "[start.sh] secrets: OPENHOST_ROUTER_URL / OPENHOST_APP_TOKEN unset; skipping fetch" >&2
        return 1
    fi
    local resp
    resp="$(curl -fsS --max-time 15 \
        -H "Authorization: Bearer $apptok" \
        -H "Content-Type: application/json" \
        -X POST "$router/api/services/v2/call/secrets/get" \
        -d '{"keys":["ANTHROPIC_API_KEY"]}' 2>/dev/null)" || {
        echo "[start.sh] secrets: fetch call failed" >&2
        return 1
    }
    local key
    key="$(printf '%s' "$resp" | jq -r '.secrets.ANTHROPIC_API_KEY // empty' 2>/dev/null)" || key=""
    if [ -n "$key" ]; then
        printf '%s' "$key"
        return 0
    fi
    echo "[start.sh] secrets: ANTHROPIC_API_KEY not present in response" >&2
    return 1
}

SECRET_KEY="$(fetch_secret || true)"
if [ -n "${SECRET_KEY:-}" ]; then
    export ANTHROPIC_API_KEY="$SECRET_KEY"
    echo "[start.sh] Anthropic API key loaded from secrets service"
elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    echo "[start.sh] Anthropic API key taken from environment (secrets fetch unavailable)"
else
    echo "[start.sh] WARNING: no Anthropic API key available; opencode will start but the agent cannot run until a key is configured (store ANTHROPIC_API_KEY in the secrets app, then reload this app)"
fi
unset SECRET_KEY

# ---------------------------------------------------------------------------
# Seed opencode config (default model) if the owner hasn't written one.
# We never overwrite an existing config so owner edits persist.
# ---------------------------------------------------------------------------
CONFIG_FILE="$XDG_CONFIG/opencode/opencode.json"
if [ ! -f "$CONFIG_FILE" ]; then
    cat > "$CONFIG_FILE" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "model": "$DEFAULT_MODEL"
}
EOF
    chown "$APP_UID:$APP_GID" "$CONFIG_FILE" 2>/dev/null || true
    echo "[start.sh] Seeded default config with model $DEFAULT_MODEL"
fi

# ---------------------------------------------------------------------------
# Template nginx.conf with the upstream port.
# ---------------------------------------------------------------------------
NGINX_CONF="/run/openhost-opencode-nginx.conf"
UPSTREAM_PORT="$UPSTREAM_PORT" python3 - "$NGINX_CONF" <<'PY'
import os
import sys

dest = sys.argv[1]
with open("/opt/openhost-opencode/nginx.conf.tmpl", encoding="utf-8") as fh:
    conf = fh.read()
conf = conf.replace("__UPSTREAM_PORT__", os.environ["UPSTREAM_PORT"])
with open(dest, "w", encoding="utf-8") as fh:
    fh.write(conf)
PY

# ---------------------------------------------------------------------------
# Launch nginx first so /_healthz answers 200 within the cold-start
# grace window.
# ---------------------------------------------------------------------------
echo "[start.sh] Starting nginx front proxy on :8080"
nginx -c "$NGINX_CONF" -g 'daemon off;' &
NGINX_PID=$!

# ---------------------------------------------------------------------------
# Launch opencode serve as the agent user, loopback-only.
# ---------------------------------------------------------------------------
# XDG_* point opencode at the persistent dirs. We cd into the project
# dir so the agent's default working directory is persistent.
echo "[start.sh] Starting opencode serve on 127.0.0.1:$UPSTREAM_PORT"
gosu "$APP_USER" env \
    HOME="/home/$APP_USER" \
    XDG_DATA_HOME="$XDG_DATA" \
    XDG_CONFIG_HOME="$XDG_CONFIG" \
    XDG_CACHE_HOME="/tmp/opencode-cache" \
    ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" \
    PATH="/home/$APP_USER/.opencode/bin:/usr/local/bin:/usr/bin:/bin" \
    bash -c "cd '$PROJECT_DIR' && exec opencode serve --hostname 127.0.0.1 --port '$UPSTREAM_PORT'" \
    &
OPENCODE_PID=$!

# ---------------------------------------------------------------------------
# Supervision: if either process dies, tear the other down and exit.
# ---------------------------------------------------------------------------
trap 'kill -TERM "$NGINX_PID" "$OPENCODE_PID" 2>/dev/null; wait' TERM INT

set +e
wait -n "$NGINX_PID" "$OPENCODE_PID"
EXIT_CODE=$?
set -e

echo "[start.sh] Child exited (code=$EXIT_CODE); shutting down"
kill -TERM "$NGINX_PID" "$OPENCODE_PID" 2>/dev/null || true
wait || true
exit "$EXIT_CODE"
