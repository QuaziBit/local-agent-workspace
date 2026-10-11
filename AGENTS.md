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
