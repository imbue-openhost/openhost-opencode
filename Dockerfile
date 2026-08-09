# opencode (SST/anomalyco AI coding agent), packaged for OpenHost.
#
# Topology:
#   browser
#     -> OpenHost router (subdomain opencode.<zone>; verifies owner
#        zone_auth, stamps X-OpenHost-Is-Owner: true, blocks anon)
#     -> container :8080          (nginx front proxy, SSE/WS-aware)
#     -> 127.0.0.1:4096           (opencode serve)
#
# opencode's HTTP server both serves the browser SPA at / and exposes
# the JSON/OpenAPI API, an SSE event stream at /event, and PTY
# (interactive terminal) endpoints. nginx proxies all of it and never
# buffers streaming responses.
#
# The opencode binary is a self-contained native Bun executable
# installed via the official install script; there is no Node/Bun
# runtime dependency at runtime. The image ships the common toolchains
# an agent tends to reach for (git, python3, build tools, ripgrep) so
# tool calls work out of the box.

FROM docker.io/library/debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PYTHONUNBUFFERED=1

# ---------------------------------------------------------------------------
# System packages
# ---------------------------------------------------------------------------
#   nginx                 — SSE/WebSocket-aware front proxy on :8080
#   gosu                  — drop privileges to the unprivileged agent user
#   tini                  — PID 1 reaper / signal forwarder
#   curl, ca-certificates — install script + secrets fetch + TLS roots
#   git, openssh-client   — VCS operations the agent performs
#   ripgrep               — opencode's file/content search backend
#   python3 / build tools — common agent tool targets
#   unzip                 — required by the opencode install script
#   jq                    — JSON parsing in start.sh (secrets response)
RUN apt-get update -qq \
 && apt-get install -y --no-install-recommends \
        nginx \
        gosu \
        tini \
        curl \
        ca-certificates \
        git \
        openssh-client \
        ripgrep \
        python3 \
        python3-venv \
        build-essential \
        unzip \
        jq \
 && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Unprivileged runtime user
# ---------------------------------------------------------------------------
# opencode (and every agent-spawned command) runs as this user, not
# root. Its home is where the binary lives and where XDG dirs default
# before start.sh repoints them at the persistent app_data dir.
RUN useradd --create-home --home-dir /home/agent --shell /bin/bash --uid 1000 agent

# ---------------------------------------------------------------------------
# Install opencode as the agent user
# ---------------------------------------------------------------------------
# The official installer drops a self-contained binary in
# ~/.opencode/bin/opencode. Pin a version for reproducible builds.
ARG OPENCODE_VERSION=1.15.13
USER agent
RUN curl -fsSL https://opencode.ai/install | VERSION="${OPENCODE_VERSION}" bash \
 && /home/agent/.opencode/bin/opencode --version
USER root
ENV PATH="/home/agent/.opencode/bin:${PATH}"

# ---------------------------------------------------------------------------
# App files
# ---------------------------------------------------------------------------
COPY start.sh          /opt/openhost-opencode/start.sh
COPY nginx.conf.tmpl   /opt/openhost-opencode/nginx.conf.tmpl
COPY proxy_common.conf /opt/openhost-opencode/proxy_common.conf
RUN chmod 0755 /opt/openhost-opencode/start.sh

# OpenHost-routed port (nginx front proxy). opencode's own port (4096)
# stays loopback-only.
EXPOSE 8080

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/openhost-opencode/start.sh"]
