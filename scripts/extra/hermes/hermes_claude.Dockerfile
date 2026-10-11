FROM nousresearch/hermes-agent

# Adds the Claude Code CLI on top of the official Hermes image, for
# terminal-delegation (see features.md "Supervisor agent" — Claude
# Code half confirmed working; see local_models.md for the full
# debugging story).
#
# Installed as root, at build time, into the installer's normal
# default location ($HOME/.local, i.e. /root/.local as root). Widens
# /root's own permissions (normally mode 700, blocking every
# non-root user from entering) rather than copying files out — the
# installer creates a launcher SCRIPT (not a compiled binary) that
# depends on other files under /root/.local/share; copying just the
# one file broke it ("unknown command 'claude'"). Confirmed needed:
# Hermes's tool execution runs as whatever PUID/PGID remaps to (1000
# here, not root), so the installed files must be reachable by that
# user specifically, not just usable by root.
USER root
RUN curl -fsSL https://claude.ai/install.sh | bash \
    && chmod 755 /root \
    && chmod -R a+rX /root/.local \
    && ln -s /root/.local/bin/claude /usr/local/bin/claude
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
