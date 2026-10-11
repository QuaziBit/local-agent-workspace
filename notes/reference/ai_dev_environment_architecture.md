# AI Development Environment

**WSL + Docker Compose + AI Agents + Obsidian + Infrastructure as Code**

## Document Information

| | |
|---|---|
| **Version** | 1.12 |
| **Last Updated** | |
| **Status** | Personal Production Architecture — Stable |

**Changelog**

- **1.14** — Adopted snake_case (`a_file_name`) as the naming
  convention for all project files and the identifiers derived from
  them: file names, compose service names, docker build-context
  directories, `run.sh` targets, scaffold files, and the vault inbox
  (`agent-inbox` → `agent_inbox`, superseding 1.13's name before
  anything went live). Deliberately EXCLUDED from the convention:
  the upstream image name (`nousresearch/hermes-agent`), CLI flags
  (`--remote-ollama` — flags are conventionally hyphenated), and the
  three live secrets directories (`claude-home`, `codex-home`,
  `hermes-home`) — those exist on disk holding working logins, and
  renaming them would break the Run-1 credential-persistence test in
  testing_plan.md; they can adopt the convention during the Run-2
  scorched-earth rebuild if desired, since that recreates them
  anyway.
- **1.13** — Renamed the vault inbox folder `00-inbox` →
  `agent-inbox` across this document and every companion file
  (compose profiles, `HERMES_WRITE_SAFE_ROOT` values, setup.sh's
  embedded copies, setup.bats, docs). Name over sort-order: the
  numeric prefix pinned the folder to the top of listings, but the
  name now states what the folder IS — the one path agents may
  write to. Live-system migration (mv the host directory, re-apply
  its `chmod o+w`, fix intra-vault references) happens in the same
  sitting the updated files land; `setup.sh --verify` confirms the
  embedded and live copies agree afterward.
- **1.12** — Correction: Appendix C's `hermes.yaml` had a hard
  `depends_on: ollama`, which forces starting a local Ollama
  container even when `config.yaml`'s `base_url` points at a remote
  endpoint (e.g. a second machine's GPU over the LAN — see
  `local_models.md`, "LAN Ollama"). Removed across all Hermes
  profiles; `-f ollama.yaml` is now an explicit choice at run time,
  not an enforced dependency. ADR 0012.
- **1.11** — Correction: Appendix C's `hermes.yaml` example was speculative and wrong on two points — it invented a custom build and an env var (`OLLAMA_BASE_URL`) that doesn't exist. Fixed to use the real official image (`nousresearch/hermes-agent`) and the real config path (`hermes setup` / `hermes model`, not an env var). Vault/workspace mounts deliberately deferred to a second pass, after basic Ollama connectivity is proven — not assumed correct on the first attempt. ADR 0011.
- **1.10** — Security correction: every vault mount example (Enforced Mount Permissions, dev.yaml, review.yaml, Appendix C's hermes.yaml) mounted the whole vault as one unit, which included `personal/` despite the stated rule to exclude it. Fixed to mount each curated subfolder individually. ADR 0010.
- **1.9** — `getting_started.md` written (fills the slot reserved in Companion Documents). Default `AGENTS.md` template added at `infrastructure/templates/AGENTS.md`, scoped to `/workspace` only.
- **1.8** — Added `ideas/` to the vault structure: idea harvesting and hypothesis exploration, distinct from `research/`. Uses the existing trust model — no new mechanism.
- **1.7** — Hardware Placement in Appendix C replaced with a concrete plan: a revived idle 2013 workstation, not a generic "whichever desktop has a GPU." ADR 0009.
- **1.6** — Added a shape diagram to Exploration Notes (still unvalidated, no new decisions).
- **1.5** — Correction: native Windows Obsidian cannot reliably open a WSL vault over `\\wsl.localhost` (documented upstream bug). Obsidian now runs inside WSL2 via WSLg; a one-way mirror is the documented fallback. ADR 0008.
- **1.4** — Added Exploration Notes section (chat UI / vector DB candidates). Unvalidated, undecided, no core architecture change.
- **1.3** — Added Appendix C: Local Agent Stack (Hermes + Ollama), a second, fully offline agent tier alongside Claude Code. New Container Profile ("Local Agent"). ADR 0007. Pending validation in use.
- **1.2** — Added Appendix B: AI Orientation Layer (four files, pending validation in use). Core architecture unchanged.
- **1.1** — Added Engineering Principles, Goals/Non-Goals, Naming Conventions, Supported Baseline, ADRs, Companion Documents.
- **1.0** — Initial stable architecture.

## Architecture Status

Version 1.x is considered stable.

Future improvements should be implemented first and documented afterward. Avoid expanding this document without a corresponding architectural change. Deep dives belong in companion documents (see [Companion Documents](#companion-documents)), not here.

## Overview

Run AI coding agents inside Docker containers hosted by WSL Ubuntu. This provides an isolated, reproducible development environment while keeping project files persistent.

An Obsidian vault stored in WSL serves as a personal knowledge base that both AI agents and Obsidian (running inside WSL2, see [Obsidian Knowledge Base](#obsidian-knowledge-base)) can access.

The entire workstation is treated as a collection of independent, replaceable modules described by version-controlled infrastructure. Docker Compose is the primary interface: every container profile is a version-controlled compose file, not a hand-typed command.

## Goals / Non-Goals

**Goals**

- ✓ Portable (recreatable on a new machine)
- ✓ Modular (every component independently replaceable)
- ✓ Secure (least privilege by default)
- ✓ Offline capable (strict profiles, local models)
- ✓ Vendor independent (open standards throughout)

**Non-Goals**

- ✗ Enterprise orchestration
- ✗ Multi-user platform
- ✗ High availability
- ✗ Kubernetes-first deployment

Non-Goals define the scope boundary. If a future change requires one of these, it is a different architecture — not an extension of this one.

## Prerequisites

**Required**

- Windows 11
- WSL2 + Ubuntu
- Docker (choose one):
  - Docker Engine installed directly in WSL (lighter, no licensing considerations), or
  - Docker Desktop (adds a GUI and manages WSL integration)
- Git
- Obsidian

**Optional**

- VS Code (+ WSL extension)
- Claude Desktop / Claude Code
- Codex CLI
- Ollama (local models)
- Podman (Docker alternative)
- NVIDIA Container Toolkit (GPU passthrough for local models)

On machine reinstall, this section is the checklist.

## Supported Baseline

Host-level versions this architecture is tested against:

- Windows 11
- Ubuntu 24.04 LTS (WSL2)
- Docker Engine with Compose v2
- Git 2.x

Language runtimes (Python, Node, Go) are deliberately **not** pinned here — each project pins its own versions in its Dockerfile. That is the point of the containers.

## Core Philosophy

- Containers are disposable.
- Data is persistent.
- Projects stay isolated.
- Knowledge is centralized.
- Secrets are never exposed unnecessarily.
- Boundaries are enforced structurally, not by convention.
- Everything important is backed up automatically.
- Backups are tested, not assumed.
- Git is the source of truth for what changed.
- Every component is modular and independently replaceable.
- Environments are launched from version-controlled compose files, never from hand-typed commands.
- Infrastructure is reproducible from Git in under one hour; user data is restored from backups on top of it.
- Prefer open standards (Markdown, Git, Docker, Compose) over vendor-specific formats.

## Engineering Principles

The design decisions throughout this document follow from:

- **Principle of Least Privilege** — container profiles, scoped tokens, minimal mounts
- **Separation of Concerns** — configuration / state / artifacts / secrets
- **Infrastructure as Code** — compose profiles, bootstrap scripts, versioned policies
- **Immutable Containers, Mutable Data** — containers are rebuilt, never patched; the workspace and vault are deliberately mutable and backed up instead
- **Defense in Depth** — filesystem mounts + network modes + scoped credentials
- **Open Standards** — Markdown, Git, Compose, env files
- **Single Source of Truth** — workspace.env, AGENTS.md, the ai-workstation repo
- **Configuration over Convention** — boundaries in mount flags and YAML, not in prompts

## Naming Conventions

| Kind | Convention | Example |
|---|---|---|
| Directories | lowercase-with-hyphens | `agent_inbox`, `vector-db` |
| Compose profiles | `<purpose>.yaml` | `dev.yaml`, `review.yaml` |
| Scripts | `<verb>.sh` | `backup.sh`, `restore.sh` |
| Manifests | `<scope>.env` | `workspace.env` |
| ADRs | `NNNN-<decision>.md` | `0001-compose-first.md` |
| Orientation files | lowercase-with-hyphens.md | `me.md`, `skill_map.md` |

No spaces in any path. Consistency prevents naming drift and keeps every path quote-free in scripts and mounts.

## Architecture

```
Windows
│
├── Codex / Claude Desktop (UI)
│
└── WSL Ubuntu
    │
    ├── Obsidian (runs inside WSL via WSLg —
    │             see Obsidian Knowledge Base)
    │
    ├── Docker Engine
    │
    ├── AI Container (launched via compose profile)
    │   ├── Ubuntu
    │   ├── Python / Node / Go
    │   ├── AI Coding Agent
    │   ├── /workspace        (rw)
    │   ├── /vault            (ro)
    │   ├── /vault/agent_inbox   (rw)
    │   └── /ai               (ro)
    │
    └── ~/workspace/
        ├── projects/
        ├── vault/
        ├── ai/
        ├── infrastructure/
        ├── models/
        ├── backups/
        └── archives/
```

Desktop UIs remain on Windows.

The actual AI agent executes entirely inside the Docker container.

## Modularity & Portability

The workstation is a collection of independent modules rather than a single monolithic environment.

Each module has:

- One responsibility
- One storage location
- One backup strategy
- One migration strategy

**Modules**

- Projects
- Knowledge Base (Vault)
- AI Policies & Standards
- Containers
- Infrastructure
- Local AI Models
- Secrets
- Backups
- Automation

Each module is replaceable without changing the others.

**Examples**

- Replace Claude Code with Codex CLI (or a future agent): no project changes required — projects define their needs in AGENTS.md and standard config files.
- Replace Obsidian with Logseq or VS Code + Markdown: the vault remains standard Markdown files.
- Replace Docker with Podman: project layouts and compose files remain valid (podman-compose reads the same files).

This minimizes vendor lock-in and simplifies future migrations.

## Container Lifecycle

Containers are temporary.

Safe operations:

```
docker compose up          Start / recreate
docker compose down        Stop and remove
docker compose restart     Restart
docker compose down &&
docker compose up          Full recreation
```

Persistent data remains outside the container.

## Persistence Methods

### Option A (Recommended): Bind Mount a WSL Directory

Example (compose):

```yaml
services:
  dev:
    volumes:
      - ~/workspace/projects/myapp:/workspace
```

Advantages: fast, native Linux filesystem, easy editing, Git friendly, easy backups.

**Never place active projects under `/mnt/c`.** The Windows 9P bridge significantly reduces filesystem performance and may break filesystem watchers.

### Option B: Docker Volumes

Useful for: databases, Redis, Elasticsearch, Ollama model blobs, pip cache, npm cache.

Avoid storing source code inside Docker volumes unless there is a specific reason.

## Filesystem Security

The container itself is isolated. **Anything mounted into the container becomes visible to the AI.**

Rules:

- Never mount `~/.ssh`
- Never mount `~/.aws`
- Never mount personal credentials
- Never mount the entire home directory
- Never mount `/mnt/c`
- Never mount `vault/personal/` into AI containers
- Mount only the project the AI is working on

## Enforced Mount Permissions

Boundaries should be structural, not behavioral. Do not rely on prompt instructions like "only modify notes when requested" — enforce it with mount flags.

Pattern:

- Vault mounted read-only.
- Inbox mounted read-write on top of it.
- Personal folder excluded entirely.
- AI policies mounted read-only.

In compose:

```yaml
services:
  dev:
    volumes:
      - ~/workspace/projects/myapp:/workspace
      - ~/workspace/vault/agent_inbox:/vault/agent_inbox
      - ~/workspace/vault/programming:/vault/programming:ro
      - ~/workspace/vault/security:/vault/security:ro
      - ~/workspace/vault/research:/vault/research:ro
      - ~/workspace/vault/ideas:/vault/ideas:ro
      - ~/workspace/vault/projects:/vault/projects:ro
      - ~/workspace/vault/archive:/vault/archive:ro
      - ~/workspace/ai:/ai:ro
```

Each curated vault subfolder is mounted individually, and `personal/`
is simply never listed. This is the only way to actually achieve
"excluded entirely" — mounting the whole vault as one unit
(`~/workspace/vault:/vault:ro`) would include `personal/` too, since
a bind mount always includes every child of the directory it mounts;
there is no mechanism to carve a subdirectory back out of a single
parent mount.

Result:

- AI can read every curated vault folder (not `personal/` — it was
  never mounted, not merely marked off-limits).
- AI can write **only** into agent_inbox.
- Curated notes physically cannot be modified.
- Review workflow is guaranteed by the kernel, not by the model.

## Secrets

Location: `~/.secrets/` — never mount this directory into AI containers.

Inject only the environment variables required for the current project. In compose:

```yaml
services:
  dev:
    env_file:
      - ~/.secrets/myapp.env
```

**Off-machine recovery source (required).** Secrets are deliberately excluded from both Git and backups, so recovery needs an explicit source. Choose one:

- Password manager (Bitwarden, KeePassXC), or
- Encrypted archive (age / gpg) stored off-machine.

Without this, workstation recovery stalls at the secrets step.

**Scoped credentials.** Prefer per-project, minimally-scoped tokens. Example: a fine-grained GitHub personal access token limited to a single repository, instead of an account-wide token.

## Network Security

Filesystem protection is only half the story. Anything the AI can read could potentially be transmitted over the network.

Recommended network modes:

**Strict**

```yaml
network_mode: "none"
```

Ideal for: refactoring, documentation, code review, local analysis.

**Balanced**

Allow outbound traffic only to trusted services, e.g.: `api.openai.com`, `api.anthropic.com`, `pypi.org`, `npmjs.com`.

> **Caution:** github.com on an allowlist partially defeats it — an agent that can reach github.com can push readable data to an arbitrary repository. If a project needs GitHub access, use a fine-grained token scoped to that single repository instead of open egress to the domain.

**Open**

Default Docker bridge. Recommended only for low-risk projects.

## Container Profiles

Different tasks require different security levels. Select the smallest profile that fits the task (Principle of Least Privilege).

| Profile | Workspace | Vault | Inbox | Network |
|---|---|---|---|---|
| Development | Read/Write | Read Only | Read/Write | Balanced (allowlist) |
| Documentation | Read/Write | Read Only | Read/Write | None or Balanced |
| Code Review | Read Only | Read Only | Read/Write (review output lands here) | None |
| Experimentation | sandbox/ only | None | — | Balanced |
| Local Agent (Hermes) | Read/Write | Read Only | Read/Write | None (fully offline) — Balanced only if a web-search tool is deliberately enabled |

Each profile is a compose file in `infrastructure/compose/` — profiles are commands, not aspirations:

```
infrastructure/compose/
├── dev.yaml
├── docs.yaml
├── review.yaml
├── sandbox.yaml
├── hermes.yaml     ← local agent (see Appendix C)
└── ollama.yaml     ← local model backend (see Appendix C)
```

Launch:

```bash
docker compose -f infrastructure/compose/dev.yaml up -d
docker compose -f infrastructure/compose/dev.yaml exec dev bash
```

**Example: dev.yaml**

```yaml
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
      # vault/personal/ is deliberately absent from this list — see
      # Filesystem Security. Mounting the whole vault as one unit
      # (${VAULT_DIR}:/vault:ro) would include it; there is no way
      # to exclude a subdirectory from a single parent bind mount.
    # Balanced network: attach to an egress-filtered
    # proxy network defined in infrastructure/compose/
    networks:
      - egress-allowlist
    stdin_open: true
    tty: true
```

**Example: review.yaml** (note the differences)

```yaml
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
    network_mode: "none"                           # ← offline
    stdin_open: true
    tty: true
```

The entire difference between "agent that builds" and "agent that can only read and report" is three lines of versioned YAML.

(Compose reads `${VARS}` from a .env file or the shell environment — point it at workspace.env.)

## Obsidian Knowledge Base

Vault location: `~/workspace/vault`

**Known limitation:** Windows Obsidian cannot reliably open a vault over `\\wsl.localhost\...`. Its file watcher throws `EISDIR: illegal operation on a directory, watch '\\wsl.localhost\...'` on that UNC path — a long-standing, still-unresolved upstream issue, not a local misconfiguration.

**Fix: run Obsidian inside WSL2 via WSLg.** WSL2 supports native Linux GUI apps that render as ordinary Windows windows. Installing Obsidian's Linux `.deb` inside Ubuntu gives full, native access to the ext4 vault — no UNC path, no watcher issue, no change to any mount or backup already specified in this document.

```bash
deb_link=$(curl -s https://obsidian.md/download | grep -o \
  'https://github[^0-9]*/v[0-9]\.[0-9]\.[0-9]/obsidian_[0-9]\.[0-9]\.[0-9]_amd64.deb')
wget "$deb_link" -O obsidian.deb
sudo apt install ./obsidian.deb
obsidian   # launches as a normal Windows window via WSLg
```

Open the vault at `~/workspace/vault` directly. This is the primary, supported path — it keeps the vault a single copy on ext4, exactly as every other section of this document assumes.

**Fallback: one-way mirror to a Windows-side path.** If WSLg isn't available or native Windows Obsidian is preferred for its plugin ecosystem, do not dual-write the same vault from both sides — the WSL copy stays canonical, and a mirror is pushed to Windows after a session:

```bash
# after a WSL/agent session — WSL vault → Windows mirror (one-way only)
rsync -av --delete ~/workspace/vault/ /mnt/c/Users/<user>/vault-mirror/
```

The mirror is read/browse-only from Windows Obsidian. Never edit the mirror and sync it back — that reintroduces the exact merge-conflict risk the [Backups, Versioning & Audit Trail](#backups-versioning--audit-trail) section's git workflow is designed to avoid. This is a stopgap, not a second source of truth.

Container mounts:

```
/vault            (read-only)
/vault/agent_inbox   (read-write)
```

Vault structure (organized by trust):

```
vault/
├── agent_inbox/         ← AI writes here
├── programming/
├── security/
├── research/
├── ideas/            ← idea harvesting, hypothesis exploration
├── projects/
├── personal/         ← never mounted into containers
└── archive/
```

`ideas/` vs `research/`: research investigates something with an existing question or reference material already in hand. Ideas captures raw, speculative, half-formed thoughts and hypotheses worth testing — the output of a brainstorming session, human or AI-assisted, that may or may not go anywhere yet. Same trust level as every other curated folder: read-only to agents, and AI-generated material still lands in agent_inbox first for review before anything is promoted here — no new mechanism, just one more destination folder.

## AI Rules

AI may:

- ✓ Read mounted notes
- ✓ Search the vault
- ✓ Create new notes (in agent_inbox only)
- ✓ Draft improvements to existing notes (as new files in agent_inbox)
- ✓ Build indexes
- ✓ Generate summaries
- ✓ Generate documentation

Enforced by mounts:

- New and modified content lands in agent_inbox.
- Curated notes are promoted out of agent_inbox manually, after human review.
- `personal/` is invisible to the AI.

## Backups, Versioning & Audit Trail

**Git is both the backup AND the audit trail.**

A self-reported "AI changes" log is a courtesy summary, not an audit — an agent that misbehaves or forgets will not log it. Git diffs show exactly what changed, with no honor system.

Workflow — before an AI session:

```bash
cd ~/workspace/vault
git add . && git commit -m "pre-session snapshot"
```

After the session:

```bash
git diff              # review exactly what the AI changed
git add . && git commit -m "AI session: <summary>"
```

Daily (projects and vault):

```bash
git add .
git commit -m "Daily backup"
```

Advantages: full history, exact per-session diffs, easy rollback, tiny storage usage, works well with markdown.

**What lives where**

| Item | Location |
|---|---|
| Infrastructure | Git (ai-workstation repo) |
| Projects | their own Git repositories |
| Vault | Git + periodic off-machine push |
| Large binary files | outside Git (backups/ or archives/) |
| Databases | exported on a schedule into backups/ |
| Local model blobs | Docker volume — **not** backed up (re-downloadable; back up models.txt manifest instead) |
| Secrets | password manager / encrypted archive |

Vault `.gitignore`:

```
.obsidian/workspace*.json
```

(Workspace state churns constantly and pollutes diffs. Keep the rest of `.obsidian/` if settings should be versioned.)

Alternative / supplement — daily compressed archives:

```
backups/
├──.tar.gz
├──.tar.gz
└──.tar.gz
```

## Backups vs Archives

| | |
|---|---|
| `backups/` | Automated snapshots of **live** state (vault, active projects, databases). Rotated, recent, restorable. |
| `archives/` | Retired content removed from active use (finished or abandoned projects taken out of projects/, old experiments). Kept long-term, rarely touched. |

## AI Change Log (Optional)

The AI may additionally maintain `vault/agent_inbox/ai-changes.md`. Each session records notes created, documentation generated, and major structural suggestions.

This is a human-readable summary for convenience. **Git remains the source of truth.**

## Recommended Workspace Layout

```
~/workspace/
│
├── projects/
│   ├── project1/
│   ├── project2/
│   └── sandbox/
│
├── vault/
│   ├── agent_inbox/
│   ├── programming/
│   ├── security/
│   ├── research/
│   ├── ideas/
│   ├── projects/
│   ├── personal/
│   ├── archive/
│   ├── skill_map.md          ← orientation (Appendix B)
│   └── current_context.md    ← orientation (Appendix B)
│
├── ai/                       ← checkout of ai-workstation/ai/
│   ├── prompts/
│   ├── templates/
│   ├── coding-standards/
│   ├── security-policies/
│   ├── workflows/
│   ├── me.md                 ← orientation (Appendix B)
│   └── workspace_map.md      ← orientation (Appendix B)
│
├── infrastructure/           ← checkout of ai-workstation repo
│   ├── compose/
│   ├── docker/
│   ├── bootstrap/
│   ├── templates/
│   ├── configs/
│   ├── scripts/
│   └── docs/
│
├── models/                   ← Local AI Models module
│   ├── ollama/               (or a Docker volume)
│   ├── embeddings/
│   ├── vector-db/
│   └── models.txt            ← manifest (this IS the backup)
│
├── backups/
│
└── archives/

~/.secrets/                   ← outside workspace, never in Git
```

## Local AI Models

Local models are a module like any other service (Redis, Postgres) — defined now, adopted when needed.

- Ollama runs as a compose service; model blobs live in a Docker volume or `models/ollama/`.
- Model blobs are **not** backed up — they are re-downloadable reproducible artifacts. `models.txt` (the list of model names and tags) is the backup.
- GPU passthrough: WSL2 Docker supports the NVIDIA Container Toolkit — the host RTX GPU is usable inside containers.
- `vector-db/` hosts embeddings for semantic search over the vault (a natural future extension: local RAG over notes).

**Local agent framework.** Ollama is a model backend, not an agent — it needs a harness to edit files, run commands, and hold session memory. [Hermes Agent](https://github.com/NousResearch) (Nous Research) fills that role and is explicitly designed to run fully offline against Ollama. Paired together they form a second, fully local agent tier alongside Claude Code. See **Appendix C** for the profile, hardware placement, and the reasoning for running both tiers rather than picking one.

## Project Structure

Each project is self-contained.

```
project-name/
├── compose.yaml
├── Dockerfile
├── README.md
├── AGENTS.md          ← canonical agent instructions (copy the
│                        default template from
│                        infrastructure/templates/AGENTS.md)
├── CLAUDE.md          ← one line: "See AGENTS.md" (or symlink)
├── .env.example
├── src/
├── tests/
├── docs/
└── scripts/
```

AGENTS.md is the emerging cross-agent convention. Keep it as the single source of truth; CLAUDE.md just points to it. This avoids two instruction files drifting apart.

Division of guidance:

- Global AI guidance lives in `/ai` (shared, versioned).
- Project-specific guidance lives in that project's AGENTS.md.

Each project can be copied, archived, or migrated independently.

## Infrastructure Repository

Maintain a dedicated Git repository describing the workstation itself.

```
ai-workstation/
├── ai/                ← policies, prompts, guidelines,
│                        me.md, workspace_map.md
├── compose/           ← container profiles (dev, docs, review,
│                        sandbox, ollama)
├── docker/            ← agent image Dockerfiles
├── bootstrap/
├── configs/
├── templates/
├── scripts/
├── workspace.env      ← workspace manifest
└── docs/
    ├── architecture.md    ← this document
    ├── adr/               ← Architecture Decision Records
    └── ...                ← companion documents
```

This repository intentionally does **not** contain: projects, vault, secrets, backups, model blobs.

It contains everything needed to **recreate** the workstation.

Note: `ai/` lives inside this repo. By the configuration-vs-state rule, AI policies are configuration — so they must be reproducible from Git. `~/workspace/ai/` is simply the checkout.

## Architecture Decision Records

`docs/adr/` preserves the **why** behind each decision, so future revisits see reasoning instead of just outcomes.

Format: one short markdown file per decision — Context / Decision / Consequences.

Seed ADRs (the reasoning already exists; write it down):

| ADR | Summary |
|---|---|
| `0001-compose-first.md` | Hand-typed docker run commands are unversioned state; profiles must be reviewable, diffable YAML. |
| `0002-read-only-vault-with-inbox-overlay.md` | Prompt-level rules are conventions; mount flags are enforcement. AI writes land in one reviewable place. |
| `0003-agents-md-canonical.md` | Two agent instruction files drift; AGENTS.md is the cross-agent standard, CLAUDE.md is a pointer. |
| `0004-env-file-manifest-over-yaml.md` | workspace.env is sourceable by bare bash and read natively by Compose; YAML needs a parser installed before bootstrap can run. |
| `0005-model-blobs-are-artifacts-not-state.md` | Re-downloadable multi-GB blobs don't belong in backups; the models.txt manifest is the backup. |
| `0006-orientation-layer-four-files.md` | Agents need global context before project context; four small files beat six overlapping ones. Static tool lists go stale; git-answerable fields don't belong in a hand-maintained status file. |
| `0007-two-tier-agent-strategy.md` | Cloud (Claude Code) and local (Hermes + Ollama) agents solve different problems — data isolation vs. zero network dependency — and have different quality/speed ceilings. Run both as separate profiles rather than replacing one with the other. |
| `0008-obsidian-runs-inside-wsl.md` | Windows Obsidian cannot reliably watch/edit a vault over `\\wsl.localhost` (documented upstream EISDIR bug). Running Obsidian inside WSL2 via WSLg keeps the vault a single ext4 copy with no path or performance compromise, instead of forking it across two filesystems. |
| `0009-dedicated-server-for-local-agent-tier.md` | The local agent tier (Appendix C) needs its own host, not a shared daily-driver desktop or the isolated Claude Code node. An idle 2013 workstation, upgraded with one GPU and a DDR3 kit, fills that role without a new purchase and mostly sidesteps the 2026 DRAM/NAND price crisis, since legacy DDR3 isn't part of the shortage. |
| `0010-vault-personal-mount-per-subfolder.md` | Mounting the whole vault as one unit (`${VAULT_DIR}:/vault:ro`) necessarily includes `personal/`, since a bind mount has no mechanism to exclude a child of the directory it mounts — contradicting the stated rule to exclude it entirely. Fixed by mounting each curated subfolder individually and never listing `personal/`. Found via a real bootstrap run, before any agent was actually connected. |
| `0011-hermes-real-image-real-config-path.md` | The original Appendix C `hermes.yaml` was speculative, not verified — it invented a custom Docker build and an `OLLAMA_BASE_URL` env var that don't exist. Corrected to the real official image and the real interactive config path (`hermes setup` / `hermes model`) after actually checking Nous Research's docs, rather than continuing to guess at an unverified tool's interface. |
| `0012-hermes-optional-ollama-dependency.md` | Every Hermes profile hard-`depends_on`'d the local Ollama service — reasonable while only a local endpoint existed, but wrong once a remote endpoint (a second machine's GPU over the LAN) became a real option: the hard dependency forced starting an unused local container every time. Removed across all profiles; `-f ollama.yaml` is now an explicit run-time choice, not an enforced one. Found in real use, switching between a laptop's local Ollama and a desktop's over the LAN. |

## Configuration vs State

Separate configuration from user data.

**Configuration** (reproducible from Git):

- compose files / container profiles
- Dockerfiles
- bootstrap scripts
- AI policies & standards (`ai/`, incl. me.md, workspace_map.md)
- templates
- workspace manifest
- models.txt manifest
- infrastructure repository

**State** (restored from backups):

- Projects
- Vault (incl. skill_map.md, current_context.md)
- Databases
- Backups themselves

**Reproducible artifacts** (re-downloaded, not backed up):

- Model blobs
- Docker images
- Package caches

**Secrets** (restored from password manager / encrypted archive):

- `~/.secrets/`

Configuration is version controlled. State is backed up. Artifacts are re-fetched. Secrets have their own off-machine recovery source.

## Workspace Manifest

Avoid hardcoding absolute paths throughout scripts.

Maintain a single manifest as a plain env file — sourceable by bare bash on a fresh machine (no yq/Python dependency) and read natively by Docker Compose:

**workspace.env**

```bash
WORKSPACE_ROOT="$HOME/workspace"
PROJECTS_DIR="$WORKSPACE_ROOT/projects"
VAULT_DIR="$WORKSPACE_ROOT/vault"
AI_DIR="$WORKSPACE_ROOT/ai"
INFRA_DIR="$WORKSPACE_ROOT/infrastructure"
MODELS_DIR="$WORKSPACE_ROOT/models"
BACKUPS_DIR="$WORKSPACE_ROOT/backups"
ARCHIVES_DIR="$WORKSPACE_ROOT/archives"
SECRETS_DIR="$HOME/.secrets"
```

Usage:

```bash
# In scripts:
source ~/workspace/infrastructure/workspace.env

# In compose (reads the same file):
docker compose --env-file \
    ~/workspace/infrastructure/workspace.env \
    -f infrastructure/compose/dev.yaml up -d
```

Bootstrap scripts, automation, and compose profiles all reference this single manifest.

## Bootstrap & Recovery

A new workstation should be recoverable with minimal manual effort. Prerequisites section = the install checklist.

**Phase 1 — Infrastructure** (target: under one hour, mostly one command after the clone):

1. Install prerequisites (see Prerequisites).
2. `git clone ai-workstation` → `~/workspace/infrastructure`
3. `./bootstrap/setup.sh` (creates workspace layout from workspace.env, links ai/, builds agent images, prepares compose profiles)

**Phase 2 — Data** (time depends on backup size):

4. Restore vault from backup / private Git remote.
5. Restore projects from backups or Git remotes.
6. Restore secrets from password manager or encrypted archive into `~/.secrets/`.
7. Re-pull local models from models.txt (optional).
8. `docker compose up` the needed profiles.

All infrastructure is version controlled. User data remains separate and is restored from backups. Secrets are restored from their dedicated off-machine source.

## AI Policies & Standards

The `ai/` directory is more than a folder — it is the engineering handbook: coding standards, architecture principles, workflows, prompts, and security policies, shared across every project and agent.

Examples: `coding-style.md`, `python-guidelines.md`, `go-guidelines.md`, `react-guidelines.md`, `security-checklist.md`, `architecture-principles.md`.

Mounted read-only into every container at `/ai`.

Integration: each project's AGENTS.md references the mounted policies:

```markdown
# AGENTS.md
Follow /ai/python-guidelines.md and /ai/security-checklist.md.
```

Agents pick these up automatically at session start — standards are written once, version controlled in the infrastructure repo, and shared across all projects.

## Sandbox

A dedicated workspace for experimentation.

```
sandbox/
├── experiments/
├── generated/
├── scratch/
└── temporary/
```

The AI is free to generate files here without cluttering real projects.

## Automation

Routine operations are executable with a single command. Scripts live in `infrastructure/scripts/` and source workspace.env.

| Script | Responsibilities |
|---|---|
| `bootstrap.sh` | Creates workspace directories. Restores symbolic links. Verifies dependencies. Builds agent images. |
| `backup.sh` | Commits Git changes. Creates compressed archives. Rotates old backups. |
| `health_check.sh` | Verifies Docker Engine and WSL. Verifies Git configuration. Verifies mounted paths and vault accessibility. (This IS the observability layer for a single-user workstation — no monitoring stack needed.) |
| `restore.sh` | Restores infrastructure, vault, projects, configuration. |

## Maintenance

Architecture isn't only about creation — it's about maintenance. The cadence is deliberately lean: a short schedule that runs beats a thorough one that doesn't.

**Weekly**

- Run backup.sh (if not automated).
- `docker system prune` (containers, dangling images).
- Glance at current_context.md — stale context misleads agents.

**Monthly**

- Update Ubuntu (`apt upgrade`) and Docker images.
- Review agent_inbox: promote or discard AI-created notes.
- Archive inactive projects → archives/.

**Quarterly**

- **Test full recovery**: restore vault + one project from backup into a clean location and verify. An untested backup is a hope, not a backup.
- Rotate credentials and API tokens.
- Review AI policies in ai/ for drift.

## Companion Documents

This document stays an architecture overview. Deep dives live in `infrastructure/docs/`, written as their subjects are implemented (implement first, document afterward):

- getting_started.md ✓ (written — see companion file)
- security.md
- backup-and-recovery.md
- local_models.md
- compose-profiles.md
- adr/ (decision records)

## Future Extensions

Potential future modules:

- MCP servers
- Local RAG over the vault (embeddings + vector-db, see Local AI Models)
- CI/CD integration
- Remote development workstations

The modular architecture allows these to be added without redesigning the workstation.

## Exploration Notes (Unvalidated)

Ideas gathered from external research — not decided, not implemented, not a commitment. Distinct from Future Extensions above: those are modules this architecture already has a clear slot for; these are raw candidates with an open question still attached to each one.

**Chat UI over local models.** A frontend for Ollama beyond raw API calls. Candidates: Open WebUI (chat-only) or AnythingLLM (chat + a bundled document RAG store). These overlap in purpose — pick one if this gets built, not both.

**Vector database for local RAG.** Chroma or Qdrant. Only relevant if the chosen chat UI doesn't already bundle one (AnythingLLM ships LanceDB by default) or if `vector-db/` — already stubbed under Local AI Models — ends up used by something other than the chat UI.

**Optional service candidates.** Postgres, Redis. Add only when a specific service actually requires one; don't pre-provision speculatively.

**Rough shape, if this ever gets built** — one path, not two: everything through Docker Compose (per ADR 0001), reached from a browser on Windows via WSL2's localhost forwarding. No competing "raw WSL, no Docker" version — that fork was already settled.

```
┌───────────────────────────────────────┐
│ Windows 11                             │
│                                         │
│  Chrome / Edge / Firefox                │
│        │                                │
│        ▼                                │
│  http://localhost:<port>                │
└─────────────┬───────────────────────────┘
              │
      WSL2 localhost forwarding
              │
┌─────────────▼───────────────────────────┐
│ WSL Ubuntu — Docker Compose              │
│ (infrastructure/compose/)                │
│                                           │
│  ┌─────────────────────────────────────┐ │
│  │ ollama.yaml     → Ollama             │ │
│  ├─────────────────────────────────────┤ │
│  │ hermes.yaml     → Hermes Agent       │ │
│  ├─────────────────────────────────────┤ │
│  │ chat-ui.yaml*   → Open WebUI         │ │
│  │                    — or —            │ │
│  │                   AnythingLLM        │ │
│  │                   (pick one)         │ │
│  ├─────────────────────────────────────┤ │
│  │ vector-db.yaml* → Chroma / Qdrant    │ │
│  │                   (only if the chat  │ │
│  │                    UI doesn't ship   │ │
│  │                    its own)          │ │
│  └─────────────────────────────────────┘ │
│                                           │
│  ${MODELS_DIR}   ${VAULT_DIR}            │
└───────────────────────────────────────────┘

* not yet built — candidates only
```

No profile, compose file, or ADR exists for any of this. Promote to a real appendix — following the Appendix B / Appendix C pattern (implement, validate in use, then document) — only once one of these is actually built and running.

## Overall Recommendation

```
Windows
    │
    ├── Codex / Claude Desktop
    │
    └──────────────┐
                   │
            WSL Ubuntu
                   │
            ├── Obsidian (runs inside WSL via WSLg)
            │
            ├── Docker Engine
            │
            ├── AI Container (compose profile: dev / docs /
            │                 review / sandbox)
            │      ├── Python
            │      ├── Node
            │      ├── Go
            │      ├── /workspace        (per profile)
            │      ├── /vault            (ro)
            │      ├── /vault/agent_inbox   (rw)
            │      └── /ai               (ro)
            │
            ├── Ollama Container (optional, GPU)
            │      └── model volume
            │
            ├── ~/workspace/
            │      ├── projects/
            │      ├── vault/
            │      │      └── personal/  (never mounted)
            │      ├── ai/
            │      ├── infrastructure/   (git: ai-workstation)
            │      ├── models/
            │      ├── backups/
            │      └── archives/
            │
            └── ~/.secrets/  (never mounted, never in Git)
```

## Benefits

- ✓ Fast Linux filesystem
- ✓ Persistent projects
- ✓ Disposable containers
- ✓ Compose-first: every environment is versioned YAML
- ✓ Explicit engineering principles and scope (goals/non-goals)
- ✓ Modular architecture
- ✓ Vendor-independent design
- ✓ Infrastructure as Code
- ✓ Container security profiles (least privilege per task)
- ✓ AI-assisted note creation with enforced review workflow
- ✓ Curated notes physically protected by mount flags
- ✓ Personal notes invisible to agents
- ✓ Organized knowledge base
- ✓ Agents boot with global context (orientation layer)
- ✓ Git-based backups with exact per-session audit diffs
- ✓ Quarterly-tested recovery
- ✓ Easy rollback
- ✓ Network isolation with scoped credentials
- ✓ Secret isolation with dedicated recovery source
- ✓ Shared Obsidian vault
- ✓ Single source of agent instructions (AGENTS.md)
- ✓ Shared engineering handbook (ai/) versioned in Git
- ✓ Decision rationale preserved in ADRs
- ✓ Reproducible development environments
- ✓ Self-contained projects
- ✓ Centralized infrastructure configuration
- ✓ One-command infrastructure bootstrap after clone
- ✓ Automated backup, restore, and health checks
- ✓ Portable workspace layout (manifest-driven paths)
- ✓ Consistent naming conventions
- ✓ Clear separation between configuration, state, artifacts, and secrets
- ✓ Local-model-ready (GPU passthrough, model manifest)
- ✓ Easy migration to new machines
- ✓ Easy migration to new AI agents
- ✓ Easy replacement of Docker or Obsidian
- ✓ Scalable to multiple AI agents
- ✓ Future-ready architecture
- ✓ Minimal vendor lock-in

## Appendix A: docker run Equivalents

Compose profiles are the primary interface. For quick one-offs, the equivalent docker run commands:

**Development profile:**

```bash
docker run -it \
    --env-file ~/.secrets/myapp.env \
    -v ~/workspace/projects/myapp:/workspace \
    -v ~/workspace/vault:/vault:ro \
    -v ~/workspace/vault/agent_inbox:/vault/agent_inbox \
    -v ~/workspace/ai:/ai:ro \
    agent-image bash
```

**Code Review profile:**

```bash
docker run -it \
    --network none \
    -v ~/workspace/projects/myapp:/workspace:ro \
    -v ~/workspace/vault:/vault:ro \
    -v ~/workspace/vault/agent_inbox:/vault/agent_inbox \
    -v ~/workspace/ai:/ai:ro \
    agent-image bash
```

If a docker run invocation is used more than twice, promote it to a compose profile.

## Appendix B: AI Orientation Layer

*(Inspired by Linking Your Thinking's AI OS. Status: pending validation in use — promote details into the core spec only after they survive a few weeks of real sessions.)*

### Purpose

The core architecture defines **how the environment is built**. The orientation layer defines **how an AI understands it**: who the user is, how the workspace is organized, where knowledge lives, and what matters right now.

Instead of every session rediscovering the workspace, agents boot from four small, human-maintained files.

### The Four Files

**`me.md`** — Location: `ai/` (config, versioned, ro)

Engineering brief about the user: current goals, preferred languages and tools, coding philosophy, communication preferences. NOT a personal diary — it is mounted into every container, so it contains only what any agent should know. Deeply personal material stays in `vault/personal/`, which agents never see.

**`workspace_map.md`** — Location: `ai/` (config, versioned, ro)

Navigation guide for agents: for each top-level directory, its purpose, what the agent may touch, and typical contents. Includes two lines of tool intent (e.g. "Ollama for local inference; Claude Code is the primary agent"). One page, hard limit. This is a **navigation** guide, not a copy of the architecture doc's layout section.

**`skill_map.md`** — Location: `vault/` (state, backed up, ro)

Index of engineering knowledge: one line per domain (Docker, Python, Go, Security, AWS, ...) linking to the detailed notes inside the vault. Lives in the vault because its links point into the vault. Lets agents jump to expertise instead of crawling thousands of notes.

**`current_context.md`** — Location: `vault/` (state, mutable)

Five lines, no more:

```
Priority this week:
Active project:
Blocked by:
Avoid touching:
Notes:
```

Deliberately excludes anything git already answers (current branch, recent changes) — agents get those from git itself. A stale context file misleads agents worse than no file, hence the weekly glance in Maintenance.

**Rejected candidates (and why):**

- `standards.md` — a pointer to pointers; AGENTS.md already references /ai/ policies (ADR 0003).
- `tool-registry.md` — static tool lists go stale silently; agents discover tools with `which`. Intent lines live in workspace_map.md instead.

### The Boot Sequence

Files don't read themselves. Each project's AGENTS.md opens with one hook line:

```markdown
# AGENTS.md
Before starting, read /ai/me.md, /ai/workspace_map.md,
and /vault/current_context.md. Consult /vault/skill_map.md
when you need background knowledge.
<project-specific instructions follow>
```

Global context loads first; project context refines it. (If the agent supports a global config, put the hook there once instead of repeating it per project.)

### Relationship to the Core Architecture

| Layer | Answers |
|---|---|
| Core architecture | How is the environment **built**? (containment, mounts, profiles) |
| Orientation layer | How should an AI **understand** it? (identity, navigation, focus) |

The containment layer stays exactly as specified: orientation files are ordinary markdown under the existing mounts (`ai/` ro, `vault/` ro) and change nothing about permissions, profiles, or backups. Swapping the AI tool (Claude Code → Codex → local model) leaves the orientation layer untouched — it is plain markdown, readable by anything.

## Appendix C: Local Agent Stack (Hermes + Ollama)

*(Status: pending validation in use — promote details into the core spec only after real sessions confirm the setup. Same discipline as Appendix B.)*

### Purpose

Claude Code, run through the `dev.yaml` profile, isolates the agent from **personal data** (vault/personal/, secrets) but still calls out to `api.anthropic.com` — the model itself runs off-machine.

Hermes Agent + Ollama solves a stricter, different problem: **zero network dependency for the agent loop itself.** Once a model is pulled, prompts, code, and session memory never leave the box. This is a second tier, not a replacement — the two exist for different jobs:

| Tier | Solves for | Trade-off |
|---|---|---|
| Claude Code (`dev.yaml`) | Isolation from personal data; best reasoning quality | Requires network to `api.anthropic.com` |
| Hermes + Ollama (`hermes.yaml`) | Zero network dependency; zero token cost | Weaker reasoning on complex multi-step tasks; slow without a GPU |

Use Hermes for boilerplate, quick edits, and exploratory work where privacy-from-the-network or cost matters more than depth. Keep Claude Code for anything needing real multi-step reasoning.

### Hardware Placement — Read This Before Choosing a Host

Ollama on CPU is slow: roughly 10 tok/s for a 9B model on a modern 8-core CPU, dropping to 2–5 tok/s for a 30B model (30–120 seconds per response). Hermes also requires **≥64K context** or it refuses to start, adding real memory pressure on top of model weights.

**This pairs well with a discrete GPU and poorly with a low-power headless node** (Raspberry Pi, budget laptop CPU) — do not run this on the same box as the isolated Claude Code dev node.

**Recommended host: a revived idle machine, not a new purchase.** A 2013 workstation (Intel Core i7-3770K, 4C/8T, 3.5GHz/4.0GHz turbo; MSI Z77A-G41 motherboard) already sits unused. The Z77 chipset gives the CPU's 16 PCIe lanes at Gen3 — a modern GPU in the top slot runs at full bandwidth despite the platform's age, and single-GPU inference is GPU-bound, not CPU-bound, so this pairing is genuinely viable, not a compromise. Reusing it also sidesteps nearly all of the 2026 DRAM/NAND price crisis (see earlier hardware discussion): the only new purchases are a GPU and a modest DDR3 kit — legacy DDR3 sits outside the DDR4/DDR5/NAND shortage entirely.

**Phase 1 — get it running now:**

1. Update the Z77A-G41 to the latest BIOS before installing any new hardware.
2. Replace RAM: install a 32GB DDR3 kit (4×8GB), removing the old 4×4GB sticks; enable XMP for 1600MHz.
3. Install an 8GB RTX 2060 Super in the top PCIe slot. Verify authenticity with GPU-Z (TU106, 2176 cores) before trusting it — this matters more for lesser-known rebrand listings than for a mainstream-brand card, but worth doing either way.
4. Run headless with Ollama or llama.cpp — 7B–8B models fully in VRAM at that point.

**Phase 2 — expand later, only if actually needed:**

5. Replace the original PSU (13+ years old — the clear weakest link for 24/7 duty) with a quality 750W unit carrying four PCIe 8-pin connectors (~$70–90).
6. Add a second 8GB Turing-or-newer GPU for layer-split inference; 16GB combined VRAM opens up 13B–14B models.

**Optional, low-priority:**

7. A cheap SATA SSD (~$25 / 500GB) for OS and model storage — the original 2013 HDDs are both slow and the most likely component to fail.
8. Dust the case and repaste the CPU cooler — over a decade old and due regardless of the rest of this plan.

Phase 1's real cost is the GPU plus roughly $40 of RAM — everything else (case, PSU for now, cooler, motherboard, CPU) is already owned and otherwise idle.

### Model Choice

| Hardware budget | Model | Notes |
|---|---|---|
| 24GB+ VRAM/RAM | Qwen 2.5-Coder 32B | Best coding quality available locally |
| 16GB | Gemma 4 12B | Best speed/quality balance |
| 8GB minimum | Llama 3 8B | Usable; noticeably weaker on multi-step agentic tasks |

Not all local models support reliable tool/function calling — stick to a confirmed tier-1 model (the Qwen family is consistently recommended) or expect flaky tool use.

### Compose Profile

```yaml
# infrastructure/compose/ollama.yaml
services:
  ollama:
    image: ollama/ollama
    volumes:
      - ${MODELS_DIR}/ollama:/root/.ollama
    environment:
      - OLLAMA_KEEP_ALIVE=-1        # avoid reload latency between turns
    # GPU passthrough (desktop host only):
    # deploy:
    #   resources:
    #     reservations:
    #       devices:
    #         - driver: nvidia
    #           count: 1
    #           capabilities: [gpu]
```

```yaml
# infrastructure/compose/hermes.yaml
#
# First pass: prove Ollama connectivity works at all, using Hermes's
# own official image and native persistence. Vault/workspace mounts
# — the pattern every other profile uses — are deliberately NOT
# added here yet; see "Extending Hermes to the Vault" below for why.
services:
  hermes:
    image: nousresearch/hermes-agent
    volumes:
      - ${SECRETS_DIR}/hermes-home:/opt/data
    stdin_open: true
    tty: true
    # depends_on deliberately removed — config.yaml's base_url may
    # point at this local Ollama or a remote one (a second machine's
    # GPU over the LAN). A hard dependency would force starting a
    # local Ollama container even when unused. Include -f ollama.yaml
    # in the run command only when actually using the local endpoint.
```

Configuration happens interactively, not through environment
variables — there is no `OLLAMA_BASE_URL` or equivalent to set in the
compose file itself:

```bash
# first run only — the setup wizard
docker compose --env-file ../workspace.env -f hermes.yaml run --rm hermes setup

# point it at Ollama (same compose network, so the service name
# resolves — not localhost, which only works same-container)
docker compose --env-file ../workspace.env -f hermes.yaml run --rm hermes model
#   → choose "Custom endpoint (self-hosted / VLLM / etc.)"
#   → URL: http://ollama:11434/v1
#   → skip the API key — Ollama doesn't need one
#   → model name: whatever was pulled into the ollama service
```

Leave `terminal.backend` at its default (local), not `docker`, for
this first pass. Setting it to `docker` gives Hermes its own sandbox
for shell commands — genuinely useful eventually, but it requires
mounting the Docker socket into Hermes's container, which is the
exact privilege-escalation concern already flagged and deliberately
parked in `features.md`'s Possible (Speculative) section. Don't
reintroduce that risk while just trying to prove the basic wiring
works.

**Extending Hermes to the vault** (a deliberate second step, not
part of getting it running): once Ollama connectivity is confirmed,
the same per-subfolder mount pattern every other profile uses can be
added — `${VAULT_DIR}/programming:/vault/programming:ro`, etc.,
`personal/` never listed, same as `dev.yaml`. Not attempted in the
first pass, on purpose — stacking "does Hermes talk to Ollama at
all" together with "does Hermes correctly respect vault boundaries"
makes a failure impossible to attribute to either cause.

Same mount pattern as every other profile: workspace read-write, vault read-only with the inbox overlay, `/ai` read-only, personal/ and secrets never mounted. The only new property this tier adds is `network_mode: "none"` by default — genuinely offline, not just isolated from personal data.

### Model Blobs

Per [Configuration vs State](#configuration-vs-state): model blobs pulled via `ollama pull` are reproducible artifacts, **not backed up**. `models.txt` in `models/` is the backup — the list of model names/tags, not the multi-GB weights themselves.

### Relationship to the Core Architecture

Nothing about the containment model changes. Hermes and Ollama are two more compose services following the exact mount and network rules every other profile follows — this appendix documents a specific pairing, not a new mechanism.
