FROM nousresearch/hermes-agent

# Combined image: BOTH Claude Code and Codex CLI on top of the
# official Hermes image. Built after both providers were
# independently proven on their own separate images (hermes_claude,
# hermes_codex) — this merge was deliberately deferred until then;
# see features.md's original hermes_codex naming discussion for the
# reasoning (separate first, merge once both halves are proven).
#
# CONFIRMED WORKING — this combined image was built and
# proven through both hermes_all (ephemeral) and
# hermes_dashboard_with_all (persistent gateway, reached remotely
# via the native Win11 app): three interleaved delegation calls
# through each, claude/codex/claude again, all clean, no login
# prompt, no cross-provider interference.
#
# Claude Code: native installer, widens /root's permissions rather
# than copying files out (the installer creates a launcher SCRIPT
# depending on other files under /root/.local/share — copying just
# the binary broke it: "unknown command 'claude'"). Needed because
# Hermes's tool execution runs as PUID/PGID (1000 here), not root.
#
# Codex: static musl release binary — self-contained, no node/npm,
# no /root permissions issue at all. Installed after Claude so a
# failure in either step is unambiguous in the build log rather
# than masked by layer caching.
USER root
RUN curl -fsSL https://claude.ai/install.sh | bash \
    && chmod 755 /root \
    && chmod -R a+rX /root/.local \
    && ln -s /root/.local/bin/claude /usr/local/bin/claude

# bubblewrap + pinned codex — same reasoning as hermes_codex's
# Dockerfile (bundled-bwrap panic + floating-latest divergence,
# both root-caused).
RUN apt-get update && apt-get install -y bubblewrap \
    && rm -rf /var/lib/apt/lists/* \
    && command -v bwrap

ARG CODEX_VERSION=rust-v0.147.0
RUN curl -fsSL -o /tmp/codex.tar.gz \
      https://github.com/openai/codex/releases/download/${CODEX_VERSION}/codex-x86_64-unknown-linux-musl.tar.gz \
    && tar -xzf /tmp/codex.tar.gz -C /tmp \
    && mv /tmp/codex-x86_64-unknown-linux-musl /usr/local/bin/codex \
    && chmod 755 /usr/local/bin/codex \
    && rm /tmp/codex.tar.gz \
    && codex --version \
    && claude --version
# ddgs: baked in at build time instead of relying on Hermes's
# documented lazy-install-on-first-use, so `web.backend: ddgs` works
# the moment a fresh container starts. Uses uv, not pip — this image
# has no pip at all in its venv ("No module named pip"; confirmed by
# hand: uv pip install ... succeeded immediately). --python points
# uv straight at the venv interpreter instead of relying on
# VIRTUAL_ENV/an auto-discovered .venv, which a plain `docker exec`
# doesn't reliably set. The import check fails the BUILD on a
# broken install, not a user's first web_search call.
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
    && mv /root/.local/bin/uv /usr/local/bin/uv

RUN uv pip install --python /opt/hermes/.venv/bin/python3 ddgs \
    && /opt/hermes/.venv/bin/python3 -c "import ddgs" \
    && echo "ddgs OK"
