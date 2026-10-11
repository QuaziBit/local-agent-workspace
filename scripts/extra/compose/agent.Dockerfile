FROM ubuntu:24.04

ARG UID=1000
ARG GID=1000

RUN apt-get update && apt-get install -y \
    git curl ca-certificates build-essential \
    python3 python3-pip \
    bubblewrap \
    && rm -rf /var/lib/apt/lists/*
# bubblewrap: codex's workspace-write sandbox needs it (its bundled
# fallback panics when absent — root-caused); harmless
# for every other use of this image.

# Node.js 20 LTS — needed here because this Dockerfile installs
# Codex CLI via npm (below). NOTE: npm is NOT the only install path
# — Codex also ships standalone statically-linked musl binaries on
# its GitHub Releases (codex-x86_64-unknown-linux-musl.tar.gz),
# which is what docker/hermes_codex uses. The npm route stays here
# because it's proven working in this image; don't copy the
# "npm-only" assumption elsewhere. Claude Code's native installer
# below does NOT need Node.
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# OpenAI Codex CLI — installed globally as root (standard npm -g
# layout under /usr), so it stays readable/executable by the
# non-root user created below. Package name is scoped:
# @openai/codex — the unscoped "codex" on npm is an unrelated
# project that installs silently and does nothing useful.
# Pinned to match the hermes-side musl binary — one
# codex version across every image, bumped deliberately, never by
# rebuild timing.
RUN npm install -g @openai/codex@0.147.0

RUN if ! id -u ubuntu >/dev/null 2>&1; then \
      groupadd -g ${GID} dev && \
      useradd -m -u ${UID} -g ${GID} -s /bin/bash dev; \
    fi

USER ubuntu
WORKDIR /workspace

# Claude Code — native installer (current recommended method, no
# Node.js required; the older npm package is now the "advanced"
# path — see docs.claude.com if this ever needs revisiting). Runs
# as the non-root user since it installs into ~/.local/bin.
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/home/ubuntu/.local/bin:${PATH}"
