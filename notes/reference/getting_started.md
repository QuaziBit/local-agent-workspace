# Getting Started — WSL Environment Bootstrap

**Companion to `architecture.md` (v1.8+). A step-by-step runbook an agent
can execute sequentially in WSL, with each step independently verifiable
before moving to the next.**

## Scope

This runbook builds the **core, validated** parts of the architecture on
the WSL machine: workspace skeleton, infrastructure repo, all six
compose profiles (dev/docs/review/sandbox + ollama/hermes), the
vault, and Obsidian via WSLg. Everything it creates has been built,
run, and debugged for real — including the local-agent tier, which
was smoke-tested end to end (see `local_models.md`).

**Explicitly out of scope for this runbook** — these depend on
decisions or hardware not yet in place, and building them now would
violate the architecture's own "implement first, validate, then wire
it in" discipline:

- The chat UI stack (Exploration Notes) — not decided, may never be built
- The revived 2013 workstation (Appendix C hardware plan) — physical
  hardware work, not something run from inside WSL

If you are an agent executing this runbook: stop and ask before doing
anything not listed in a step below. Do not improvise additional
services, mounts, or network access.

## Phase 0 — Preflight

Verify prerequisites before creating anything:

```bash
# WSL version and distro
wsl.exe --status 2>/dev/null || echo "run from Windows, not WSL, to check this"
lsb_release -a                    # expect Ubuntu 24.04 LTS

# Docker
docker --version
docker compose version            # must be Compose v2

# Git
git --version

# Confirm current user is UID/GID 1000 (default first-user on Ubuntu)
id                                 # expect uid=1000 gid=1000
```

If UID/GID is not 1000, note the actual values — they'll need to
replace `1000` in Phase 2's Dockerfile and compose files.

Also confirm git has an identity configured — the commit steps in
Phase 2.6 and Phase 3 will fail silently otherwise:

```bash
git config user.email && git config user.name || {
  echo "Run these first:"
  echo '  git config --global user.email "you@example.com"'
  echo '  git config --global user.name "Your Name"'
}
```

**Stop here and report back if any of these are missing.** Do not
attempt to install Docker or WSL itself from this runbook — that's a
one-time host setup step, not a repeatable bootstrap action.

## Phase 1 — Workspace Skeleton

```bash
export WORKSPACE_ROOT="$HOME/workspace"

mkdir -p "$WORKSPACE_ROOT"/{projects,backups,archives}
mkdir -p "$WORKSPACE_ROOT"/projects/sandbox

mkdir -p "$WORKSPACE_ROOT"/vault/{agent_inbox,programming,security,research,ideas,projects,personal,archive}

mkdir -p "$WORKSPACE_ROOT"/infrastructure/{compose,docker/agent,bootstrap,configs,templates,scripts,docs/adr}

# ai/ is git-tracked content that lives INSIDE the infrastructure repo
# (architecture.md, Infrastructure Repository: "ai/ lives inside this
# repo... ~/workspace/ai/ is simply the checkout"). Create the real
# directory under infrastructure/, then symlink the workspace-level
# path to it — every ${AI_DIR} reference elsewhere keeps working
# unchanged, but the content is now actually version-controlled.
mkdir -p "$WORKSPACE_ROOT/infrastructure/ai"/{prompts,templates,coding-standards,security-policies,workflows}
ln -s "$WORKSPACE_ROOT/infrastructure/ai" "$WORKSPACE_ROOT/ai"

mkdir -p "$WORKSPACE_ROOT"/models/{ollama,embeddings,vector-db}

# Secrets: outside the workspace, never in Git
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

# Codex CLI persistence — bind-mounted at /home/ubuntu/.codex in
# every profile. CRITICAL: config.toml must force file-based
# credential storage BEFORE the first login, or the login silently
# doesn't survive a recreate. Codex's cli_auth_credentials_store
# defaults to "auto" (OS keyring when available, else auth.json) —
# inside a minimal container, auto routes the credential somewhere
# that dies with the container, so auth.json never appears on the
# mounted path. With "file" forced, auth.json lands on the mount
# and login persists. Guarded like claude-home.json: never
# overwrite a config.toml that already has content.
mkdir -p "$HOME/.secrets/codex-home"
if [ ! -s "$HOME/.secrets/codex-home/config.toml" ]; then
  echo 'cli_auth_credentials_store = "file"' > "$HOME/.secrets/codex-home/config.toml"
fi
chmod 700 "$HOME/.secrets/codex-home"

# Hermes Agent's own persistence directory — same host-visible
# pattern. Unlike claude-home, unexercised against a real container.
mkdir -p "$HOME/.secrets/hermes-home"
chmod 700 "$HOME/.secrets/hermes-home"
```

The block above is exactly what `setup.sh --secrets-only` now does
in one command — added specifically to avoid re-typing
this by hand. Either path works and they never conflict (same
`seed_secrets()` function underneath); manual is shown here because
this runbook's whole point is showing what setup.sh automates, but
`bash setup.sh --secrets-only` is the faster route for just this
piece — e.g. rebuilding `~/.secrets` alone without touching
`~/workspace`, which is exactly the situation a scorched-earth
rebuild puts you in.

Verify:

```bash
find "$WORKSPACE_ROOT" -maxdepth 2 -type d | sort
```

## Phase 2 — Infrastructure Repository

### 2.1 — workspace.env (the manifest)

```bash
cat > "$WORKSPACE_ROOT/infrastructure/workspace.env" << 'EOF'
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
```

### 2.2 — Agent Dockerfile (non-root, UID/GID matched to host)

```bash
cat > "$WORKSPACE_ROOT/infrastructure/docker/agent/Dockerfile" << 'EOF'
FROM ubuntu:24.04

ARG UID=1000
ARG GID=1000

RUN apt-get update && apt-get install -y \
    git curl ca-certificates build-essential \
    python3 python3-pip \
    && rm -rf /var/lib/apt/lists/*

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
RUN npm install -g @openai/codex

# Reuse Ubuntu's default UID-1000 user if present, else create one
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
```

*(See `bind-mounts-permissions-ownership.md` for why this matters —
skipping it means every file the agent creates ends up root-owned on
the host.)*

### 2.3 — Compose profiles

```bash
mkdir -p "$WORKSPACE_ROOT/infrastructure/compose"
```

**dev.yaml:**

```bash
cat > "$WORKSPACE_ROOT/infrastructure/compose/dev.yaml" << 'EOF'
services:
  dev:
    build: ../docker/agent
    working_dir: /workspace
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
      # vault as one unit would include it; a bind mount can't
      # exclude a subdirectory of what it mounts.
      - ${SECRETS_DIR}/claude-home:/home/ubuntu/.claude
      - ${SECRETS_DIR}/claude-home.json:/home/ubuntu/.claude.json
      # Both paths are required — Claude Code splits session state
      # across ~/.claude/ (the actual credential) and the separate
      # sibling file ~/.claude.json (login/onboarding status, checked
      # first). Persisting only one still re-prompts for login.
      - ${SECRETS_DIR}/codex-home:/home/ubuntu/.codex
      # Codex login persists here ONLY because config.toml inside
      # this directory forces cli_auth_credentials_store = "file"
      # (seeded in Phase 1) — the "auto" default routes the
      # credential to a store that dies with the container.
    # Balanced network: point at an egress-filtered proxy network
    # once one exists — network_mode left default for now
    stdin_open: true
    tty: true
EOF
```

**docs.yaml:**

```bash
cat > "$WORKSPACE_ROOT/infrastructure/compose/docs.yaml" << 'EOF'
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
```

**review.yaml:**

```bash
cat > "$WORKSPACE_ROOT/infrastructure/compose/review.yaml" << 'EOF'
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
```

**sandbox.yaml:**

```bash
cat > "$WORKSPACE_ROOT/infrastructure/compose/sandbox.yaml" << 'EOF'
services:
  sandbox:
    build: ../docker/agent
    working_dir: /workspace
    volumes:
      - ${PROJECTS_DIR}/sandbox:/workspace   # sandbox/ only — no other project
      - ${AI_DIR}:/ai:ro                     # standards still apply
      - ${SECRETS_DIR}/claude-home:/home/ubuntu/.claude
      - ${SECRETS_DIR}/claude-home.json:/home/ubuntu/.claude.json
      - ${SECRETS_DIR}/codex-home:/home/ubuntu/.codex
    # No vault mount at all in this profile
    stdin_open: true
    tty: true
EOF
```

All four bind-mount the same three host paths under `~/.secrets/`
(`claude-home/`, `claude-home.json`, `codex-home/`) —
host-visible and removable like every other secret in this setup,
not an opaque Docker-managed volume. Since the paths are identical
across all four files, logging in once from any profile — for either
agent — persists for every profile launched afterward, not just the
one you logged in from.

**ollama.yaml and hermes.yaml — run and verified:**

Both have been smoke-tested for real: Ollama serving models with GPU
passthrough, Hermes connected via the custom OpenAI endpoint, full
conversation round-trips confirmed. See **local_models.md** for the
setup walkthrough, the model requirements (≥64K context + `tools` +
`thinking` capabilities — **qwen3 does not qualify**, 40K ceiling),
and every operational finding. First-run order still applies on a
fresh machine: Ollama alone first, confirmed answering via `curl`,
before bringing Hermes up on top of it.

```bash
cat > "$WORKSPACE_ROOT/infrastructure/compose/ollama.yaml" << 'EOF'
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
    # install was needed). Uncomment on a host with an NVIDIA GPU.
    # deploy:
    #   resources:
    #     reservations:
    #       devices:
    #         - driver: nvidia
    #           count: 1
    #           capabilities: [gpu]
EOF

cat > "$WORKSPACE_ROOT/infrastructure/compose/hermes.yaml" << 'EOF'
services:
  hermes:
    image: nousresearch/hermes-agent
    environment:
      # Hermes's own write allowlist (write_file/patch tools) —
      # default is /opt/data only, which blocks even the legitimate
      # inbox. Extend it or Hermes cannot write to the vault at all.
      # NOTE: the terminal tool bypasses this guard; the read-only
      # mounts below are what catch terminal-path writes.
      - HERMES_WRITE_SAFE_ROOT=/opt/data:/vault/agent_inbox
      # PUID/PGID — official Hermes env vars remapping the internal
      # hermes user (default UID 10000) to match the host user, so
      # files it writes are directly openable without sudo. Set to
      # match the actual host user (verify with `id -u`).
      - PUID=1000
      - PGID=1000
    volumes:
      - ${SECRETS_DIR}/hermes-home:/opt/data
      # Same per-subfolder vault pattern as every other profile —
      # personal/ never listed (see architecture.md, ADR 0010).
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
    # point at this local ollama service OR a remote one. Include
    # -f ollama.yaml ONLY when actually using the local service —
    # the hostname still resolves fine when both files are passed
    # together:
    #   Local:   docker compose --env-file ../workspace.env \
    #              -f ollama.yaml -f hermes.yaml run --rm hermes
    #   Remote:  docker compose --env-file ../workspace.env \
    #              -f hermes.yaml run --rm hermes
    # Configure via: hermes setup — see local_models.md.
    # terminal.backend stays local, NOT docker — docker requires the
    # Docker socket mounted here, the exact risk parked in
    # features.md's Possible (Speculative) section.
EOF
```



Validate each profile parses correctly:

```bash
cd "$WORKSPACE_ROOT/infrastructure/compose"
for f in dev docs review sandbox; do
  docker compose --env-file ../workspace.env -f "$f.yaml" config > /dev/null \
    && echo "$f.yaml OK" || echo "$f.yaml FAILED"
done
```

### 2.4 — Default AGENTS.md template

```bash
mkdir -p "$WORKSPACE_ROOT/infrastructure/templates"
# See the standalone AGENTS.md deliverable — copy its content to:
# $WORKSPACE_ROOT/infrastructure/templates/AGENTS.md
```

### 2.5 — Automation script stubs

```bash
cat > "$WORKSPACE_ROOT/infrastructure/scripts/health_check.sh" << 'EOF'
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

echo "== Infrastructure files =="
check "workspace.env"           "[ -f '$INFRA_DIR/workspace.env' ]"
check "docker/agent/Dockerfile" "[ -f '$INFRA_DIR/docker/agent/Dockerfile' ]"
check "compose/dev.yaml"        "[ -f '$INFRA_DIR/compose/dev.yaml' ]"
check "compose/docs.yaml"       "[ -f '$INFRA_DIR/compose/docs.yaml' ]"
check "compose/review.yaml"     "[ -f '$INFRA_DIR/compose/review.yaml' ]"
check "compose/sandbox.yaml"    "[ -f '$INFRA_DIR/compose/sandbox.yaml' ]"
check "templates/AGENTS.md"     "[ -f '$INFRA_DIR/templates/AGENTS.md' ]"

echo "== Orientation layer scaffolds (Appendix B) =="
check "ai/me.md"                 "[ -f '$AI_DIR/me.md' ]"
check "ai/workspace_map.md"      "[ -f '$AI_DIR/workspace_map.md' ]"
check "vault/skill_map.md"       "[ -f '$VAULT_DIR/skill_map.md' ]"
check "vault/current_context.md" "[ -f '$VAULT_DIR/current_context.md' ]"

echo "== Git repositories =="
check "vault is a git repo"          "git -C '$VAULT_DIR' rev-parse --is-inside-work-tree >/dev/null 2>&1"
check "vault has a commit"           "git -C '$VAULT_DIR' log -1 >/dev/null 2>&1"
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
chmod +x "$WORKSPACE_ROOT/infrastructure/scripts/health_check.sh"
```

*(This content must stay identical to the copy embedded in `setup.sh` — one script, two places it's written from. If you edit one, edit both, or better, delete this copy once `setup.sh` is the only thing anyone actually runs.)*

*(`backup.sh` and `restore.sh` are deliberately left for a later pass —
write them once the git workflow in Phase 3 has been used for real, so
they reflect actual usage rather than a guess.)*

### 2.6 — Git init the infrastructure repo

```bash
cd "$WORKSPACE_ROOT/infrastructure"
git init
cat > .gitignore << 'EOF'
*.env
!workspace.env
EOF
git add .
git commit -m "Infrastructure repo: initial skeleton"
```

## Phase 3 — Vault

```bash
cd "$WORKSPACE_ROOT/vault"
git init

cat > .gitignore << 'EOF'
.obsidian/workspace*.json
EOF

# Placeholder so empty dirs survive the first commit
for d in agent_inbox programming security research ideas projects personal archive; do
  touch "$d/.gitkeep"
done

git add .
git commit -m "Vault: initial structure"
```

**Do not commit anything into `personal/` from this runbook.** That
folder is human-only by design (see architecture.md, Filesystem
Security) — an agent should never populate it.

## Phase 4 — Obsidian (inside WSL, via WSLg)

Per architecture.md §Obsidian Knowledge Base / ADR 0008 — native Windows
Obsidian cannot reliably open a WSL vault. Install inside WSL instead:

```bash
deb_link=$(curl -s https://obsidian.md/download | grep -o \
  'https://github[^0-9]*/v[0-9]\.[0-9]\.[0-9]/obsidian_[0-9]\.[0-9]\.[0-9]_amd64.deb')
wget "$deb_link" -O /tmp/obsidian.deb
sudo apt install /tmp/obsidian.deb
```

This step requires a human to actually launch `obsidian` and open the
vault at `~/workspace/vault` — an agent can install the package but
shouldn't drive the GUI on the human's behalf.

## Phase 5 — Orientation Layer Skeleton (Appendix B — optional)

These four files are marked "pending validation in use" in
architecture.md. Creating the skeletons is part of validating them —
but their content is personal and should be human-authored, not
agent-generated. Create empty scaffolds only:

```bash
cat > "$WORKSPACE_ROOT/ai/me.md" << 'EOF'
# Me

<!-- Engineering brief: goals, preferred languages/tools, coding
     philosophy, communication preferences. Mounted into every
     container — keep it professional, not personal. -->
EOF

cat > "$WORKSPACE_ROOT/ai/workspace_map.md" << 'EOF'
# Workspace Map

<!-- For each top-level directory: purpose, what an agent may touch,
     typical contents. One page, hard limit. -->
EOF

cat > "$WORKSPACE_ROOT/vault/skill_map.md" << 'EOF'
# Skill Map

<!-- One line per domain, linking to detailed vault notes.
     e.g. Docker → programming/docker-notes.md -->
EOF

cat > "$WORKSPACE_ROOT/vault/current_context.md" << 'EOF'
Priority this week:
Active project:
Blocked by:
Avoid touching:
Notes:
EOF
```

Leave these for the human to fill in. Do not write speculative
content into `me.md` on their behalf.

`ai/me.md` and `ai/workspace_map.md` are written through the symlink
created in Phase 1 — they physically live at
`infrastructure/ai/me.md` and `infrastructure/ai/workspace_map.md`.
`git status` inside `infrastructure/` (not inside `ai/`) is where
you'll see them as new files to commit; `vault/skill_map.md` and
`vault/current_context.md` show up under `git status` in `vault/`.

## Phase 6 — Verify

```bash
bash "$WORKSPACE_ROOT/infrastructure/scripts/health_check.sh"
```

All lines should read `OK`. If anything is `MISSING` or
`NOT INITIALIZED`, stop and report which step to re-run — do not
proceed to using a dev profile on an unverified setup.

## What Happens Next (Not Part of This Runbook)

- Copy `infrastructure/templates/AGENTS.md` into each new project
  under `projects/`, and fill in its project-specific section.
- Fill in `ai/me.md`, `ai/workspace_map.md`, `vault/skill_map.md`,
  `vault/current_context.md` — human-authored.
- When `dev.yaml` is actually used for the first time: set
  `PROJECT`, `SECRETS_DIR/${PROJECT}.env`, and confirm the mounts
  behave as expected before trusting it with real work.
- `ollama.yaml`, `hermes.yaml`, `hermes_claude.yaml`, and
  `hermes_codex.yaml` are all verified working — see
  `local_models.md` for setup, model requirements, and each
  provider's delegation recipe (`hermes_operations.md` section 8
  has the full profile list and the port-9119 conflict). The chat
  UI stack and the revived-PC hardware plan still stay fully out of
  scope until each is individually decided — see Exploration Notes.
- Once the workspace is bootstrapped, prefer
  `infrastructure/scripts/run.sh` over typing any `docker compose`
  command above by hand — `run.sh hermes_claude`, `run.sh drift`
  (wraps `setup.sh --verify`), `run.sh health`, `run.sh models` /
  `run.sh pull [model]` for the local Ollama, or a bare `run.sh`
  for an interactive menu. The same commands are available as VS
  Code tasks via `.vscode/tasks.json` (Ctrl+Shift+P -> "Tasks: Run
  Task") once `~/workspace` itself is the opened folder. Both are
  embedded in `setup.sh` alongside everything else in this runbook.

Once this runbook has been run for real and each phase confirmed
working, fold the verified commands into
`infrastructure/bootstrap/setup.sh` as a single script — per
architecture.md's own rule: implement first, then automate. (As of
this writing, that fold has already happened for everything above.)
