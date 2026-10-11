FROM nousresearch/hermes-agent

# Adds the Codex CLI on top of the official Hermes image, for the
# Codex half of terminal-delegation (see features.md "Supervisor
# agent" — Codex half CONFIRMED WORKING — a real
# `codex exec` call returned a genuine response with no login
# prompt). Deliberately a SEPARATE image from hermes_claude — the
# proven Claude image stays frozen and untouched.
#
# Unlike the Claude Dockerfile, no /root permissions fix is needed
# here: Codex's Linux release asset (codex-x86_64-unknown-linux-musl)
# is a single statically linked musl binary — self-contained, no
# node/npm, no support files under /root/.local. It drops straight
# into /usr/local/bin and is executable by any uid as-is — confirmed:
# `codex --version` ran cleanly as uid=1000(hermes), same introspected
# identity as the Claude container ($HOME=/opt/data/home).
#
# curl uses -f so a failed download fails the BUILD, and the trailing
# `codex --version` proves the binary actually executes — both guards
# against the stale-build-cache class of bug that silently masked a
# failed install during the Claude build (see local_models.md).
#
# Pinning note: `releases/latest` floats. If a Codex release ever
# breaks the delegation pattern, switch the URL to a pinned tag
# (github.com/openai/codex/releases/download/<tag>/...) at that point
# — not preemptively.
USER root
# bubblewrap: REQUIRED for codex's workspace-write sandbox. The
# 0.147.0 musl binary's "will use the bundled bubblewrap" startup
# warning is a lie in this image — at shell-launch time it panics
# (launcher.rs: "no system bwrap on PATH and no bundled
# codex-resources/bwrap next to the Codex executable"; RUST_LOG
# trace, MSI-PC). System bwrap removes that leg
# entirely. Needs the seccomp=unconfined compose override to
# actually run (user namespaces) — see hermes_codex.yaml.
RUN apt-get update && apt-get install -y bubblewrap \
    && rm -rf /var/lib/apt/lists/* \
    && command -v bwrap

# PINNED to 0.147.0: `releases/latest` floats, so two
# images built hours apart could carry different binaries — this
# bit during the sandbox investigation, where identical-version
# across images was luck, not guarantee. Bump deliberately, retest
# the workspace-write delegation, then update the tag here.
ARG CODEX_VERSION=rust-v0.147.0
RUN curl -fsSL -o /tmp/codex.tar.gz \
      https://github.com/openai/codex/releases/download/${CODEX_VERSION}/codex-x86_64-unknown-linux-musl.tar.gz \
    && tar -xzf /tmp/codex.tar.gz -C /tmp \
    && mv /tmp/codex-x86_64-unknown-linux-musl /usr/local/bin/codex \
    && chmod 755 /usr/local/bin/codex \
    && rm /tmp/codex.tar.gz \
    && codex --version
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
