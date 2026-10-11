#!/usr/bin/env bash
#
# setup.sh — WSL/Linux environment bootstrap
#
# Companion to architecture.md and getting_started.md. Automates
# Phases 0–3 and 5 of that runbook. Safe to re-run: every file write
# is skip-if-exists, every git operation is safe on an already-
# initialized repo.
#
# Scope: workspace skeleton, infrastructure repo, all nine compose
# profiles (dev/docs/review/sandbox — the four core profiles; plus
# ollama/hermes/hermes_dashboard/hermes_claude/
# hermes_dashboard_with_claude — the local-agent tier, run and
# verified, see local_models.md), default AGENTS.md, the vault,
# orientation-layer scaffolds. Obsidian install (Phase 4) is
# included but flagged — it needs sudo and is a system package, not
# workspace state.
#
# OUT OF SCOPE — do not add these here without updating
# architecture.md first: the chat UI stack, the revived-workstation
# hardware plan. Each depends on a decision or hardware this script
# can't make for you.
#
# Intended final location once verified: infrastructure/bootstrap/setup.sh
#
# Usage:
#   setup.sh                bootstrap (original behavior, safe to re-run)
#   setup.sh --verify       NO writes — regenerate every file embedded
#                           in this script into a temp mirror, diff
#                           against the live tree, exit non-zero on any
#                           drift. Exists because create_file_if_missing
#                           never updates an existing file: hot-edit a
#                           live file and forget to back-port it here,
#                           or edit here and forget to delete + regen
#                           the live one, and the two copies drift
#                           SILENTLY — same failure class as the
#                           stale-build-cache bug. Run it after touching
#                           either side.
#   setup.sh --secrets-only ONLY seed_secrets() — creates/repairs
#                           ~/.secrets and its four subdirs (claude-home,
#                           codex-home, hermes-home + the two guarded
#                           seed files) without touching ~/workspace at
#                           all. Same function bootstrap mode calls —
#                           not a second copy of the logic, just a way
#                           to run that one piece independently (e.g.
#                           recreating secrets without rebuilding the
#                           workspace, or vice versa). Idempotent: safe
#                           to run against an existing ~/.secrets, never
#                           overwrites real login content.

set -euo pipefail

WORKSPACE_ROOT="$HOME/workspace"
INFRA="$WORKSPACE_ROOT/infrastructure"
VAULT="$WORKSPACE_ROOT/vault"
AI="$WORKSPACE_ROOT/ai"

MODE="bootstrap"
case "${1:-}" in
  --verify) MODE="verify" ;;
  --secrets-only) MODE="secrets-only" ;;
  "") ;;
  *) echo "usage: $0 [--verify|--secrets-only]" >&2; exit 2 ;;
esac
VERIFY_TMP=""
VERIFY_TOTAL=0
VERIFY_DRIFT=0
if [ "$MODE" = "verify" ]; then
  VERIFY_TMP="$(mktemp -d)"
  trap 'rm -rf "$VERIFY_TMP"' EXIT
fi

log() { echo -e "\n== $* =="; }

_SCAFFOLD=0

create_file_if_missing() {
  local path="$1"
  if [ "$MODE" = "verify" ]; then
    # Write the embedded content to a temp mirror and diff it against
    # the live file — never touch the live tree itself.
    local mirror="$VERIFY_TMP$path"
    mkdir -p "$(dirname "$mirror")"
    cat > "$mirror"
    VERIFY_TOTAL=$((VERIFY_TOTAL+1))
    if [ ! -f "$path" ]; then
      echo "  MISSING: $path (embedded here, absent on disk)"
      VERIFY_DRIFT=$((VERIFY_DRIFT+1))
    elif [ "$_SCAFFOLD" = "1" ]; then
      # Scaffolds (me.md, current_context.md, ...) are human-filled
      # BY DESIGN — content drift is the point, so existence is the
      # only thing checked.
      echo "  ok (scaffold, content not compared): $path"
    elif diff -q "$mirror" "$path" >/dev/null 2>&1; then
      echo "  ok:      $path"
    else
      echo "  DRIFT:   $path"
      diff -u --label "embedded in setup.sh" --label "live: $path" \
        "$mirror" "$path" | sed 's/^/    /' || true
      VERIFY_DRIFT=$((VERIFY_DRIFT+1))
    fi
    return 0
  fi
  if [ -f "$path" ]; then
    echo "  exists, skipping: $path"
  else
    mkdir -p "$(dirname "$path")"
    cat > "$path"
    echo "  created: $path"
  fi
}

# Identical to create_file_if_missing at bootstrap time; at --verify
# time checks existence only, never content (see comment above).
create_scaffold_if_missing() {
  _SCAFFOLD=1
  create_file_if_missing "$1"
  _SCAFFOLD=0
}

# All ~/.secrets seeding lives in ONE place — this function — so
# bootstrap mode and --secrets-only mode call the exact same code,
# never two copies that can drift apart. Idempotent and safe to
# re-run: every guard below only ever ADDS a missing seed, never
# overwrites real content.
seed_secrets() {
  mkdir -p "$HOME/.secrets"
  chmod 700 "$HOME/.secrets"

  # Claude Code session persistence — bind-mounted from here, not a
  # Docker-managed volume, so it's host-visible/removable like
  # everything else under ~/.secrets/. Two paths, not one: Claude Code
  # splits its state across ~/.claude/ (credentials.json lives here)
  # and a SEPARATE sibling file ~/.claude.json (onboarding/account
  # status — checked first; if it's missing, Claude Code re-prompts
  # for login even with a valid credential sitting in ~/.claude/).
  # Both must persist or the login silently doesn't survive a recreate.
  #
  # claude-home.json must be seeded with valid JSON, not left genuinely
  # empty. A touch'd 0-byte file causes Claude Code's very first launch
  # to fail with "configuration file is corrupted: JSON Parse error:
  # Unexpected EOF" — confirmed on a real bootstrap, not hypothetical.
  # An empty object is enough; Claude Code fills it in from there.
  #
  # Guarded, not unconditional: only seed {} if the file is missing or
  # still genuinely empty. An unconditional `echo '{}' >` would wipe a
  # real login's content back to {} on every re-run — this file isn't
  # covered by create_file_if_missing, so it needs its own guard.
  mkdir -p "$HOME/.secrets/claude-home"
  if [ ! -s "$HOME/.secrets/claude-home.json" ]; then
    echo '{}' > "$HOME/.secrets/claude-home.json"
  fi
  chmod 700 "$HOME/.secrets/claude-home"
  chmod 600 "$HOME/.secrets/claude-home.json"

  # Codex CLI persistence — bind-mounted at /home/ubuntu/.codex in every
  # profile, same pattern as claude-home. CRITICAL: config.toml must
  # force file-based credential storage BEFORE the first login, or the
  # login silently doesn't survive a recreate. Codex's
  # cli_auth_credentials_store defaults to "auto" (OS keyring when
  # available, else auth.json) — inside a minimal container, auto
  # routes the credential somewhere that dies with the container, so
  # auth.json never appears on the mounted path and every recreate
  # re-prompts for login. Debugged for real across two sessions; with
  # "file" forced, auth.json lands on the mount and login persists.
  # Guarded like claude-home.json: never overwrite a file that already
  # has content (a user may have added their own config.toml settings).
  mkdir -p "$HOME/.secrets/codex-home"
  if [ ! -s "$HOME/.secrets/codex-home/config.toml" ]; then
    echo 'cli_auth_credentials_store = "file"' > "$HOME/.secrets/codex-home/config.toml"
  fi
  chmod 700 "$HOME/.secrets/codex-home"

  # Hermes Agent's own persistence directory (config.yaml, memory,
  # sessions) — bind-mounted, same host-visible pattern as everything
  # else under ~/.secrets/. Confirmed working end-to-end
  # local Ollama chat, Claude Code delegation, Codex delegation, and
  # the dashboard/gateway reachable from both a browser and the native
  # desktop app over WSL2's default localhost forwarding — see
  # local_models.md and hermes_operations.md.
  mkdir -p "$HOME/.secrets/hermes-home"
  chmod 700 "$HOME/.secrets/hermes-home"

  # Git identity for the hermes user's HOME (/opt/data/home in every
  # container — bind-mounted here, so this is seeded ONCE and every
  # container just inherits it, no docker exec needed after a fresh
  # bootstrap). Without it, agent_inbox's nested repo (needed for
  # Codex's trust check) refuses to commit: "Author identity
  # unknown... Please tell me who you are" — hit for real via the
  # Hermes desktop app's Review/Commit UI. Guarded like every other
  # seed here: never overwrite a value the user already set (by hand,
  # or via an earlier version of this same seed).
  mkdir -p "$HOME/.secrets/hermes-home/home"
  if [ ! -f "$HOME/.secrets/hermes-home/home/.gitconfig" ]; then
    cat > "$HOME/.secrets/hermes-home/home/.gitconfig" << 'GITCONFIG_EOF'
[user]
	email = hermes@localhost
	name = Hermes Agent
GITCONFIG_EOF
  fi
}

git_commit_if_changes() {
  if [ "$MODE" = "verify" ]; then return 0; fi
  local repo="$1" msg="$2"
  (cd "$repo" && git add . && git commit -m "$msg") \
    || echo "  nothing new to commit in $repo"
}

# ── --secrets-only: handled before Phase 0, needs none of its checks ──
# No docker, no git identity, no workspace at all — just the one
# function, then exit. Runs seed_secrets() directly rather than
# falling through Phase 1's "if MODE=bootstrap" guard, since
# everything else in Phase 1 (workspace mkdir, the ai/ symlink) is
# exactly what this mode exists to skip.
if [ "$MODE" = "secrets-only" ]; then
  log "Secrets only: seeding ~/.secrets"
  seed_secrets
  echo "  ~/.secrets ready (claude-home, codex-home, hermes-home)"
  exit 0
fi

# ── Phase 0 — Preflight ──────────────────────────────────────────
# Skipped entirely under --verify: verify only reads and diffs, so it
# must work on a machine that has neither docker nor a git identity.
if [ "$MODE" = "bootstrap" ]; then

log "Phase 0: Preflight"

command -v docker >/dev/null || { echo "docker not found — install it first"; exit 1; }
command -v git    >/dev/null || { echo "git not found — install it first"; exit 1; }
docker compose version >/dev/null || { echo "docker compose v2 not found"; exit 1; }

ACTUAL_UID=$(id -u)
ACTUAL_GID=$(id -g)
if [ "$ACTUAL_UID" != "1000" ] || [ "$ACTUAL_GID" != "1000" ]; then
  echo "  NOTE: your UID:GID is $ACTUAL_UID:$ACTUAL_GID, not the assumed 1000:1000."
  echo "  Edit infrastructure/docker/agent/Dockerfile's ARG UID/GID after this runs."
fi

if ! git config user.email >/dev/null 2>&1 || ! git config user.name >/dev/null 2>&1; then
  echo "  Git has no identity configured — the commit steps below will fail."
  echo "  Run these first, then re-run this script:"
  echo "    git config --global user.email \"you@example.com\""
  echo "    git config --global user.name \"Your Name\""
  exit 1
fi

# Finding test run: Docker auto-creates missing
# bind-mount source directories AS ROOT the first time a compose
# profile runs — if that happens before setup.sh ever does (e.g. an
# ollama.yaml run against a not-yet-bootstrapped path), the resulting
# ~/workspace is root-owned and every mkdir below fails with
# "Permission denied," with no hint as to why. Catch it here with a
# clear diagnosis instead of a bare mkdir failure three phases later.
if [ -e "$WORKSPACE_ROOT" ] && [ ! -w "$WORKSPACE_ROOT" ]; then
  echo "  FAIL: $WORKSPACE_ROOT exists but isn't writable by $(whoami)."
  echo "  Likely a root-owned leftover from Docker auto-creating"
  echo "  bind-mount source directories before setup.sh ever ran."
  echo "  Fix, then re-run:"
  echo "    sudo chown -R $(whoami):$(whoami) $WORKSPACE_ROOT   # keep contents"
  echo "    sudo rm -rf $WORKSPACE_ROOT                          # discard instead"
  exit 1
fi

echo "  preflight OK"

fi  # MODE=bootstrap (Phase 0)

# ── Phase 1 — Workspace skeleton ─────────────────────────────────
# Skipped entirely under --verify: every line here writes (mkdir,
# chmod, secret seeding, symlink) and --verify's contract is "no
# writes outside its own temp dir."
if [ "$MODE" = "bootstrap" ]; then

log "Phase 1: Workspace skeleton"

mkdir -p "$WORKSPACE_ROOT"/{projects,backups,archives}
mkdir -p "$WORKSPACE_ROOT"/projects/sandbox
mkdir -p "$VAULT"/{agent_inbox,programming,security,research,ideas,projects,personal,archive}
# agent_inbox subfolders: organization for agent-written
# output WITHOUT adding a second writable root — the whole inbox
# mount is rw, so these are writable by every tool automatically
# (Hermes write_file: safe-root prefix match; Codex: keep
# workdir=/vault/agent_inbox and use a RELATIVE path like
# reports/foo.md — workdir must stay at the .git root for the
# trust check).
mkdir -p "$VAULT"/agent_inbox/{reports,research,sessions}
mkdir -p "$INFRA"/{compose,docker/agent,bootstrap,configs,templates,scripts,docs/adr}
mkdir -p "$WORKSPACE_ROOT/.vscode"
mkdir -p "$WORKSPACE_ROOT"/models/{ollama,embeddings,vector-db}
# See seed_secrets() above — single source of truth, shared with --secrets-only.
seed_secrets

# ai/ is git-tracked content that lives INSIDE the infrastructure repo
# (architecture.md, Infrastructure Repository: "ai/ lives inside this
# repo... ~/workspace/ai/ is simply the checkout"). Create the real
# directory under infrastructure/, then symlink the workspace-level
# path to it — every existing ${AI_DIR} reference keeps working
# unchanged, but the content is now actually version-controlled.
mkdir -p "$INFRA/ai"/{prompts,templates,coding-standards,security-policies,workflows}
if [ ! -e "$AI" ]; then
  ln -s "$INFRA/ai" "$AI"
  echo "  linked: $AI -> $INFRA/ai"
fi

echo "  workspace directories present"

fi  # MODE=bootstrap (Phase 1)

# ── Phase 2 — Infrastructure repository ──────────────────────────
log "Phase 2: Infrastructure repository"

create_file_if_missing "$INFRA/workspace.env" << 'EOF'
WORKSPACE_ROOT="$HOME/workspace"
PROJECTS_DIR="$WORKSPACE_ROOT/projects"
VAULT_DIR="$WORKSPACE_ROOT/vault"
AI_DIR="$WORKSPACE_ROOT/ai"
INFRA_DIR="$WORKSPACE_ROOT/infrastructure"
MODELS_DIR="$WORKSPACE_ROOT/models"
BACKUPS_DIR="$WORKSPACE_ROOT/backups"
ARCHIVES_DIR="$WORKSPACE_ROOT/archives"
SECRETS_DIR="$HOME/.secrets"
EOF

create_file_if_missing "$INFRA/docker/agent/Dockerfile" << 'EOF'
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
EOF

create_file_if_missing "$INFRA/compose/dev.yaml" << 'EOF'
services:
  dev:
    build: ../docker/agent
    working_dir: /workspace
    # Required for codex's workspace-write sandbox: bubblewrap needs
    # unprivileged user namespaces, which the default seccomp profile
    # blocks — full root-cause note in hermes_codex.yaml.
    security_opt:
      - seccomp=unconfined
    env_file:
      - ${SECRETS_DIR}/${PROJECT}.env
    volumes:
      - ${PROJECTS_DIR}/${PROJECT}:/workspace
      - ${VAULT_DIR}/agent_inbox:/vault/agent_inbox
      - ${VAULT_DIR}/programming:/vault/programming:ro
      - ${VAULT_DIR}/security:/vault/security:ro
      - ${VAULT_DIR}/research:/vault/research:ro
      - ${VAULT_DIR}/ideas:/vault/ideas:ro
      - ${VAULT_DIR}/projects:/vault/projects:ro
      - ${VAULT_DIR}/archive:/vault/archive:ro
      - ${AI_DIR}:/ai:ro
      # vault/personal/ is deliberately absent — mounting the whole
      # vault as one unit would include it; there is no way to
      # exclude a subdirectory from a single parent bind mount.
      - ${SECRETS_DIR}/claude-home:/home/ubuntu/.claude
      - ${SECRETS_DIR}/claude-home.json:/home/ubuntu/.claude.json
      # Both paths are required — Claude Code splits session state
      # across ~/.claude/ (the actual credential) and the separate
      # sibling file ~/.claude.json (login/onboarding status, checked
      # first). Persisting only one still re-prompts for login.
      - ${SECRETS_DIR}/codex-home:/home/ubuntu/.codex
      # Codex login persists here ONLY because config.toml inside
      # this directory forces cli_auth_credentials_store = "file"
      # (seeded by this script) — the "auto" default routes the
      # credential to a store that dies with the container.
    # Balanced network: point at an egress-filtered proxy network
    # once one exists — network_mode left default for now
    stdin_open: true
    tty: true
EOF

create_file_if_missing "$INFRA/compose/docs.yaml" << 'EOF'
services:
  docs:
    build: ../docker/agent
    working_dir: /workspace
    volumes:
      - ${PROJECTS_DIR}/${PROJECT}:/workspace
      - ${VAULT_DIR}/agent_inbox:/vault/agent_inbox
      - ${VAULT_DIR}/programming:/vault/programming:ro
      - ${VAULT_DIR}/security:/vault/security:ro
      - ${VAULT_DIR}/research:/vault/research:ro
      - ${VAULT_DIR}/ideas:/vault/ideas:ro
      - ${VAULT_DIR}/projects:/vault/projects:ro
      - ${VAULT_DIR}/archive:/vault/archive:ro
      - ${AI_DIR}:/ai:ro
      - ${SECRETS_DIR}/claude-home:/home/ubuntu/.claude
      - ${SECRETS_DIR}/claude-home.json:/home/ubuntu/.claude.json
      - ${SECRETS_DIR}/codex-home:/home/ubuntu/.codex
    network_mode: "none"      # switch to Balanced only if the task needs it
    stdin_open: true
    tty: true
EOF

create_file_if_missing "$INFRA/compose/review.yaml" << 'EOF'
services:
  review:
    build: ../docker/agent
    working_dir: /workspace
    volumes:
      - ${PROJECTS_DIR}/${PROJECT}:/workspace:ro   # ← ro
      - ${VAULT_DIR}/agent_inbox:/vault/agent_inbox      # output
      - ${VAULT_DIR}/programming:/vault/programming:ro
      - ${VAULT_DIR}/security:/vault/security:ro
      - ${VAULT_DIR}/research:/vault/research:ro
      - ${VAULT_DIR}/ideas:/vault/ideas:ro
      - ${VAULT_DIR}/projects:/vault/projects:ro
      - ${VAULT_DIR}/archive:/vault/archive:ro
      - ${AI_DIR}:/ai:ro
      - ${SECRETS_DIR}/claude-home:/home/ubuntu/.claude
      - ${SECRETS_DIR}/claude-home.json:/home/ubuntu/.claude.json
      - ${SECRETS_DIR}/codex-home:/home/ubuntu/.codex
    network_mode: "none"                           # ← offline
    stdin_open: true
    tty: true
EOF

create_file_if_missing "$INFRA/compose/sandbox.yaml" << 'EOF'
services:
  sandbox:
    build: ../docker/agent
    working_dir: /workspace
    # Required for codex's workspace-write sandbox: bubblewrap needs
    # unprivileged user namespaces, which the default seccomp profile
    # blocks — full root-cause note in hermes_codex.yaml.
    security_opt:
      - seccomp=unconfined
    volumes:
      - ${PROJECTS_DIR}/sandbox:/workspace   # sandbox/ only
      - ${AI_DIR}:/ai:ro
      - ${SECRETS_DIR}/claude-home:/home/ubuntu/.claude
      - ${SECRETS_DIR}/claude-home.json:/home/ubuntu/.claude.json
      - ${SECRETS_DIR}/codex-home:/home/ubuntu/.codex
    # No vault mount at all in this profile
    stdin_open: true
    tty: true
EOF

# --- ollama.yaml / hermes.yaml — run and verified (see local_models.md)
# Smoke-tested for real: Ollama with GPU passthrough serving models,
# Hermes connected via the custom OpenAI endpoint, full conversation
# round-trips confirmed (gemma4:e2b, 100% GPU). Model requirements
# (>=64K context, tools + thinking capabilities) and every finding
# from the debugging are recorded in local_models.md — read it before
# picking a model; qwen3 does NOT work (40K context ceiling).

create_file_if_missing "$INFRA/compose/ollama.yaml" << 'EOF'
services:
  ollama:
    image: ollama/ollama
    volumes:
      - ${MODELS_DIR}/ollama:/root/.ollama
    environment:
      - OLLAMA_KEEP_ALIVE=-1        # avoid reload latency between agent turns
      - OLLAMA_CONTEXT_LENGTH=64000 # Hermes rejects models below 64K context
    ports:
      - "11434:11434"
    # GPU passthrough — verified working on WSL2 via Docker Desktop
    # (Windows NVIDIA driver is enough; no separate Container Toolkit
    # install was needed). Uncomment on a host with an NVIDIA GPU;
    # confirm with: docker compose ... exec ollama nvidia-smi
    # then check placement per model with: ollama ps  (PROCESSOR col).
    deploy:
       resources:
         reservations:
           devices:
             - driver: nvidia
               count: 1
               capabilities: [gpu]
EOF

create_file_if_missing "$INFRA/compose/hermes.yaml" << 'EOF'
services:
  hermes:
    image: nousresearch/hermes-agent
    working_dir: /vault/agent_inbox   # default cwd for delegated writes — see delegation_phrasing.md
    environment:
      # Hermes's own write allowlist (write_file/patch tools) —
      # default is /opt/data only, which blocks even the legitimate
      # inbox. Extend it or Hermes cannot write to the vault at all.
      # NOTE: the terminal tool bypasses this guard; the read-only
      # mounts below are what catch terminal-path writes.
      - HERMES_WRITE_SAFE_ROOT=/opt/data:/vault/agent_inbox
      # PUID/PGID — official Hermes env vars (LinuxServer.io-style
      # convention) remapping the internal hermes user (default UID
      # 10000) to match the host user, so files it writes are
      # directly openable without sudo — same reasoning as this
      # project's own agent Dockerfile using UID 1000. Set these to
      # match the actual host user (verify with `id -u`).
      # KNOWN UPSTREAM BUG (nousresearch/hermes-agent#35025): any
      # non-default PUID makes the boot hook re-chown every
      # Hermes-managed directory on EVERY start, not just the
      # first — with `run --rm` (fresh container each launch) this
      # means every single invocation pays that cost. Confirmed
      # working correctly despite the slower startup.
      - PUID=1000
      - PGID=1000
    volumes:
      - ${SECRETS_DIR}/hermes-home:/opt/data
      # Same per-subfolder vault pattern as every other profile —
      # personal/ never listed (see architecture.md, ADR 0010).
      # With PUID/PGID set above, files Hermes writes here are
      # owned by the host user directly — no chmod/sudo needed.
      # (If PUID/PGID are ever removed, tools revert to uid 10000
      # and `chmod o+w` becomes necessary again — see local_models.md.)
      - ${VAULT_DIR}/agent_inbox:/vault/agent_inbox
      - ${VAULT_DIR}/programming:/vault/programming:ro
      - ${VAULT_DIR}/security:/vault/security:ro
      - ${VAULT_DIR}/research:/vault/research:ro
      - ${VAULT_DIR}/ideas:/vault/ideas:ro
      - ${VAULT_DIR}/projects:/vault/projects:ro
      - ${VAULT_DIR}/archive:/vault/archive:ro
    stdin_open: true
    tty: true
    # depends_on deliberately removed — config.yaml's base_url can
    # point at this local ollama service OR a remote one (e.g. a
    # desktop GPU over the LAN), and a hard dependency here would
    # force starting a local Ollama container even when unused.
    # Include -f ollama.yaml in the run command ONLY when config.yaml
    # actually points at http://ollama:11434/v1 (the local service
    # name still resolves fine when both files are passed together).
    #   Local:   docker compose --env-file ../workspace.env \
    #              -f ollama.yaml -f hermes.yaml run --rm hermes
    #   Remote:  docker compose --env-file ../workspace.env \
    #              -f hermes.yaml run --rm hermes
    # Configure via: hermes setup (Full setup → Custom endpoint →
    # http://ollama:11434/v1, Chat Completions) — see local_models.md
    # for the full verified walkthrough and model requirements.
    # terminal.backend stays local, NOT docker — docker requires the
    # Docker socket mounted here, the exact risk parked in
    # features.md's Possible (Speculative) section.
EOF

create_file_if_missing "$INFRA/compose/hermes_dashboard.yaml" << 'EOF'
# Hermes web dashboard as a standing daemon — deliberately a
# SEPARATE profile from hermes.yaml: ephemeral chat and a
# persistent dashboard are different usage patterns. Both mount
# the same hermes-home, so config/memory/sessions are shared.
#
# AUTH IS MANDATORY (fail-closed): inside the container the
# dashboard must bind 0.0.0.0 for Docker's port forwarding to
# work, and its safety gate refuses non-loopback binds without an
# auth provider — it cannot see the host-side 127.0.0.1
# restriction. Before first use, set basic_auth in
# ~/.secrets/hermes-home/config.yaml — see local_models.md
# "Web Dashboard" for the hash-generation one-liner. Do NOT use
# the Nous OAuth option (adds a cloud login to the offline tier).
#
# Run: docker compose --env-file ../workspace.env \
#        -f ollama.yaml -f hermes_dashboard.yaml up -d
# Open: http://127.0.0.1:9119
services:
  hermes_dashboard:
    image: nousresearch/hermes-agent
    working_dir: /vault/agent_inbox   # default cwd for delegated writes — see delegation_phrasing.md
    command: gateway run
    environment:
      - HERMES_DASHBOARD=1
      - HERMES_WRITE_SAFE_ROOT=/opt/data:/vault/agent_inbox
      - PUID=1000
      - PGID=1000
    volumes:
      - ${SECRETS_DIR}/hermes-home:/opt/data
      - ${VAULT_DIR}/agent_inbox:/vault/agent_inbox
      - ${VAULT_DIR}/programming:/vault/programming:ro
      - ${VAULT_DIR}/security:/vault/security:ro
      - ${VAULT_DIR}/research:/vault/research:ro
      - ${VAULT_DIR}/ideas:/vault/ideas:ro
      - ${VAULT_DIR}/projects:/vault/projects:ro
      - ${VAULT_DIR}/archive:/vault/archive:ro
    ports:
      - "127.0.0.1:9119:9119"   # loopback ONLY — never expose to LAN
    restart: unless-stopped
    # depends_on deliberately removed — same reasoning as hermes.yaml:
    # config.yaml may point at this local Ollama or a remote one.
    # Include -f ollama.yaml only when actually using the local
    # service; the "ollama" hostname still resolves fine when both
    # files are passed together.
EOF

# --- hermes_claude — Hermes with Claude Code delegation ------------
# Run and verified (see local_models.md, "Claude Code Delegation via
# Hermes"). Named for the provider, matching the convention used for
# every future addition (hermes_codex.yaml, etc. — see
# hermes_operations.md section 8) — not "experimental," since this
# is a confirmed-working, permanent profile, not a testbed to be
# overwritten by whatever's tried next.

create_file_if_missing "$INFRA/docker/hermes_claude/Dockerfile" << 'EOF'
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
EOF

create_file_if_missing "$INFRA/compose/hermes_claude.yaml" << 'EOF'
services:
  hermes_claude:
    build:
      context: ../docker/hermes_claude
      dockerfile: Dockerfile
    working_dir: /vault/agent_inbox   # default cwd for delegated writes — see delegation_phrasing.md
    environment:
      - HERMES_WRITE_SAFE_ROOT=/opt/data:/vault/agent_inbox
      - PUID=1000
      - PGID=1000
    volumes:
      - ${SECRETS_DIR}/hermes-home:/opt/data
      # Reuses the exact Claude Code login already authenticated for
      # dev.yaml/docs.yaml/etc — no new auth. Mount destination
      # confirmed by asking Hermes to introspect itself (whoami ;
      # echo $HOME) — tool execution runs as uid=1000(hermes) with
      # $HOME=/opt/data/home, NOT /root. This path is nested inside
      # the already-mounted /opt/data; Docker handles nested bind
      # mounts fine — the more specific mount just takes precedence.
      - ${SECRETS_DIR}/claude-home:/opt/data/home/.claude
      - ${SECRETS_DIR}/claude-home.json:/opt/data/home/.claude.json
      - ${VAULT_DIR}/agent_inbox:/vault/agent_inbox
      - ${VAULT_DIR}/programming:/vault/programming:ro
      - ${VAULT_DIR}/security:/vault/security:ro
      - ${VAULT_DIR}/research:/vault/research:ro
      - ${VAULT_DIR}/ideas:/vault/ideas:ro
      - ${VAULT_DIR}/projects:/vault/projects:ro
      - ${VAULT_DIR}/archive:/vault/archive:ro
    stdin_open: true
    tty: true
    # depends_on deliberately removed — same reasoning as hermes.yaml:
    # config.yaml may point at this local Ollama or a remote one.
    # Include -f ollama.yaml only when actually using the local
    # service.
    # Delegate from inside a session:
    #   claude -p "task" --allowedTools Read,Edit --max-turns 10
    # Default model controlled via the SAME settings.json dev.yaml
    # uses (~/.secrets/claude-home/settings.json) — Claude Code
    # defaults to its most expensive model with no override; add
    # {"model": "sonnet"} to keep automated delegation off Opus by
    # default. Confirmed working — see local_models.md.
EOF

# --- hermes_dashboard_with_claude — combines both, VERIFIED --------
# Run and confirmed working (see local_models.md): a real
# `claude -p` delegation call returned a genuine response with no
# login prompt, through the persistent dashboard/remote-gateway
# backend. Only publishes 127.0.0.1:9119, same as hermes_dashboard.yaml
# — the two can't run simultaneously without remapping one's port.

create_file_if_missing "$INFRA/compose/hermes_dashboard_with_claude.yaml" << 'EOF'
# Hermes dashboard/desktop-app backend WITH Claude Code delegation
# available. Confirmed working — see local_models.md and
# hermes_operations.md. Same hermes-home and claude-home mounts as
# the other profiles. NOTE: conflicts with hermes_dashboard.yaml on
# port 9119 — only one of the two can run at a time unless remapped.
#
# AUTH IS MANDATORY (fail-closed) — see local_models.md "Web
# Dashboard". Do NOT use the Nous OAuth option.
#
# Run:  docker compose --env-file ../workspace.env \
#         -f ollama.yaml -f hermes_dashboard_with_claude.yaml up -d
# Open: http://127.0.0.1:9119, or the desktop app's Remote gateway.
services:
  hermes_dashboard_with_claude:
    build:
      context: ../docker/hermes_claude
      dockerfile: Dockerfile
    working_dir: /vault/agent_inbox   # default cwd for delegated writes — see delegation_phrasing.md
    command: gateway run
    environment:
      - HERMES_DASHBOARD=1
      - HERMES_WRITE_SAFE_ROOT=/opt/data:/vault/agent_inbox
      - PUID=1000
      - PGID=1000
    volumes:
      - ${SECRETS_DIR}/hermes-home:/opt/data
      - ${SECRETS_DIR}/claude-home:/opt/data/home/.claude
      - ${SECRETS_DIR}/claude-home.json:/opt/data/home/.claude.json
      - ${VAULT_DIR}/agent_inbox:/vault/agent_inbox
      - ${VAULT_DIR}/programming:/vault/programming:ro
      - ${VAULT_DIR}/security:/vault/security:ro
      - ${VAULT_DIR}/research:/vault/research:ro
      - ${VAULT_DIR}/ideas:/vault/ideas:ro
      - ${VAULT_DIR}/projects:/vault/projects:ro
      - ${VAULT_DIR}/archive:/vault/archive:ro
    ports:
      - "127.0.0.1:9119:9119"   # loopback ONLY — never expose to LAN
    restart: unless-stopped
    # depends_on deliberately removed — same reasoning as the other
    # profiles: config.yaml may point at this local Ollama or a
    # remote one (this exact scenario is what surfaced the issue —
    # confirmed running against the desktop's GPU with no local
    # Ollama needed). Include -f ollama.yaml only when actually
    # using the local service.
EOF

# --- hermes_codex — Hermes with Codex delegation --------------------
# Run and verified (see features.md "Supervisor agent" and
# local_models.md). Separate build context from hermes_claude —
# decided so the proven Claude image stays frozen; see
# hermes_operations.md section 8 for the full provider-naming
# convention.

create_file_if_missing "$INFRA/docker/hermes_codex/Dockerfile" << 'EOF'
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
EOF

create_file_if_missing "$INFRA/compose/hermes_codex.yaml" << 'EOF'
services:
  hermes_codex:
    build:
      context: ../docker/hermes_codex
      dockerfile: Dockerfile
    working_dir: /vault/agent_inbox   # default cwd for delegated writes — see delegation_phrasing.md
    # Codex's workspace-write sandbox is bubblewrap, which must create
    # an unprivileged USER NAMESPACE inside this container — and
    # docker-ce's default seccomp profile blocks that syscall
    # (root-caused on the laptop, docker-ce 29.7.2:
    # `unshare -U` fails "Operation not permitted" under the default
    # profile, succeeds under seccomp=unconfined; codex's own raw log
    # named the failing piece — "the local sandbox launcher is
    # unavailable" — and even its apply_patch fallback writes route
    # through the same launcher). Without this line, every
    # `codex exec --sandbox workspace-write` write fails while STILL
    # EXITING 0 — Hermes then truthfully relays a false success.
    # The stack's real boundaries (mount scoping,
    # HERMES_WRITE_SAFE_ROOT, non-root users, offline profiles) are
    # untouched; container seccomp was defense-in-depth that codex's
    # own nested sandbox is incompatible with. docs/review keep the
    # default profile deliberately (offline — codex can't run there).
    security_opt:
      - seccomp=unconfined
    environment:
      - HERMES_WRITE_SAFE_ROOT=/opt/data:/vault/agent_inbox
      - PUID=1000
      - PGID=1000
    volumes:
      - ${SECRETS_DIR}/hermes-home:/opt/data
      # Same codex-home mount dev.yaml uses — the existing,
      # already-authenticated ChatGPT-plan login (device-auth flow +
      # cli_auth_credentials_store = "file"), reused unchanged.
      # Destination CONFIRMED (not just inferred from the Claude
      # build): whoami/echo $HOME/id inside a live session returned
      # uid=1000(hermes), $HOME=/opt/data/home — identical to the
      # Claude container, same base image. `~/.codex/auth.json` was
      # also confirmed present and correctly populated
      # (auth_mode: chatgpt) through this mount.
      - ${SECRETS_DIR}/codex-home:/opt/data/home/.codex
      - ${VAULT_DIR}/agent_inbox:/vault/agent_inbox
      - ${VAULT_DIR}/programming:/vault/programming:ro
      - ${VAULT_DIR}/security:/vault/security:ro
      - ${VAULT_DIR}/research:/vault/research:ro
      - ${VAULT_DIR}/ideas:/vault/ideas:ro
      - ${VAULT_DIR}/projects:/vault/projects:ro
      - ${VAULT_DIR}/archive:/vault/archive:ro
    stdin_open: true
    tty: true
    # depends_on deliberately removed — config.yaml may point at
    # this local Ollama or a remote one. Include -f ollama.yaml only
    # when actually using the local service.
    #
    # Confirmed delegation recipe — three things this
    # profile's first real test surfaced, none of them the
    # anticipated bubblewrap uid-map error, which never appeared:
    #
    #   1. HERMES TERMINAL-TOOL QUIRK, not Codex-specific: a raw
    #      top-level `cmd1 && cmd2` through Hermes's terminal tool
    #      fails with exit 126. Wrap multi-command calls as a single
    #      string instead:
    #        bash -c "cmd1 && cmd2 && cmd3"
    #      This applies to ANY multi-command delegation through
    #      Hermes, not just Codex.
    #
    # 2. CODEX'S GIT-TRUST GATE, DECIDED codex exec
    #      refuses a directory it doesn't consider trusted with
    #      "Not inside a trusted directory and --skip-git-repo-check
    #      was not specified." STANDING PATTERN: pass
    #      --skip-git-repo-check on every call from this ephemeral
    #      profile — confirmed clean (agent-tier Stage A test), and
    #      cheaper than `git init`-per-call for a /tmp scratch dir
    #      that's destroyed anyway when the container exits.
    #
    #   3. pty=true is REQUIRED (confirmed, as anticipated) — the
    #      opposite of Claude's skill; getting it backwards hangs
    #      the call.
    #
    # Working example, combining all three:
    #   bash -c "mkdir -p /tmp/codex-test && cd /tmp/codex-test && \
    #     git init && codex exec 'task'"
    #   (run via the terminal tool with pty=true)
    #
    # Open follow-up: billing plan (ChatGPT plan vs API metering) not
    # yet explicitly confirmed via `codex /status` inside a session —
    # do that on the next real use.
EOF

create_file_if_missing "$INFRA/templates/AGENTS.md" << 'EOF'
# AGENTS.md

Default template — copy this into each new project as the starting
point, then fill in **Project-Specific Instructions** at the bottom.
`CLAUDE.md` should contain only "See AGENTS.md" or a symlink.

## Scope — Read This First

You operate **only within `/workspace`.** This is enforced by the
container's mount configuration, not just stated here.

- **`/workspace`** — read-write. This is your project. Work here.
- **`/vault`** — read-only. Reference material. Never attempt to
  write here directly.
- **`/vault/agent_inbox`** — the one exception, if mounted read-write
  for your profile: new files may go here. Nowhere else in the vault.
- **`/ai`** — read-only. Engineering standards. Read and follow;
  never modify.
- Anything outside these mounted paths does not exist for you.

If a task seems to need something outside `/workspace`, stop and say
so — that usually means a different container profile is needed, not
a workaround.

## Before You Start

If present, read in order: `/ai/me.md`, `/ai/workspace_map.md`,
`/vault/current_context.md`. Consult `/vault/skill_map.md` for
background knowledge. If any don't exist yet, proceed without them.

## Standards

Follow `/ai/coding-style.md`, `/ai/security-checklist.md`, and any
`/ai/<language>-guidelines.md` relevant to this project. Reference
them — don't duplicate their content here.

## Working Conventions

- Rebuild the image after Dockerfile changes; don't hand-patch a
  running container.
- Anything worth remembering beyond this session belongs in
  `/vault/agent_inbox` (if writable) as a note for human review.
- Match existing naming conventions (lowercase-with-hyphens).

## Project-Specific Instructions

<!-- Fill in per project: language/framework specifics, build/test/
     lint commands, directory structure, anything unusual. -->
EOF

# --- hermes_dashboard_with_codex — combines both, VERIFIED ---------
# Run and confirmed working — a real codex exec delegation
# through the persistent dashboard/gateway returned CODEX DASHBOARD
# OK with no login prompt. Third profile claiming port 9119.

create_file_if_missing "$INFRA/compose/hermes_dashboard_with_codex.yaml" << 'EOF'
# Hermes dashboard/desktop-app backend WITH Codex delegation
# available. CONFIRMED WORKING — a real delegation call
# through the persistent gateway returned CODEX DASHBOARD OK, no
# login prompt — same credential-persistence guarantee already
# proven for hermes_codex.yaml (ephemeral) and
# hermes_dashboard_with_claude.yaml. Same hermes-home and codex-home
# mounts as the other profiles.
#
# AUTH IS MANDATORY (fail-closed) — see local_models.md "Web
# Dashboard". Do NOT use the Nous OAuth option.
#
# Delegation recipe (confirmed, see local_models.md "Codex
# Delegation via Hermes"): codex exec (not -p), pty=true required,
# wrap multi-command chains in bash -c "..." (Hermes's terminal tool
# errors on a raw top-level && chain), and the target directory must
# be a git repo (git init first, or pass --skip-git-repo-check —
# which of the two is the standing pattern is still an open item).
#
# Run:  run.sh dashboard_codex
#   (or: docker compose --env-file ../workspace.env \
#          -f ollama.yaml -f hermes_dashboard_with_codex.yaml up -d)
# Open: http://127.0.0.1:9119, or the desktop app's Remote gateway.
#
# NOTE: conflicts with hermes_dashboard.yaml AND
# hermes_dashboard_with_claude.yaml on port 9119 — only one of the
# three can run at a time unless remapped.
services:
  hermes_dashboard_with_codex:
    build:
      context: ../docker/hermes_codex
      dockerfile: Dockerfile
    working_dir: /vault/agent_inbox   # default cwd for delegated writes — see delegation_phrasing.md
    # Required for codex's workspace-write sandbox: bubblewrap needs
    # unprivileged user namespaces, which the default seccomp profile
    # blocks — full root-cause note in hermes_codex.yaml.
    security_opt:
      - seccomp=unconfined
    command: gateway run
    environment:
      - HERMES_DASHBOARD=1
      - HERMES_WRITE_SAFE_ROOT=/opt/data:/vault/agent_inbox
      - PUID=1000
      - PGID=1000
    volumes:
      - ${SECRETS_DIR}/hermes-home:/opt/data
      - ${SECRETS_DIR}/codex-home:/opt/data/home/.codex
      - ${VAULT_DIR}/agent_inbox:/vault/agent_inbox
      - ${VAULT_DIR}/programming:/vault/programming:ro
      - ${VAULT_DIR}/security:/vault/security:ro
      - ${VAULT_DIR}/research:/vault/research:ro
      - ${VAULT_DIR}/ideas:/vault/ideas:ro
      - ${VAULT_DIR}/projects:/vault/projects:ro
      - ${VAULT_DIR}/archive:/vault/archive:ro
    ports:
      - "127.0.0.1:9119:9119"   # loopback ONLY — never expose to LAN
    restart: unless-stopped
    # depends_on deliberately removed — same reasoning as every other
    # profile: config.yaml may point at this local Ollama or a
    # remote one. Include -f ollama.yaml only when actually using
    # the local service.
EOF

# --- hermes_all — combined Claude Code + Codex image -----------------
# CONFIRMED WORKING — mechanical merge of two independently
# proven images (see features.md's original hermes_codex naming
# discussion for why the merge was deferred until then). Both the
# ephemeral and dashboard forms proven via interleaved delegation
# calls with no cross-provider interference — see features.md's
# Resolved entry and testing_plan.md §1.8/§1.8b.

create_file_if_missing "$INFRA/docker/hermes_all/Dockerfile" << 'EOF'
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
EOF

create_file_if_missing "$INFRA/compose/hermes_all.yaml" << 'EOF'
services:
  hermes_all:
    build:
      context: ../docker/hermes_all
      dockerfile: Dockerfile
    working_dir: /vault/agent_inbox   # default cwd for delegated writes — see delegation_phrasing.md
    # Required for codex's workspace-write sandbox: bubblewrap needs
    # unprivileged user namespaces, which the default seccomp profile
    # blocks — full root-cause note in hermes_codex.yaml.
    security_opt:
      - seccomp=unconfined
    environment:
      - HERMES_WRITE_SAFE_ROOT=/opt/data:/vault/agent_inbox
      - PUID=1000
      - PGID=1000
    volumes:
      - ${SECRETS_DIR}/hermes-home:/opt/data
      # Both credential sets, at their respectively-confirmed paths
      # (both proven identical: uid=1000(hermes), $HOME=/opt/data/home).
      - ${SECRETS_DIR}/claude-home:/opt/data/home/.claude
      - ${SECRETS_DIR}/claude-home.json:/opt/data/home/.claude.json
      - ${SECRETS_DIR}/codex-home:/opt/data/home/.codex
      - ${VAULT_DIR}/agent_inbox:/vault/agent_inbox
      - ${VAULT_DIR}/programming:/vault/programming:ro
      - ${VAULT_DIR}/security:/vault/security:ro
      - ${VAULT_DIR}/research:/vault/research:ro
      - ${VAULT_DIR}/ideas:/vault/ideas:ro
      - ${VAULT_DIR}/projects:/vault/projects:ro
      - ${VAULT_DIR}/archive:/vault/archive:ro
    stdin_open: true
    tty: true
    # depends_on deliberately removed — same reasoning as every other
    # profile: config.yaml may point at this local Ollama or a
    # remote one. Include -f ollama.yaml only when actually using
    # the local service.
    #
    # CONFIRMED WORKING — three interleaved delegation
    # calls in one continuous session (claude, codex, claude again)
    # all returned clean with no login prompt and no cross-provider
    # interference: "INTERLEAVE 1 OK" / "INTERLEAVE 2 OK" /
    # "INTERLEAVE 3 OK". Both credential mounts resolve identically
    # to their individually-proven paths. The one risk unique to the
    # combination — one provider's use disturbing the other's state —
    # did not materialize.
    #
    # Recipe: Use your terminal tool to run: claude -p "task"
    #         Use your terminal tool with pty=true to run: codex exec --skip-git-repo-check "task"
    #         (same phrasing rules as hermes_codex — bare commands
    #         get chatted back at, not executed)
EOF

create_file_if_missing "$INFRA/compose/hermes_dashboard_with_all.yaml" << 'EOF'
# Hermes dashboard/desktop-app backend WITH BOTH Claude Code and
# Codex delegation available. CONFIRMED WORKING — three
# interleaved delegation calls (claude, codex, claude again) through
# this standing gateway, reached remotely via the native Win11 app,
# all returned clean with no login prompt and no cross-provider
# interference. This closes the final open item from the entire
# supervisor-agent effort: both providers, both ephemeral and
# dashboard form, single and combined, all proven end to end.
#
# AUTH IS MANDATORY (fail-closed) — see local_models.md "Web
# Dashboard". Do NOT use the Nous OAuth option.
#
# NOTE: conflicts with hermes_dashboard.yaml,
# hermes_dashboard_with_claude.yaml, AND
# hermes_dashboard_with_codex.yaml on port 9119 — only one of the
# four can run at a time unless remapped.
#
# Delegation recipe (confirmed): interleave calls to prove no
# cross-provider interference, same pattern hermes_all was proven with:
#   claude -p "task"
#   codex exec --skip-git-repo-check "task"
#   claude -p "task"
# (same terminal-tool framing as the ephemeral profile — bare
# commands get chatted back at, not executed)
#
# Run:  run.sh dashboard_all
#   (or: docker compose --env-file ../workspace.env \
#          -f ollama.yaml -f hermes_dashboard_with_all.yaml up -d)
# Open: http://127.0.0.1:9119, or the desktop app's Remote gateway.
services:
  hermes_dashboard_with_all:
    build:
      context: ../docker/hermes_all
      dockerfile: Dockerfile
    working_dir: /vault/agent_inbox   # default cwd for delegated writes — see delegation_phrasing.md
    # Required for codex's workspace-write sandbox: bubblewrap needs
    # unprivileged user namespaces, which the default seccomp profile
    # blocks — full root-cause note in hermes_codex.yaml.
    security_opt:
      - seccomp=unconfined
    command: gateway run
    environment:
      - HERMES_DASHBOARD=1
      - HERMES_WRITE_SAFE_ROOT=/opt/data:/vault/agent_inbox
      - PUID=1000
      - PGID=1000
    volumes:
      - ${SECRETS_DIR}/hermes-home:/opt/data
      - ${SECRETS_DIR}/claude-home:/opt/data/home/.claude
      - ${SECRETS_DIR}/claude-home.json:/opt/data/home/.claude.json
      - ${SECRETS_DIR}/codex-home:/opt/data/home/.codex
      - ${VAULT_DIR}/agent_inbox:/vault/agent_inbox
      - ${VAULT_DIR}/programming:/vault/programming:ro
      - ${VAULT_DIR}/security:/vault/security:ro
      - ${VAULT_DIR}/research:/vault/research:ro
      - ${VAULT_DIR}/ideas:/vault/ideas:ro
      - ${VAULT_DIR}/projects:/vault/projects:ro
      - ${VAULT_DIR}/archive:/vault/archive:ro
    ports:
      - "127.0.0.1:9119:9119"   # loopback ONLY — never expose to LAN
    restart: unless-stopped
    # depends_on deliberately removed — config.yaml may point at
    # this local Ollama or a remote one. Include -f ollama.yaml only
    # when actually using the local service.
EOF

create_file_if_missing "$INFRA/compose/hermes_dashboard_project.yaml" << 'EOF'
# Project-mount override for hermes_dashboard.yaml, applied ONLY when
# run.sh is called with --project=<name>. Deliberately its own tiny
# file, not shared with the other three dashboard variants: each
# dashboard has exactly one service name, and a fragment listing all
# four would make compose treat the other three as new, incomplete
# standalone services (no image/build) that `up -d` would then also
# try to start. ${HERMES_PROJECT} must be a real exported env var —
# run.sh's --project=<name> parsing does this; it isn't in
# workspace.env, since it's a per-invocation choice, not a fixed
# setting.
services:
  hermes_dashboard:
    volumes:
      - ${PROJECTS_DIR}/${HERMES_PROJECT}:/workspace
    working_dir: /workspace
    # working_dir here is best-effort — Hermes's terminal tool has
    # been found NOT to reliably pick up the container's own default
    # workdir for delegated commands (same root cause as the
    # /opt/hermes cwd finding). The real fix is still passing
    # workdir=/workspace explicitly in the delegation instruction —
    # see delegation_phrasing.md.
EOF

create_file_if_missing "$INFRA/compose/hermes_dashboard_with_claude_project.yaml" << 'EOF'
# Project-mount override for hermes_dashboard_with_claude.yaml, applied ONLY when
# run.sh is called with --project=<name>. Deliberately its own tiny
# file, not shared with the other three dashboard variants: each
# dashboard has exactly one service name, and a fragment listing all
# four would make compose treat the other three as new, incomplete
# standalone services (no image/build) that `up -d` would then also
# try to start. ${HERMES_PROJECT} must be a real exported env var —
# run.sh's --project=<name> parsing does this; it isn't in
# workspace.env, since it's a per-invocation choice, not a fixed
# setting.
services:
  hermes_dashboard_with_claude:
    volumes:
      - ${PROJECTS_DIR}/${HERMES_PROJECT}:/workspace
    working_dir: /workspace
    # working_dir here is best-effort — Hermes's terminal tool has
    # been found NOT to reliably pick up the container's own default
    # workdir for delegated commands (same root cause as the
    # /opt/hermes cwd finding). The real fix is still passing
    # workdir=/workspace explicitly in the delegation instruction —
    # see delegation_phrasing.md.
EOF

create_file_if_missing "$INFRA/compose/hermes_dashboard_with_codex_project.yaml" << 'EOF'
# Project-mount override for hermes_dashboard_with_codex.yaml, applied ONLY when
# run.sh is called with --project=<name>. Deliberately its own tiny
# file, not shared with the other three dashboard variants: each
# dashboard has exactly one service name, and a fragment listing all
# four would make compose treat the other three as new, incomplete
# standalone services (no image/build) that `up -d` would then also
# try to start. ${HERMES_PROJECT} must be a real exported env var —
# run.sh's --project=<name> parsing does this; it isn't in
# workspace.env, since it's a per-invocation choice, not a fixed
# setting.
services:
  hermes_dashboard_with_codex:
    volumes:
      - ${PROJECTS_DIR}/${HERMES_PROJECT}:/workspace
    working_dir: /workspace
    # working_dir here is best-effort — Hermes's terminal tool has
    # been found NOT to reliably pick up the container's own default
    # workdir for delegated commands (same root cause as the
    # /opt/hermes cwd finding). The real fix is still passing
    # workdir=/workspace explicitly in the delegation instruction —
    # see delegation_phrasing.md.
EOF

create_file_if_missing "$INFRA/compose/hermes_dashboard_with_all_project.yaml" << 'EOF'
# Project-mount override for hermes_dashboard_with_all.yaml, applied ONLY when
# run.sh is called with --project=<name>. Deliberately its own tiny
# file, not shared with the other three dashboard variants: each
# dashboard has exactly one service name, and a fragment listing all
# four would make compose treat the other three as new, incomplete
# standalone services (no image/build) that `up -d` would then also
# try to start. ${HERMES_PROJECT} must be a real exported env var —
# run.sh's --project=<name> parsing does this; it isn't in
# workspace.env, since it's a per-invocation choice, not a fixed
# setting.
services:
  hermes_dashboard_with_all:
    volumes:
      - ${PROJECTS_DIR}/${HERMES_PROJECT}:/workspace
    working_dir: /workspace
    # working_dir here is best-effort — Hermes's terminal tool has
    # been found NOT to reliably pick up the container's own default
    # workdir for delegated commands (same root cause as the
    # /opt/hermes cwd finding). The real fix is still passing
    # workdir=/workspace explicitly in the delegation instruction —
    # see delegation_phrasing.md.
EOF


# --- run.sh — post-setup convenience runner --------------------------
# Confirmed working terminal invocation and one VS Code
# task both executed successfully against a real workspace. Single
# source of truth for every "how do I start X again?" command — both
# the terminal and tasks.json call this, so the compose invocations
# live in exactly one place. See testing_plan.md for what's been run.

create_file_if_missing "$INFRA/scripts/run.sh" << 'RUN_SH_EOF'
#!/usr/bin/env bash
#
# run.sh — post-setup convenience runner
#
# Lives at infrastructure/scripts/run.sh AFTER setup.sh has created
# the workspace — this script never creates anything, it only runs
# what already exists. Single source of truth for every "how do I
# start X again?" invocation: the terminal uses it directly, and
# .vscode/tasks.json calls it too, so the commands live in exactly
# one place.
#
# Usage:
#   run.sh                          interactive menu
#   run.sh <target> [project]      direct
#   run.sh dev myproject           e.g. dev container for a project
#
# Targets:
#   dev|docs|review <project>   core profiles (need a project name)
#   sandbox                     isolated scratch container
#   hermes                      ephemeral Hermes chat (Ollama tier)
#   hermes_claude               ephemeral Hermes + Claude Code delegation
#   hermes_codex                ephemeral Hermes + Codex delegation
#   hermes_all                  ephemeral Hermes + Claude Code + Codex
#   dashboard                   persistent dashboard, Ollama only
#   dashboard_claude            persistent dashboard + Claude Code
#   dashboard_codex             persistent dashboard + Codex
#   dashboard_all               persistent dashboard + Claude Code + Codex
#   models                       list models Ollama has pulled (starts
#                               the container if it isn't running)
#   pull [model]                pull a model into the local Ollama
#                               (default: gemma4:e2b if no name given)
#   ollama_down                  stop the local Ollama container
#   docker_clean                 free disk: containers/images picked
#                               PER ITEM from a numbered list (not a
#                               blanket per-category y/N — that once
#                               took ollama/ollama, a real re-pull,
#                               along with cheap-to-rebuild project
#                               images in one yes); build cache and
#                               networks stay category-level; no
#                               volumes exist in this project so none
#                               are at risk either way
#   dashboard_auth               generate/print a dashboard basic_auth
#                               config block (terminal only — password
#                               entry isn't masked in VS Code tasks)
#   down                        stop whatever dashboard is running
#   ps                          show running workspace containers
#   health                      run scripts/health_check.sh
#   drift                       run bootstrap/setup.sh --verify
#   docker_status               which Docker backend this distro's
#                               CLI points at (Desktop shim vs native
#                               docker-ce) + migration prerequisites
#   docker_migrate              move the stack to native docker-ce
#                               (reversible; needs sudo + network)
#   docker_revert               back to the Docker Desktop backend
#                               (stops the native service, uninstalls
#                               nothing — see migrate_docker_backend.sh)
#   bootstrap                   re-run bootstrap/setup.sh (idempotent —
#                               "exists, skipping" on a healthy tree)
#   test                        run the bats regression suite
#                               (bootstrap/setup.bats)
#   check_all                   health + drift + test in sequence —
#                               the local stand-in for CI; stops at
#                               the first failure
#
# Flags:
#   -r | --remote-ollama   don't include ollama.yaml (config.yaml
#                          points at a remote Ollama, e.g. a desktop
#                          GPU over the LAN). Default is to include
#                          it — matches the current local-GPU setup.
#   --project=<name>       mount a real project (read-write, at
#                          /workspace) into ANY Hermes chat or
#                          dashboard profile — hermes, hermes_claude,
#                          hermes_codex, hermes_all, dashboard,
#                          dashboard_claude, dashboard_codex,
#                          dashboard_all. Delegation calls still need
#                          workdir=/workspace explicitly (Hermes's
#                          terminal tool doesn't reliably pick up the
#                          container's own default workdir) — see
#                          delegation_phrasing.md.
#                          e.g. run.sh --project=hydrogen-sky hermes_all
#                               run.sh --project=hydrogen-sky dashboard_all

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA="$(dirname "$SCRIPT_DIR")"
COMPOSE_DIR="$INFRA/compose"
ENV_FILE="../workspace.env"          # relative to COMPOSE_DIR, as documented
SECRETS_DIR="$HOME/.secrets"
PROJECTS_DIR="$(dirname "$INFRA")/projects"

[ -d "$COMPOSE_DIR" ] || { echo "compose/ not found at $COMPOSE_DIR — run setup.sh first."; exit 1; }

WITH_OLLAMA=1
HERMES_PROJECT=""
ARGS=()
for a in "$@"; do
  case "$a" in
    -r|--remote-ollama) WITH_OLLAMA=0 ;;
    --project=*) export HERMES_PROJECT="${a#--project=}" ;;
    -h|--help) sed -n '2,76p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) ARGS+=("$a") ;;
  esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

TARGET="${1:-}"
PROJECT_ARG="${2:-}"

if [ -n "$HERMES_PROJECT" ] && [ ! -d "$PROJECTS_DIR/$HERMES_PROJECT" ]; then
  echo "No such project dir: $PROJECTS_DIR/$HERMES_PROJECT"
  echo "Available projects:"
  ls -1 "$PROJECTS_DIR" 2>/dev/null | sed 's/^/  /' || true
  exit 1
fi

compose() {
  # Always run from compose/, always with the manifest — the two
  # things everyone forgets when typing by hand.
  ( cd "$COMPOSE_DIR" && docker compose --env-file "$ENV_FILE" "$@" )
}

ensure_ollama() {
  # `docker compose run` starts ONLY the named service plus its
  # depends_on — and depends_on was deliberately REMOVED from every
  # Hermes profile (remote-Ollama support). So in local mode the
  # ollama service must be brought up explicitly first, or Hermes
  # launches with no backend (ctx --). Finding #2 test
  # run. Idempotent: if ollama is already up, this is a no-op.
  # Dashboards don't need the "start ollama" half — `up -d` on
  # merged files starts all services anyway — but DO still need
  # ensure_model below, called separately after their own `up -d`.
  if [ "$WITH_OLLAMA" = "1" ]; then
    compose -f ollama.yaml up -d ollama
    ensure_model
  fi
}

ensure_model() {
  # Added so "pick a profile, it just works" is actually
  # true end to end — no separate `run.sh pull` step needed first.
  # LOCAL MODE ONLY: the desktop's own models are a different
  # machine's concern, managed independently (already confirmed
  # populated — see local_models.md); nothing to pull there from
  # here. `ollama pull` on an already-current model is a fast local
  # layer check, not a re-download, so this is cheap even when the
  # model's already present. Best-effort: a pull failure here
  # shouldn't block the actual launch, which will surface its own
  # clearer error if something's genuinely wrong.
  if [ "$WITH_OLLAMA" = "1" ]; then
    compose -f ollama.yaml exec -T ollama ollama pull gemma4:e2b >/dev/null 2>&1 || true
  fi
}

ollama_flag() {
  # Hermes profiles pair with ollama.yaml so the "ollama" hostname
  # resolves — unless config.yaml points at a remote instance.
  if [ "$WITH_OLLAMA" = "1" ]; then echo "-f ollama.yaml"; else echo ""; fi
}

project_mount_args() {
  # Mounts a project into a Hermes profile at runtime via `docker
  # compose run`'s own -v/-w flags — deliberately NOT a compose YAML
  # fragment. hermes/hermes_claude/hermes_codex/hermes_all are four
  # DIFFERENTLY-NAMED services (that's how the profile matrix keeps
  # them separate), so a single fragment file can't merge a volume
  # into whichever one happens to be running. `run`'s own -v/-w
  # apply to whatever service name is actually invoked, no matter
  # which — so no new file is needed for this. Read-write, fixed
  # path (/workspace, matching dev.yaml's own convention) regardless
  # of project name, so delegation phrasing never has to change.
  [ -n "$HERMES_PROJECT" ] || return 0
  echo "-v ${PROJECTS_DIR}/${HERMES_PROJECT}:/workspace -w /workspace"
}

dashboard_project_flag() {
  # The dashboard equivalent of project_mount_args() — but dashboards
  # use `up -d`, which doesn't take run-time -v/-w overrides the way
  # `run` does, so this genuinely needs a compose fragment. UNLIKE
  # the ephemeral profiles, each dashboard variant has exactly ONE
  # service name per file — so a fragment CAN target it directly.
  # One fragment per dashboard, not one shared file: a shared file
  # listing all four dashboard service names would make compose
  # treat the OTHER three (not actually being launched) as new,
  # incomplete standalone services with no image/build — `up -d`
  # would then try to start those broken phantoms too. $1 is the
  # base service/file name, e.g. hermes_dashboard_with_all.
  [ -n "$HERMES_PROJECT" ] || { echo ""; return; }
  echo "-f ${1}_project.yaml"
}

need_project() {
  # dev/docs/review are parameterized by ${PROJECT}. Validate BEFORE
  # docker runs, with real error messages instead of compose's
  # variable-interpolation noise.
  local for_target="$1"
  if [ -z "$PROJECT_ARG" ]; then
    echo "Available projects:"
    ls -1 "$PROJECTS_DIR" 2>/dev/null | sed 's/^/  /' || true
    read -r -p "Project name for '$for_target': " PROJECT_ARG
  fi
  [ -n "$PROJECT_ARG" ] || { echo "No project given."; exit 1; }
  [ -d "$PROJECTS_DIR/$PROJECT_ARG" ] \
    || { echo "No such project dir: $PROJECTS_DIR/$PROJECT_ARG"; exit 1; }
  if [ "$for_target" = "dev" ] && [ ! -f "$SECRETS_DIR/$PROJECT_ARG.env" ]; then
    echo "dev.yaml declares env_file \$SECRETS_DIR/$PROJECT_ARG.env and it doesn't exist."
    echo "Create it first (empty is fine):  touch $SECRETS_DIR/$PROJECT_ARG.env"
    exit 1
  fi
  export PROJECT="$PROJECT_ARG"
}

port_9119_owner() {
  docker ps --filter "publish=9119" --format '{{.Names}}' 2>/dev/null | head -1
}

guard_9119() {
  # hermes_dashboard.yaml and hermes_dashboard-with-*.yaml all claim
  # 127.0.0.1:9119 — only one can run. Detect and offer the swap
  # instead of letting docker fail with a bind error.
  local wanted="$1" owner; owner="$(port_9119_owner)"
  if [ -n "$owner" ] && [ "$owner" != "$wanted" ]; then
    echo "Port 9119 is held by: $owner"
    read -r -p "Stop it and start $wanted instead? [y/N] " yn
    case "$yn" in
      y|Y) docker stop "$owner" >/dev/null && echo "  stopped $owner" ;;
      *) echo "Leaving $owner running. Aborted."; exit 1 ;;
    esac
  fi
}

run_target() {
  if [ -n "$HERMES_PROJECT" ]; then
    case "$1" in
      hermes|hermes_claude|hermes_codex|hermes_all) : ;;             # supported (-v/-w)
      dashboard|dashboard_claude|dashboard_codex|dashboard_all) : ;; # supported (compose fragment)
      *)
        echo "--project=$HERMES_PROJECT has no effect on '$1' — only"
        echo "the Hermes chat/dashboard profiles support a project mount:"
        echo "hermes, hermes_claude, hermes_codex, hermes_all,"
        echo "dashboard, dashboard_claude, dashboard_codex, dashboard_all."
        exit 1
        ;;
    esac
  fi
  case "$1" in
    dev|docs|review)
      need_project "$1"
      compose -f "$1.yaml" run --rm "$1"
      ;;
    sandbox)
      compose -f sandbox.yaml run --rm sandbox
      ;;
    hermes)
      ensure_ollama
      # shellcheck disable=SC2046
      compose $(ollama_flag) -f hermes.yaml run --rm $(project_mount_args) hermes
      ;;
    hermes_claude)
      ensure_ollama
      # shellcheck disable=SC2046
      compose $(ollama_flag) -f hermes_claude.yaml run --rm $(project_mount_args) hermes_claude
      ;;
    hermes_codex)
      # Confirmed working (features.md, "Supervisor
      # agent"). Two things to remember when delegating from inside
      # the session: (1) codex exec, not -p, and pty=true is
      # required; (2) wrap multi-command shell calls in
      # bash -c "cmd1 && cmd2" — Hermes's terminal tool errors
      # (exit 126) on a raw top-level && chain, unrelated to Codex.
      ensure_ollama
      # shellcheck disable=SC2046
      compose $(ollama_flag) -f hermes_codex.yaml run --rm $(project_mount_args) hermes_codex
      ;;
    hermes_all)
      # Confirmed working three interleaved delegation
      # calls in one continuous session (claude, codex, claude again)
      # all returned clean with no login prompt and no cross-provider
      # interference — the one risk individual per-provider testing
      # couldn't have caught.
      ensure_ollama
      # shellcheck disable=SC2046
      compose $(ollama_flag) -f hermes_all.yaml run --rm $(project_mount_args) hermes_all
      ;;
    dashboard)
      guard_9119 "compose-hermes_dashboard-1"
      # shellcheck disable=SC2046
      compose $(ollama_flag) -f hermes_dashboard.yaml $(dashboard_project_flag hermes_dashboard) up -d
      ensure_model
      echo "Dashboard: http://127.0.0.1:9119"
      ;;
    dashboard_claude)
      guard_9119 "compose-hermes_dashboard_with_claude-1"
      # shellcheck disable=SC2046
      compose $(ollama_flag) -f hermes_dashboard_with_claude.yaml $(dashboard_project_flag hermes_dashboard_with_claude) up -d
      ensure_model
      echo "Dashboard (with Claude Code delegation): http://127.0.0.1:9119"
      ;;
    dashboard_codex)
      # Confirmed working real delegation through the
      # persistent gateway returned CODEX DASHBOARD OK, no login
      # prompt. Same delegation recipe as hermes_codex (codex exec,
      # pty=true, bash -c wrapping for && chains — see that target's
      # comments above).
      guard_9119 "compose-hermes_dashboard_with_codex-1"
      # shellcheck disable=SC2046
      compose $(ollama_flag) -f hermes_dashboard_with_codex.yaml $(dashboard_project_flag hermes_dashboard_with_codex) up -d
      ensure_model
      echo "Dashboard (with Codex delegation): http://127.0.0.1:9119"
      ;;
    dashboard_all)
      # Confirmed working three interleaved delegation
      # calls (claude, codex, claude again) through the persistent
      # gateway, reached remotely via the native Win11 app, all
      # returned clean with no login prompt and no cross-provider
      # interference. Both halves of the supervisor-agent idea —
      # ephemeral and dashboard, single-provider and combined — are
      # now proven end to end.
      guard_9119 "compose-hermes_dashboard_with_all-1"
      # shellcheck disable=SC2046
      compose $(ollama_flag) -f hermes_dashboard_with_all.yaml $(dashboard_project_flag hermes_dashboard_with_all) up -d
      ensure_model
      echo "Dashboard (with Claude Code + Codex delegation): http://127.0.0.1:9119"
      ;;
    down)
      local owner; owner="$(port_9119_owner)"
      if [ -n "$owner" ]; then
        docker stop "$owner" >/dev/null && echo "stopped: $owner"
      else
        echo "No dashboard holding port 9119."
      fi
      ;;
    ollama_down)
      if docker ps --format '{{.Names}}' | grep -qx compose-ollama-1; then
        docker stop compose-ollama-1 >/dev/null && echo "stopped: compose-ollama-1"
      else
        echo "Ollama isn't running."
      fi
      ;;
    docker_clean)
      # Destructive — confirmation required PER ITEM for containers
      # and images (not just per-category): a category-wide "remove
      # unused images? [y/N]" once took ollama/ollama — a 6GB image
      # that re-pulls from the registry rather than rebuilding from
      # cache — along with the project's own small, cheap images in
      # the same yes, with no way to keep one and drop the rest.
      # Build cache and networks stay category-level: build cache
      # has no per-item concept (opaque layers, not named things a
      # user would recognize), and networks already gets an
      # automatic safety net below instead of manual selection.
      # Nothing here touches volumes — this project uses only bind
      # mounts,
      # confirmed zero Docker volumes throughout, so there's nothing
      # volume-related to offer either way. Rebuilding this project's
      # images afterward is a normal --no-cache rebuild, not a
      # disaster recovery — same as setting up on a fresh machine.
      # Matches the manual cleanup sequence already proven to work
      # well: container/image/builder/network prune, run separately
      # rather than one opaque `system prune -a` so each step's
      # effect is visible AND individually skippable.
      echo "Current Docker disk usage:"
      docker system df
      echo
      did_something=0

      # Per-item selection (not per-category), for containers and
      # images: a category-wide "remove unused images? [y/N]" once
      # took ollama/ollama (a 6GB re-pull, not a cheap rebuild)
      # along with the project's own small, cheap-to-rebuild images
      # in the same yes — there was no way to keep one and drop the
      # rest. Numbered list + pick which ones; blank/Enter skips the
      # whole category, exactly like before.

      echo "== Stopped containers =="
      mapfile -t dc_c_list < <(docker ps -a --filter status=exited --filter status=created \
        --format '{{.Names}}|{{.Image}}|{{.Size}}')
      if [ "${#dc_c_list[@]}" -eq 0 ]; then
        echo "  (none — nothing to remove)"
      else
        i=1
        for entry in "${dc_c_list[@]}"; do
          name="${entry%%|*}"; rest="${entry#*|}"; img="${rest%%|*}"; sz="${rest##*|}"
          printf "  %2d) %-30s %-35s %s\n" "$i" "$name" "$img" "$sz"
          i=$((i + 1))
        done
        read -r -p "Remove which? (numbers, 'all', or blank to skip): " dc_c_sel
        dc_c_sel="${dc_c_sel//,/ }"
        if [ "$dc_c_sel" = "all" ]; then
          docker container prune -f; did_something=1
        elif [ -n "$dc_c_sel" ]; then
          for n in $dc_c_sel; do
            idx=$((n - 1))
            if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#dc_c_list[@]}" ]; then
              name="${dc_c_list[$idx]%%|*}"
              docker rm "$name" | sed 's/^/    removed: /'
              did_something=1
            else
              echo "  skipped invalid selection: $n"
            fi
          done
        else
          echo "  skipped: containers"
        fi
      fi
      echo

      echo "== Unused images =="
      echo "  (only images NOT backing any container, running or"
      echo "   stopped — this project's own hermes/agent/sandbox builds"
      echo "   included if none of their containers currently exist;"
      echo "   they rebuild on next launch from cached layers, just"
      echo "   slower. ollama/ollama does NOT rebuild from cache the"
      echo "   same way — removing it means a real multi-GB re-pull.)"
      mapfile -t dc_used_ids < <(docker ps -aq | xargs -r docker inspect --format '{{.Image}}' 2>/dev/null | sort -u)
      mapfile -t dc_img_list < <(docker images --format '{{.ID}}|{{.Repository}}:{{.Tag}}|{{.Size}}')
      dc_unused=()
      for entry in "${dc_img_list[@]}"; do
        id="${entry%%|*}"
        used=0
        for u in "${dc_used_ids[@]}"; do
          [ "$id" = "$u" ] && used=1 && break
        done
        [ "$used" -eq 0 ] && dc_unused+=("$entry")
      done
      if [ "${#dc_unused[@]}" -eq 0 ]; then
        echo "  (none — nothing to remove)"
      else
        i=1
        for entry in "${dc_unused[@]}"; do
          rest="${entry#*|}"; name="${rest%%|*}"; sz="${rest##*|}"
          printf "  %2d) %-45s %s\n" "$i" "$name" "$sz"
          i=$((i + 1))
        done
        read -r -p "Remove which? (numbers, 'all', or blank to skip): " dc_i_sel
        dc_i_sel="${dc_i_sel//,/ }"
        if [ "$dc_i_sel" = "all" ]; then
          for entry in "${dc_unused[@]}"; do
            rest="${entry#*|}"; name="${rest%%|*}"
            docker rmi "$name" | sed 's/^/    removed: /'
          done
          did_something=1
        elif [ -n "$dc_i_sel" ]; then
          for n in $dc_i_sel; do
            idx=$((n - 1))
            if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#dc_unused[@]}" ]; then
              rest="${dc_unused[$idx]#*|}"; name="${rest%%|*}"
              docker rmi "$name" | sed 's/^/    removed: /'
              did_something=1
            else
              echo "  skipped invalid selection: $n"
            fi
          done
        else
          echo "  skipped: images"
        fi
      fi
      echo

      echo "== Build cache =="
      docker system df | grep -E "TYPE|Build Cache"
      echo "  (frees the most space; next build of anything starts from"
      echo "   scratch — no cached layers left to reuse)"
      read -r -p "Remove ALL build cache? [y/N] " dc_builder
      case "$dc_builder" in
        y|Y) docker builder prune -a -f; did_something=1 ;;
        *) echo "  skipped: build cache" ;;
      esac
      echo

      echo "== Unused networks =="
      # Footgun fix: network prune only spares networks with a
      # RUNNING container attached — a stopped/orphaned compose-*
      # container left pointing at a network still gets that network
      # deleted out from under it, and the next `up` fails with
      # "failed to set up container networking: network ... not
      # found" (hit for real). Since every container here is
      # disposable (all state lives in bind mounts), the safe fix is
      # to clear stale compose-* containers FIRST, not to skip the
      # network prune.
      stale_compose=$(docker ps -aq --filter name=compose- --filter status=exited)
      if [ -n "$stale_compose" ]; then
        echo "  Found stopped compose-* container(s) that could be"
        echo "  stranded by a network prune — removing them first"
        echo "  (safe: no data lives in containers, only bind mounts):"
        docker rm -f $stale_compose | sed 's/^/    removed: /'
      fi
      net_list=$(docker network ls --filter dangling=true --format '  {{.Name}} ({{.Driver}})')
      if [ -z "$net_list" ]; then
        echo "  (none — nothing to remove)"
      else
        echo "$net_list"
        read -r -p "Remove these? [y/N] " dc_networks
        case "$dc_networks" in
          y|Y) docker network prune -f; did_something=1 ;;
          *) echo "  skipped: networks" ;;
        esac
      fi
      echo
      if [ "$did_something" -eq 1 ]; then
        echo "Docker disk usage after cleanup:"
        docker system df
        echo
        echo "That frees space INSIDE Docker's WSL2 allocation only."
        echo "To reclaim it on the Windows side too, from an admin"
        echo "PowerShell:"
        echo "  wsl --shutdown"
        echo "  Optimize-VHD -Path <path-to-docker-desktop-data.vhdx> -Mode Full"
        echo "(or Docker Desktop -> Settings -> Resources -> Clean / Purge data)"
      else
        echo "Nothing selected — nothing removed."
      fi
      ;;
    dashboard_auth)
      # Confirmed necessary any dashboard profile refuses
      # to bind (Hermes's OWN internal auth gate, independent of
      # Docker's 127.0.0.1-only port mapping) until basic_auth is
      # configured in hermes-home/config.yaml — this doesn't survive
      # a hermes-home wipe (--secrets-only or a manual rm), so it
      # needs redoing after one. Prints the config block rather than
      # editing config.yaml directly — safer than blindly patching
      # hand-maintained YAML (risk of duplicate keys / clobbering an
      # existing block).
      local da_user da_pass da_hash
      read -r -p "Dashboard username: " da_user
      read -r -s -p "Dashboard password: " da_pass; echo
      [ -n "$da_user" ] && [ -n "$da_pass" ] || { echo "Both required."; exit 1; }
      # Password goes through an env var into the container, not
      # spliced into the python source string — avoids shell/python
      # quoting issues if the password contains quotes, $, etc.
      da_hash="$(compose -f hermes.yaml run --rm -e DA_PASS="$da_pass" hermes         python -c "import os; from plugins.dashboard_auth.basic import hash_password; print(hash_password(os.environ['DA_PASS']))"         2>/dev/null | tail -1)"
      if [ -z "$da_hash" ]; then
        echo "Hash generation failed — is the hermes image built? (run.sh hermes once first)"
        exit 1
      fi
      echo
      echo "Add this to ~/.secrets/hermes-home/config.yaml (create the"
      echo "dashboard: block if none exists yet; merge by hand if one does):"
      echo
      echo "  dashboard:"
      echo "    basic_auth:"
      echo "      username: $da_user"
      echo "      password_hash: \"$da_hash\""
      echo
      echo "Then restart whichever dashboard container is running so it"
      echo "re-reads config.yaml fresh, e.g.:"
      echo "  docker restart compose-hermes_dashboard-1"
      echo "  (or _with_claude-1 / _with_codex-1 / _with_all-1 — whichever's up)"
      ;;
    models)
      # Independent of any Hermes profile — just needs the ollama
      # service itself. up -d is a no-op if it's already running.
      compose -f ollama.yaml up -d ollama >/dev/null
      docker exec compose-ollama-1 ollama list
      ;;
    pull)
      local model="${PROJECT_ARG:-gemma4:e2b}"
      compose -f ollama.yaml up -d ollama >/dev/null
      echo "Pulling $model ..."
      docker exec compose-ollama-1 ollama pull "$model"
      ;;
    ps)
      docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
      ;;
    health)
      bash "$INFRA/scripts/health_check.sh"
      ;;
    drift)
      [ -f "$INFRA/bootstrap/setup.sh" ] \
        || { echo "setup.sh not found at $INFRA/bootstrap/ — run drift check from wherever it lives."; exit 1; }
      bash "$INFRA/bootstrap/setup.sh" --verify
      ;;
    docker_status)
      bash "$INFRA/scripts/migrate_docker_backend.sh" --check
      ;;
    docker_migrate)
      # Gated in features.md until the current test pass is finished.
      bash "$INFRA/scripts/migrate_docker_backend.sh" --migrate
      ;;
    docker_revert)
      bash "$INFRA/scripts/migrate_docker_backend.sh" --revert
      ;;
    bootstrap)
      # Safe as a one-click task BECAUSE setup.sh is idempotent —
      # on a healthy tree this is a wall of "exists, skipping".
      [ -f "$INFRA/bootstrap/setup.sh" ] \
        || { echo "setup.sh not found at $INFRA/bootstrap/."; exit 1; }
      bash "$INFRA/bootstrap/setup.sh"
      ;;
    test)
      [ -f "$INFRA/bootstrap/setup.bats" ] \
        || { echo "setup.bats not found at $INFRA/bootstrap/."; exit 1; }
      command -v bats >/dev/null 2>&1 \
        || { echo "bats not installed — sudo apt install bats (see setup.bats header)."; exit 1; }
      ( cd "$INFRA/bootstrap" && bats setup.bats )
      ;;
    check_all)
      # The full local confidence sweep, one click: does the live
      # tree look right (health), does it match what's embedded
      # (drift), does the script logic still hold (test). set -e
      # stops the chain at the first failure.
      run_target health
      run_target drift
      run_target test
      echo
      echo "== check_all: health + drift + test all passed =="
      ;;
    *)
      echo "Unknown target: $1 (see run.sh --help)"; exit 1 ;;
  esac
}

if [ -n "$TARGET" ]; then
  run_target "$TARGET"
  exit 0
fi

echo "What do you want to run? (Ctrl-C to quit)"
PS3="> "
select choice in \
  "hermes           — ephemeral chat, Ollama tier" \
  "hermes_claude    — ephemeral chat + Claude Code delegation" \
  "hermes_codex     — ephemeral chat + Codex delegation" \
  "hermes_all       — ephemeral chat + Claude Code + Codex" \
  "dashboard        — persistent dashboard, Ollama only" \
  "dashboard_claude — persistent dashboard + Claude Code" \
  "dashboard_codex  — persistent dashboard + Codex" \
  "dashboard_all    — persistent dashboard + Claude Code + Codex" \
  "dev              — dev container for a project" \
  "docs / review / sandbox" \
  "dashboard_auth   — generate a dashboard password (run from a terminal)" \
  "down             — stop the running dashboard" \
  "ollama_down      — stop the local Ollama container" \
  "models           — list pulled Ollama models" \
  "pull             — pull an Ollama model (default gemma4:e2b)" \
  "docker_clean     — free disk (prune containers/images/cache/networks)" \
  "ps / health / drift" \
  "docker backend      — status / migrate / revert (Desktop <-> native)" \
  "bootstrap / test / check_all — setup.sh, bats suite, or all checks" \
  "hermes/dashboard with a project mounted (--project=<name>)"; do
  case "$REPLY" in
    1) run_target hermes; break ;;
    2) run_target hermes_claude; break ;;
    3) run_target hermes_codex; break ;;
    4) run_target hermes_all; break ;;
    5) run_target dashboard; break ;;
    6) run_target dashboard_claude; break ;;
    7) run_target dashboard_codex; break ;;
    8) run_target dashboard_all; break ;;
    9) run_target dev; break ;;
    10) read -r -p "which (docs/review/sandbox): " t; run_target "$t"; break ;;
    11) run_target dashboard_auth; break ;;
    12) run_target down; break ;;
    13) run_target ollama_down; break ;;
    14) run_target models; break ;;
    15) read -r -p "model to pull (blank = gemma4:e2b): " m; PROJECT_ARG="$m" run_target pull; break ;;
    16) run_target docker_clean; break ;;
    17) read -r -p "which (ps/health/drift): " t; run_target "$t"; break ;;
    18) read -r -p "which (docker_status/docker_migrate/docker_revert): " t; run_target "$t"; break ;;
    19) read -r -p "which (bootstrap/test/check_all): " t; run_target "$t"; break ;;
    20)
      read -r -p "project name (blank = none): " p
      if [ -n "$p" ]; then
        if [ ! -d "$PROJECTS_DIR/$p" ]; then
          echo "No such project dir: $PROJECTS_DIR/$p"
          echo "Available projects:"
          ls -1 "$PROJECTS_DIR" 2>/dev/null | sed 's/^/  /' || true
          break
        fi
        export HERMES_PROJECT="$p"
      fi
      read -r -p "which (hermes/hermes_claude/hermes_codex/hermes_all/dashboard/dashboard_claude/dashboard_codex/dashboard_all): " t
      run_target "$t"
      break
      ;;
    *) echo "1-20 please" ;;
  esac
done
RUN_SH_EOF
if [ "$MODE" = "bootstrap" ]; then
  chmod +x "$INFRA/scripts/run.sh"
fi

create_file_if_missing "$INFRA/scripts/health_check.sh" << 'EOF'
#!/usr/bin/env bash
# health_check.sh — verify the bootstrap actually produced everything
# it was supposed to. Runs every check regardless of earlier failures
# and reports a full summary, rather than stopping at the first miss.

set -uo pipefail  # deliberately not -e: every check should still run

source "$(dirname "$0")/../workspace.env"

PASS=0
FAIL=0

check() {
  local desc="$1" cond="$2"
  if eval "$cond"; then
    echo "  OK    $desc"
    PASS=$((PASS+1))
  else
    echo "  FAIL  $desc"
    FAIL=$((FAIL+1))
  fi
}

echo "== Core tools =="
check "Docker Engine reachable" "docker info >/dev/null 2>&1"
check "Docker Compose v2"        "docker compose version >/dev/null 2>&1"
check "Git installed"            "git --version >/dev/null 2>&1"

echo "== Workspace directories =="
for d in "$PROJECTS_DIR" "$VAULT_DIR" "$AI_DIR" "$MODELS_DIR" \
         "$BACKUPS_DIR" "$ARCHIVES_DIR" "$INFRA_DIR"; do
  check "$d" "[ -d '$d' ]"
done
check "ai/ is a symlink into infrastructure/ai (version-controlled, not orphaned)" "[ -L '$AI_DIR' ]"

echo "== Vault structure =="
for sub in agent_inbox programming security research ideas projects personal archive; do
  check "vault/$sub" "[ -d '$VAULT_DIR/$sub' ]"
done
for sub in reports research sessions; do
  check "vault/agent_inbox/$sub (agent output subfolder)" "[ -d '$VAULT_DIR/agent_inbox/$sub' ]"
done

echo "== Infrastructure files =="
check "workspace.env"           "[ -f '$INFRA_DIR/workspace.env' ]"
check "docker/agent/Dockerfile" "[ -f '$INFRA_DIR/docker/agent/Dockerfile' ]"
check "compose/dev.yaml"        "[ -f '$INFRA_DIR/compose/dev.yaml' ]"
check "compose/docs.yaml"       "[ -f '$INFRA_DIR/compose/docs.yaml' ]"
check "compose/review.yaml"     "[ -f '$INFRA_DIR/compose/review.yaml' ]"
check "compose/sandbox.yaml"    "[ -f '$INFRA_DIR/compose/sandbox.yaml' ]"
check "compose/hermes.yaml"     "[ -f '$INFRA_DIR/compose/hermes.yaml' ]"
check "compose/hermes_claude.yaml" "[ -f '$INFRA_DIR/compose/hermes_claude.yaml' ]"
check "docker/hermes_claude/Dockerfile" "[ -f '$INFRA_DIR/docker/hermes_claude/Dockerfile' ]"
check "compose/hermes_dashboard.yaml" "[ -f '$INFRA_DIR/compose/hermes_dashboard.yaml' ]"
check "compose/hermes_dashboard_with_claude.yaml" "[ -f '$INFRA_DIR/compose/hermes_dashboard_with_claude.yaml' ]"
check "compose/hermes_codex.yaml"       "[ -f '$INFRA_DIR/compose/hermes_codex.yaml' ]"
check "compose/hermes_dashboard_with_codex.yaml" "[ -f '$INFRA_DIR/compose/hermes_dashboard_with_codex.yaml' ]"
check "compose/hermes_all.yaml" "[ -f '$INFRA_DIR/compose/hermes_all.yaml' ]"
check "docker/hermes_all/Dockerfile" "[ -f '$INFRA_DIR/docker/hermes_all/Dockerfile' ]"
check "compose/hermes_dashboard_with_all.yaml" "[ -f '$INFRA_DIR/compose/hermes_dashboard_with_all.yaml' ]"
check "compose/hermes_dashboard_project.yaml" "[ -f '$INFRA_DIR/compose/hermes_dashboard_project.yaml' ]"
check "compose/hermes_dashboard_with_claude_project.yaml" "[ -f '$INFRA_DIR/compose/hermes_dashboard_with_claude_project.yaml' ]"
check "compose/hermes_dashboard_with_codex_project.yaml" "[ -f '$INFRA_DIR/compose/hermes_dashboard_with_codex_project.yaml' ]"
check "compose/hermes_dashboard_with_all_project.yaml" "[ -f '$INFRA_DIR/compose/hermes_dashboard_with_all_project.yaml' ]"
check "docker/hermes_codex/Dockerfile"  "[ -f '$INFRA_DIR/docker/hermes_codex/Dockerfile' ]"
check "scripts/run.sh (executable)"     "[ -x '$INFRA_DIR/scripts/run.sh' ]"
check "scripts/migrate_docker_backend.sh (executable)" "[ -x '$INFRA_DIR/scripts/migrate_docker_backend.sh' ]"
check "templates/AGENTS.md"     "[ -f '$INFRA_DIR/templates/AGENTS.md' ]"

check ".vscode/tasks.json"     "[ -f '$WORKSPACE_ROOT/.vscode/tasks.json' ]"

echo "== Orientation layer scaffolds (Appendix B) =="
check "ai/me.md"                 "[ -f '$AI_DIR/me.md' ]"
check "ai/workspace_map.md"      "[ -f '$AI_DIR/workspace_map.md' ]"
check "vault/skill_map.md"       "[ -f '$VAULT_DIR/skill_map.md' ]"
check "vault/current_context.md" "[ -f '$VAULT_DIR/current_context.md' ]"

echo "== Git repositories =="
check "vault is a git repo"          "git -C '$VAULT_DIR' rev-parse --is-inside-work-tree >/dev/null 2>&1"
check "vault has a commit"           "git -C '$VAULT_DIR' log -1 >/dev/null 2>&1"
check "agent_inbox has its own nested git repo" "git -C '$VAULT_DIR/agent_inbox' rev-parse --is-inside-work-tree >/dev/null 2>&1"
check "hermes-home has a seeded git identity (agent_inbox commits need one)" \
  "[ -f '$SECRETS_DIR/hermes-home/home/.gitconfig' ] && grep -q 'email' '$SECRETS_DIR/hermes-home/home/.gitconfig'"

echo "== Codex sandbox prerequisite (root cause) =="
# codex exec --sandbox workspace-write = bubblewrap = user namespaces,
# blocked by docker-ce's default seccomp profile. Every codex-capable
# compose file must carry the seccomp=unconfined override; the offline
# profiles (docs, review) deliberately must NOT.
for f in dev sandbox hermes_codex hermes_all hermes_dashboard_with_codex hermes_dashboard_with_all; do
  check "compose/$f.yaml allows user namespaces (codex bwrap)" \
    "grep -q 'seccomp=unconfined' '$INFRA_DIR/compose/$f.yaml'"
done
for f in docs review; do
  check "compose/$f.yaml keeps default seccomp (offline profile)" \
    "! grep -q 'seccomp=unconfined' '$INFRA_DIR/compose/$f.yaml'"
done
check "infrastructure is a git repo" "git -C '$INFRA_DIR' rev-parse --is-inside-work-tree >/dev/null 2>&1"
check "infrastructure has a commit"  "git -C '$INFRA_DIR' log -1 >/dev/null 2>&1"

echo "== Security invariants =="
check "~/.secrets exists" "[ -d '$SECRETS_DIR' ]"

secrets_mode=$(stat -c %a "$SECRETS_DIR" 2>/dev/null || echo "??")
if [ "$secrets_mode" = "700" ]; then
  echo "  OK    ~/.secrets is mode 700"; PASS=$((PASS+1))
else
  echo "  FAIL  ~/.secrets is mode $secrets_mode, expected 700"; FAIL=$((FAIL+1))
fi

extra_files=$(find "$VAULT_DIR/personal" -type f ! -name '.gitkeep' 2>/dev/null | wc -l)
if [ "$extra_files" -eq 0 ]; then
  echo "  OK    vault/personal has no extra files"; PASS=$((PASS+1))
else
  echo "  FAIL  vault/personal has $extra_files unexpected file(s)"; FAIL=$((FAIL+1))
fi

echo
echo "== Summary: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
EOF
if [ "$MODE" = "bootstrap" ]; then
  chmod +x "$INFRA/scripts/health_check.sh"
fi

create_file_if_missing "$INFRA/scripts/migrate_docker_backend.sh" << 'MIGRATE_SH_EOF'
#!/usr/bin/env bash
#
# migrate_docker_backend.sh — move the stack between Docker Desktop's
# WSL backend and native docker-ce inside this Ubuntu distro.
#
# Why this exists: fewer standing apps on the laptop. Docker Desktop
# stays INSTALLED (needed for non-stack use) — this only changes
# which daemon this distro's `docker` talks to. The switch is
# deliberately reversible: nothing in the stack depends on docker-ce
# specifics (compose files, run.sh, tasks.json are daemon-agnostic),
# and --revert uninstalls nothing.
#
# Usage (or via run.sh docker_status / docker_migrate / docker_revert):
#   migrate_docker_backend.sh [--check]    read-only status (default)
#   migrate_docker_backend.sh --migrate    install/enable native docker-ce
#   migrate_docker_backend.sh --revert     back to the Docker Desktop shim
#
# What this script CANNOT do (honest limits, decided in advance):
#   - Flip Docker Desktop's "WSL integration" toggle — that's a
#     Windows GUI setting (Settings → Resources → WSL integration).
#     The script detects it and tells you, but you flip it.
#   - Purge the stack's images from Desktop's side — with integration
#     off, Desktop's daemon isn't reachable from this distro at all.
#     Do it in Desktop's own UI, and only after the native path has
#     survived real day-to-day use for a while (features.md entry).

set -uo pipefail   # not -e: --check must report everything, not stop

# ── Detection helpers (PATH-based, so bats can mock them) ─────────

docker_cli_path() {
  local p
  p="$(command -v docker 2>/dev/null || true)"
  [ -n "$p" ] || { echo ""; return; }
  readlink -f "$p" 2>/dev/null || echo "$p"
}

docker_flavor() {
  # "desktop"  — CLI resolves into Docker Desktop's injected tooling
  # "native"   — a real binary in the distro (docker-ce)
  # "none"     — no docker CLI on PATH at all
  local p; p="$(docker_cli_path)"
  [ -n "$p" ] || { echo "none"; return; }
  case "$p" in
    */docker-desktop/*|*/mnt/wsl/*) echo "desktop" ;;
    # Windows PATH interop leakage: no docker IN the distro, but
    # WSL's appended Windows PATH exposes Desktop's Windows-side CLI
    # under /mnt/<drive>/ (found on a virgin distro —
    # running it just prints Desktop's "activate WSL integration"
    # stub). Not a real backend; treat as "nothing installed here."
    */mnt/[a-z]/*) echo "windows-interop" ;;
    *) echo "native" ;;
  esac
}

have_pkg() { dpkg -s "$1" >/dev/null 2>&1; }

yn() { local a; read -r -p "$1 [y/N] " a; case "$a" in y|Y) return 0;; *) return 1;; esac; }

# ── --check ───────────────────────────────────────────────────────

do_check() {
  local p flavor
  p="$(docker_cli_path)"; flavor="$(docker_flavor)"

  echo "== Docker backend status =="
  case "$flavor" in
    desktop) echo "  Docker CLI: $p  (Docker Desktop shim)" ;;
    native)  echo "  Docker CLI: $p  (native docker-ce)" ;;
    windows-interop)
      echo "  Docker CLI: $p"
      echo "              (Desktop's WINDOWS CLI via interop PATH —"
      echo "               no docker is installed in this distro)" ;;
    none)    echo "  Docker CLI: not on PATH" ;;
  esac
  # The CLI path alone can lie in the hybrid state: --revert keeps
  # docker-ce installed, so /usr/bin/docker stays on PATH even when
  # Desktop's proxy is the one serving /var/run/docker.sock. Ask the
  # daemon itself who it is (best-effort; needs a reachable daemon).
  if [ "$flavor" != "none" ] && [ "$flavor" != "windows-interop" ]; then
    local dsays; dsays="$(docker info --format '{{.OperatingSystem}}' 2>/dev/null || true)"
    if [ -n "$dsays" ]; then
      echo "  Daemon:     $dsays"
    else
      echo "  Daemon:     not reachable (nothing serving the socket)"
    fi
  fi

  echo "== Migration prerequisites =="
  if [ -d /run/systemd/system ]; then
    echo "  OK    systemd is running in this distro"
  else
    echo "  MISS  systemd not running — needs [boot] systemd=true in /etc/wsl.conf + wsl --shutdown"
  fi
  if grep -qs "systemd[[:space:]]*=[[:space:]]*true" /etc/wsl.conf 2>/dev/null; then
    echo "  OK    /etc/wsl.conf enables systemd"
  else
    echo "  MISS  /etc/wsl.conf does not set systemd=true"
  fi
  for pkg in docker-ce docker-compose-plugin nvidia-container-toolkit; do
    if have_pkg "$pkg"; then echo "  OK    $pkg installed"
    else echo "  MISS  $pkg not installed"; fi
  done
  if command -v systemctl >/dev/null 2>&1; then
    # is-active prints its state AND exits non-zero for anything but
    # "active" — capture with || true so the fallback doesn't double-print
    local svc; svc="$(systemctl is-active docker 2>/dev/null || true)"
    echo "  ....  native docker service: ${svc:-unknown}"
  fi
  local me; me="${USER:-$(id -un)}"
  if id -nG 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
    echo "  OK    $me is in the docker group"
  else
    echo "  MISS  $me not in the docker group (needs re-login after usermod)"
  fi

  echo
  case "$flavor" in
    desktop)
      echo "Currently on the DESKTOP backend. To migrate: flip the WSL"
      echo "integration toggle OFF for this distro first, then --migrate."
      ;;
    native)  echo "Currently on the NATIVE backend. --revert switches back." ;;
    windows-interop)
      echo "No docker inside this distro — only Windows interop leakage."
      echo "Run --migrate to install native docker-ce (it will shadow"
      echo "the Windows CLI on PATH)."
      ;;
    none)
      echo "No docker CLI found — either enable Desktop's WSL integration"
      echo "or run --migrate to install native docker-ce."
      ;;
  esac
}

# ── --migrate ─────────────────────────────────────────────────────

do_migrate() {
  local flavor; flavor="$(docker_flavor)"

  if [ "$flavor" = "windows-interop" ]; then
    echo "NOTE: only Desktop's Windows CLI leaks through the interop"
    echo "PATH — no docker in this distro. Proceeding with the native"
    echo "install; /usr/bin/docker will shadow the leak afterward."
  fi
  if [ "$flavor" = "desktop" ]; then
    echo "REFUSING: docker still resolves to the Docker Desktop shim:"
    echo "  $(docker_cli_path)"
    echo
    echo "Flip the toggle first (Windows side, GUI only — no script can):"
    echo "  Docker Desktop → Settings → Resources → WSL integration"
    echo "  → turn OFF for this distro → Apply & Restart"
    echo "Then open a NEW terminal and re-run: run.sh docker_migrate"
    return 1
  fi

  if [ ! -d /run/systemd/system ]; then
    echo "REFUSING: systemd isn't running in this distro."
    echo "Add to /etc/wsl.conf:"
    echo "  [boot]"
    echo "  systemd=true"
    echo "Then from Windows PowerShell:  wsl --shutdown"
    echo "Reopen the distro and re-run: run.sh docker_migrate"
    return 1
  fi

  # Idempotent install — each step skips if already satisfied, so
  # re-running after a partial failure is safe (same philosophy as
  # setup.sh's "exists, skipping").
  if ! have_pkg docker-ce; then
    echo "== Installing docker-ce (official apt repo) =="
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin
  else
    echo "  exists, skipping: docker-ce"
  fi

  if ! have_pkg nvidia-container-toolkit; then
    # REQUIRED with native docker-ce: the "no Container Toolkit
    # needed" note in ollama.yaml was true only via Docker Desktop,
    # which bundles the GPU runtime.
    echo "== Installing nvidia-container-toolkit =="
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
      | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -sL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
      | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
      | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
    sudo apt-get update
    sudo apt-get install -y nvidia-container-toolkit
    sudo nvidia-ctk runtime configure --runtime=docker
  else
    echo "  exists, skipping: nvidia-container-toolkit"
  fi

  echo "== Enabling the native docker service =="
  # a prior --revert masks the unit so WSL restarts can't resurrect
  # it — unmask before enabling or both commands fail
  sudo systemctl unmask docker docker.socket 2>/dev/null || true
  # enable + RESTART, not `enable --now`: the apt install already
  # started dockerd, and --now is a no-op on a running service — so
  # the daemon would never re-read the daemon.json nvidia-ctk just
  # wrote, and GPU containers fail with "could not select device
  # driver nvidia" (hit for real on first migration).
  sudo systemctl enable docker
  sudo systemctl restart docker

  if ! id -nG | tr ' ' '\n' | grep -qx docker; then
    local me; me="${USER:-$(id -un)}"
    sudo usermod -aG docker "$me"
    echo "  Added $me to the docker group — takes effect on next"
    echo "  login (or: newgrp docker for this shell only)."
  fi

  echo
  echo "== Verifying with the stack's own tooling =="
  local SCRIPT_DIR; SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  bash "$SCRIPT_DIR/run.sh" health || true
  bash "$SCRIPT_DIR/run.sh" drift  || true

  echo
  echo "== Done. Next steps (manual, in order) =="
  echo "  1. Confirm: which docker  → /usr/bin/docker, NOT /mnt/wsl/..."
  echo "  2. bats setup.bats — full regression"
  echo "  3. run.sh hermes_claude — one real delegation proves the"
  echo "     credential mounts (images rebuild on first use; models"
  echo "     under \${MODELS_DIR} survive, no re-download)"
  echo "  4. Turn OFF Docker Desktop's autostart (Settings → General)"
  echo "  5. Do NOT purge Desktop's stack copies yet — only after the"
  echo "     native path survives real day-to-day use (features.md)."
  echo "     Purging happens in Desktop's own UI; it's unreachable"
  echo "     from here with integration off."
}

# ── --revert ──────────────────────────────────────────────────────

do_revert() {
  # Reversible switch, never a burned bridge: stop/disable the
  # native service so Desktop's shim wins the PATH again. Nothing
  # is uninstalled — docker-ce stays for the next --migrate.
  echo "== Reverting to the Docker Desktop backend =="
  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl disable --now docker docker.socket 2>/dev/null || true
    # MASK, not just disable — Desktop's "Apply & Restart" bounces
    # the whole WSL distro, and a merely-disabled unit came back
    # enabled+active through that cycle on real hardware
    #. Masking survives boots; migrate unmasks.
    sudo systemctl mask docker docker.socket 2>/dev/null || true
    # Report ACTUAL state, never assert success — the first version
    # printed "stopped and disabled" unconditionally with stderr
    # suppressed, which hid exactly this failure.
    local en ac
    en="$(systemctl is-enabled docker 2>/dev/null || true)"
    ac="$(systemctl is-active docker 2>/dev/null || true)"
    echo "  native docker service now: ${ac:-unknown} / ${en:-unknown} (still installed)"
    case "$en" in
      masked) : ;;
      *) echo "  WARNING: expected 'masked' — check manually before relying on the revert" ;;
    esac
  fi
  echo
  echo "Now flip the toggle back (Windows side, GUI only):"
  echo "  Docker Desktop → Settings → Resources → WSL integration"
  echo "  → turn ON for this distro → Apply & Restart"
  echo "Then open a NEW terminal and confirm:"
  echo "  which docker   → should resolve into the Desktop shim again"
  echo "The same compose files rebuild under Desktop unchanged — all"
  echo "state lives in the same bind mounts either way."
}

# ── Entry ─────────────────────────────────────────────────────────

case "${1:---check}" in
  --check)   do_check ;;
  --migrate) do_migrate ;;
  --revert)  do_revert ;;
  *) echo "Usage: $(basename "$0") [--check|--migrate|--revert]"; exit 1 ;;
esac
MIGRATE_SH_EOF
if [ "$MODE" = "bootstrap" ]; then
  chmod +x "$INFRA/scripts/migrate_docker_backend.sh"
fi

if [ "$MODE" = "bootstrap" ] && [ ! -d "$INFRA/.git" ]; then
  (cd "$INFRA" && git init -q)
fi
# .gitignore sits OUTSIDE the git-init guard (it used to be inside)
# so --verify can check it too. Bootstrap behavior is unchanged —
# create_file_if_missing is still skip-if-exists — except that a repo
# which somehow lost its .gitignore now gets it back, which is
# strictly an improvement.
# --- .vscode/tasks.json — thin wrappers over run.sh -----------------
# Confirmed working VS Code's task picker (Ctrl+Shift+P ->
# "Tasks: Run Task") listed all entries and one task executed
# correctly. Lives at the WORKSPACE root, not inside infrastructure/
# — VS Code reads .vscode/ from whatever folder is opened, and the
# intended opened folder is ~/workspace itself.

create_file_if_missing "$WORKSPACE_ROOT/.vscode/tasks.json" << 'TASKS_JSON_EOF'
{
  // ~/workspace/.vscode/tasks.json — thin wrappers over
  // infrastructure/scripts/run.sh. NO compose logic lives here on
  // purpose: run.sh is the single source of truth (it validates
  // PROJECT, handles the ollama.yaml pairing, guards the port 9119
  // dashboard conflict, and — added — auto-pulls the
  // local model via ensure_model so picking a task is genuinely
  // "just works," no separate pull step first). If a command needs
  // changing, change run.sh — every task here inherits the fix.
  //
  // Run any of these: Ctrl+Shift+P -> "Tasks: Run Task"
  "version": "2.0.0",
  "options": {
    "cwd": "${workspaceFolder}"
  },
  "presentation": {
    "reveal": "always",
    "focus": true,
    "panel": "dedicated"
  },
  "tasks": [
    {
      "label": "Hermes: chat (Ollama tier)",
      "type": "shell",
      "command": "infrastructure/scripts/run.sh hermes",
      "problemMatcher": []
    },
    {
      "label": "Hermes: chat + Claude Code delegation",
      "type": "shell",
      "command": "infrastructure/scripts/run.sh hermes_claude",
      "problemMatcher": []
    },
    {
      "label": "Hermes: chat + Codex delegation",
      "type": "shell",
      "command": "infrastructure/scripts/run.sh hermes_codex",
      "problemMatcher": []
    },
    {
      "label": "Hermes: chat + Claude Code + Codex — Local",
      "type": "shell",
      "command": "infrastructure/scripts/run.sh hermes_all",
      "problemMatcher": []
    },
    {
      "label": "Hermes: chat + Claude Code + Codex — Remote Desktop",
      "type": "shell",
      "command": "infrastructure/scripts/run.sh --remote-ollama hermes_all",
      "problemMatcher": []
    },
    {
      "label": "Dashboard: up (Ollama only)",
      "type": "shell",
      "command": "infrastructure/scripts/run.sh dashboard",
      "problemMatcher": []
    },
    {
      "label": "Dashboard: up (with Claude Code)",
      "type": "shell",
      "command": "infrastructure/scripts/run.sh dashboard_claude",
      "problemMatcher": []
    },
    {
      "label": "Dashboard: up (with Codex)",
      "type": "shell",
      "command": "infrastructure/scripts/run.sh dashboard_codex",
      "problemMatcher": []
    },
    {
      "label": "Dashboard: up (Claude Code + Codex) — Local",
      "type": "shell",
      "command": "infrastructure/scripts/run.sh dashboard_all",
      "problemMatcher": []
    },
    {
      "label": "Dashboard: up (Claude Code + Codex) — Remote Desktop",
      "type": "shell",
      "command": "infrastructure/scripts/run.sh --remote-ollama dashboard_all",
      "problemMatcher": []
    },
    {
      "label": "Dashboard: down",
      "type": "shell",
      "command": "infrastructure/scripts/run.sh down",
      "problemMatcher": []
    },
    {
      "label": "Ollama: stop (local container)",
      "type": "shell",
      "command": "infrastructure/scripts/run.sh ollama_down",
      "problemMatcher": []
    },
    {
      "label": "Docker: clean up (free disk — asks per category)",
      "type": "shell",
      "command": "infrastructure/scripts/run.sh docker_clean",
      "problemMatcher": []
    },
    {
      "label": "Dev container (pick project)",
      "type": "shell",
      "command": "infrastructure/scripts/run.sh dev ${input:project}",
      "problemMatcher": []
    },
    {
      "label": "Docs container (pick project, offline)",
      "type": "shell",
      "command": "infrastructure/scripts/run.sh docs ${input:project}",
      "problemMatcher": []
    },
    {
      "label": "Review container (pick project, read-only, offline)",
      "type": "shell",
      "command": "infrastructure/scripts/run.sh review ${input:project}",
      "problemMatcher": []
    },
    {
      "label": "Sandbox container",
      "type": "shell",
      "command": "infrastructure/scripts/run.sh sandbox",
      "problemMatcher": []
    },
    {
      "label": "Ollama: list pulled models",
      "type": "shell",
      "command": "infrastructure/scripts/run.sh models",
      "problemMatcher": []
    },
    {
      "label": "Ollama: pull a model",
      "type": "shell",
      "command": "infrastructure/scripts/run.sh pull ${input:model}",
      "problemMatcher": []
    },
    {
      "label": "Workspace: health check",
      "type": "shell",
      "command": "infrastructure/scripts/run.sh health",
      "problemMatcher": []
    },
    {
      "label": "Workspace: drift check (setup.sh --verify)",
      "type": "shell",
      "command": "infrastructure/scripts/run.sh drift",
      "problemMatcher": []
    },
    {
      "label": "Workspace: bootstrap (setup.sh — idempotent, safe to re-run)",
      "type": "shell",
      "command": "infrastructure/scripts/run.sh bootstrap",
      "problemMatcher": []
    },
    {
      "label": "Workspace: test suite (bats setup.bats)",
      "type": "shell",
      "command": "infrastructure/scripts/run.sh test",
      "problemMatcher": []
    },
    {
      "label": "Workspace: check all (health + drift + test)",
      "type": "shell",
      "command": "infrastructure/scripts/run.sh check_all",
      "problemMatcher": []
    },
    {
      "label": "Docker backend: status (Desktop shim vs native docker-ce)",
      "type": "shell",
      "command": "infrastructure/scripts/run.sh docker_status",
      "problemMatcher": []
    },
    {
      "label": "Docker backend: migrate to native docker-ce (sudo, reversible)",
      "type": "shell",
      "command": "infrastructure/scripts/run.sh docker_migrate",
      "problemMatcher": []
    },
    {
      "label": "Docker backend: revert to Docker Desktop (uninstalls nothing)",
      "type": "shell",
      "command": "infrastructure/scripts/run.sh docker_revert",
      "problemMatcher": []
    },
    {
      "label": "Runner: any target, any endpoint (pick both)",
      "type": "shell",
      "command": "infrastructure/scripts/run.sh ${input:ollamaEndpoint} ${input:target}",
      "problemMatcher": []
    }
  ],
  "inputs": [
    {
      "id": "project",
      "type": "promptString",
      "description": "Project name (a folder under ~/workspace/projects/)"
    },
    {
      "id": "model",
      "type": "promptString",
      "description": "Model to pull (blank = gemma4:e2b)",
      "default": ""
    },
    {
      "id": "ollamaEndpoint",
      "type": "pickString",
      "description": "Which Ollama should drive this?",
      "options": [
        {
          "label": "Local (this machine's Ollama container)",
          "value": ""
        },
        {
          "label": "Remote Desktop (the desktop's Ollama over the LAN)",
          "value": "--remote-ollama"
        }
      ],
      "default": ""
    },
    {
      "id": "target",
      "type": "pickString",
      "description": "run.sh target",
      "options": [
        "hermes",
        "hermes_claude",
        "hermes_codex",
        "hermes_all",
        "dashboard",
        "dashboard_claude",
        "dashboard_codex",
        "dashboard_all",
        "dev",
        "docs",
        "review",
        "sandbox",
        "models",
        "pull",
        "down",
        "ps",
        "health",
        "drift",
        "docker_status",
        "bootstrap",
        "test",
        "check_all"
      ]
    }
  ]
}
TASKS_JSON_EOF

create_file_if_missing "$INFRA/.gitignore" << 'EOF'
*.env
!workspace.env
EOF
git_commit_if_changes "$INFRA" "Infrastructure repo: bootstrap"

if [ "$MODE" = "bootstrap" ]; then
log "Validating compose profiles (syntax only — PROJECT unset at bootstrap time)"
for f in dev docs review sandbox; do
  if docker compose -f "$INFRA/compose/$f.yaml" config >/dev/null 2>&1; then
    echo "  $f.yaml: syntax OK"
  else
    echo "  $f.yaml: could not fully resolve (expected — \${PROJECT} isn't set until first real use)"
  fi
done
fi  # MODE=bootstrap (compose validation)

# ── Phase 3 — Vault ───────────────────────────────────────────────
log "Phase 3: Vault"

if [ "$MODE" = "bootstrap" ] && [ ! -d "$VAULT/.git" ]; then
  (cd "$VAULT" && git init -q)
fi
# Outside the git-init guard for the same --verify reason as the
# infrastructure .gitignore above.
create_file_if_missing "$VAULT/.gitignore" << 'EOF'
.obsidian/workspace*.json
agent_inbox/
EOF
if [ "$MODE" = "bootstrap" ]; then
for d in agent_inbox programming security research ideas projects personal archive \
         agent_inbox/reports agent_inbox/research agent_inbox/sessions; do
  touch "$VAULT/$d/.gitkeep"
done
# agent_inbox gets its own nested git repo — codex exec's trust
# check (finding) wants.git directly in the invoked
# directory, not satisfied by the vault's own repo one level up.
# Bare init, no commit needed — confirmed sufficient in testing.
# Deliberately excluded from the vault's own git tracking above
# (a nested .git would otherwise show up there as a confusing
# "gitlink" entry rather than real tracked content).
if [ ! -d "$VAULT/agent_inbox/.git" ]; then
  (cd "$VAULT/agent_inbox" && git init -q)
fi
fi
git_commit_if_changes "$VAULT" "Vault: bootstrap structure"

echo "  NOTE: personal/ is scaffolded but this script will never write"
echo "  content into it — that folder is human-only by design."

# ── Phase 5 — Orientation layer scaffolds (Appendix B) ───────────
log "Phase 5: Orientation layer scaffolds (content is yours to fill in)"

create_scaffold_if_missing "$AI/me.md" << 'EOF'
# Me

<!-- Engineering brief: goals, preferred languages/tools, coding
     philosophy, communication preferences. Mounted into every
     container — keep it professional, not personal. -->
EOF

create_scaffold_if_missing "$AI/workspace_map.md" << 'EOF'
# Workspace Map

<!-- For each top-level directory: purpose, what an agent may touch,
     typical contents. One page, hard limit. -->
EOF

create_scaffold_if_missing "$VAULT/skill_map.md" << 'EOF'
# Skill Map

<!-- One line per domain, linking to detailed vault notes.
     e.g. Docker → programming/docker-notes.md -->
EOF

create_scaffold_if_missing "$VAULT/current_context.md" << 'EOF'
Priority this week:
Active project:
Blocked by:
Avoid touching:
Notes:
EOF

# ai/ content is a symlink into infrastructure/ai/ (see Phase 1), so
# it commits there — it was never its own repo.
git_commit_if_changes "$INFRA" "AI policies: orientation scaffolds"
git_commit_if_changes "$VAULT" "Vault: orientation scaffolds"

# ── Verify-mode summary (end of the road for --verify) ────────────
if [ "$MODE" = "verify" ]; then
  echo
  echo "== Verify: $VERIFY_TOTAL embedded files checked, $VERIFY_DRIFT drifted or missing =="
  if [ "$VERIFY_DRIFT" -ne 0 ]; then
    echo "   Reconcile each file in ONE direction, then re-run --verify:"
    echo "   - keep the live edit  -> back-port it into this script's heredoc"
    echo "   - keep the embedded   -> delete the live file, re-run setup.sh"
    exit 1
  fi
  exit 0
fi

# ── Phase 6 — Verify ──────────────────────────────────────────────
log "Phase 6: Verify"
bash "$INFRA/scripts/health_check.sh"

# ── Summary ────────────────────────────────────────────────────────
cat << 'EOF'

=====================================================================
Done. What this script did NOT do — by design, see architecture.md:

  - Install Obsidian (Phase 4). Run this yourself:
      deb_link=$(curl -s https://obsidian.md/download | grep -o \
        'https://github[^0-9]*/v[0-9]\.[0-9]\.[0-9]/obsidian_[0-9]\.[0-9]\.[0-9]_amd64.deb')
      wget "$deb_link" -O /tmp/obsidian.deb && sudo apt install /tmp/obsidian.deb
    Then open ~/workspace/vault from inside WSL (WSLg renders it as
    a normal window — see ADR 0008).

  - Fill in ai/me.md, ai/workspace_map.md, vault/skill_map.md,
    vault/current_context.md — these are scaffolded, not written.
    Human-authored on purpose.

  - Run ollama.yaml / hermes.yaml — both verified working (Ollama
    with GPU passthrough, Hermes via custom endpoint, gemma4:e2b at
    100% GPU). See local_models.md for the setup walkthrough, model
    requirements (>=64K context + tools + thinking — qwen3 does NOT
    qualify), and operational notes. The chat UI stack and the
    revived-PC hardware plan still need their own decisions first
    (Exploration Notes).

  - Eight Hermes chat options, use whichever fits: hermes.yaml
    (ephemeral, Ollama only), hermes_claude.yaml (ephemeral, plus
    Claude Code delegation via `claude -p "task"`), hermes_codex.yaml
    (ephemeral, plus Codex delegation via `codex exec "task"`, pty=
    true required, wrap multi-command shell calls in
    bash -c "cmd1 && cmd2" — Hermes's terminal tool errors on a raw
    top-level && chain), hermes_all.yaml (ephemeral, BOTH Claude Code
    and Codex delegation in one image — CONFIRMED three
    interleaved delegation calls in one session, no cross-provider
    interference), hermes_dashboard.yaml (persistent, Ollama
    only, browser/desktop-app reachable at 127.0.0.1:9119),
    hermes_dashboard_with_claude.yaml (persistent + Claude Code
    delegation — what the native desktop app actually connects to),
    hermes_dashboard_with_codex.yaml (persistent + Codex
    delegation), or hermes_dashboard_with_all.yaml (persistent, both
    providers — confirmed via three interleaved calls
    through the standing gateway, reached remotely via the native
    Win11 app). All eight verified working; see local_models.md's delegation
    section and hermes_operations.md for the full recipes, the
    dashboard/desktop-app setup, and the provider-naming convention.
    Set a cheaper default model for Claude delegation via
    ~/.secrets/claude-home/settings.json — Claude Code defaults to
    its most expensive model otherwise. Note: all three dashboard
    profiles (hermes_dashboard, _with_claude, _with_codex) claim
    port 9119 — only one can run at a time without remapping.

  - Use scripts/run.sh (or the VS Code tasks in .vscode/tasks.json,
    Ctrl+Shift+P -> "Tasks: Run Task") instead of typing the compose
    commands above by hand: `run.sh hermes_claude`, `run.sh drift`
    (wraps this script's own --verify), `run.sh health`, and a bare
    `run.sh` for an interactive menu. Confirmed working end-to-end
. --remote-ollama switches any Hermes target to a
    remote Ollama instance (e.g. a desktop GPU on the LAN) instead
    of the local container.

  - Copy infrastructure/templates/AGENTS.md into your first real
    project and fill in its Project-Specific Instructions.
=====================================================================
EOF
