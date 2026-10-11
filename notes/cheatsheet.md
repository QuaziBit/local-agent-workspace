# Cheat Sheet — No Reading Required

Every command you actually need day to day. Nothing else. If a line
here isn't enough, the doc it points to has the full story — but you
shouldn't need to open it.

## Just start

```bash
run.sh                       # interactive menu, when in doubt
run.sh hermes_claude          # chat + Claude Code delegation
run.sh dashboard_claude       # same, but browser + stays running
```

## Delegating inside a Hermes chat — copy these EXACTLY

```
Use your terminal tool to run: claude -p "<task>"
Use your terminal tool with pty=true to run: codex exec --skip-git-repo-check "<task>"
```
Anything softer than this ("use claude to...") gets talked about, not
run. **These trigger phrasings only — add `--permission-mode
acceptEdits` (claude) / `--sandbox workspace-write` (codex) if the
task needs to WRITE anything, or it silently does nothing.**
Full templates + copy-paste examples: `delegation_phrasing.md`

## Working on a real project (Hermes can't see project files — this is)

```bash
run.sh dev <project>
claude -p --permission-mode acceptEdits "<task>"      # or just `claude` interactively
codex exec --sandbox workspace-write "<task>"
```
→ `projects.md`

## Vault vs. projects

Who can write, and what kind of content lives there:

- **`vault/`** — shared knowledge, read-only to agents except
  `agent_inbox/` (the sole writable path — capture goes here).
  `personal/` isn't mounted at all. The project's memory: durable,
  curated, agent-readable.
- **`projects/`** — actual code, read-write in `dev` (read-only in
  `review`). Where agents actively work: editing, building,
  committing. The workbench, not the archive.

**Two different `projects/` — don't confuse them:**
- `vault/projects/` — curated, READ-ONLY notes *about* projects
  (design docs, decisions, retrospectives)
- `~/workspace/projects/` — the actual CODE, read-write in `dev`

**The flow:** work happens in `~/workspace/projects/<name>/` → worth
keeping? → `agent_inbox` → triaged later into `vault/projects/` (or
`ideas/`, `research/`) as durable reference. One's the workbench,
one's the filing cabinet.

## Is everything OK?

```bash
run.sh check_all             # health + drift + full test suite, one shot
bash init.sh --check         # new/rebuilt machine — reports, changes nothing
```

## Switch which Docker is running the stack

```
Toggle OFF (Desktop) + run.sh docker_migrate   → native (daily driver)
Toggle ON  (Desktop) + run.sh docker_revert    → Win Docker (revert FIRST, then toggle)
run.sh docker_status                            → "Daemon:" line = the truth
```

## New or broken machine

```bash
bash init.sh                 # fixes the first thing wrong, tell it to continue, repeat
```
→ `setup.md`

## Still stuck?

`quick_reference.md` (full command list) · `workflows.md` ("what do
I reach for") · `features.md` (what's actually proven, and what's still open).
