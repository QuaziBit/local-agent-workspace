# README — Start Here

This project is a Docker/WSL2 multi-agent dev environment: local and
desktop Ollama models, Claude Code and Codex CLI delegation through
Hermes (chat and dashboard forms), and a direct-use tier for hands-on
dev/docs/review/sandbox work — all sharing one Obsidian vault with
enforced mount boundaries. Confirmed working end to end, including
full from-zero rebuilds on two separate machines.

**If you only read one thing, read `quick_reference.md`. If you want
it even shorter, read `cheatsheet.md`.** Everything else here goes
deeper on some specific angle of it.

## By what you're trying to do

**"I just want to run something."**
→ `quick_reference.md` — every command, one page.
→ `cheatsheet.md` — the same, cut down to one line each, no reading required.

**"I know what I want to do, but not which tool to reach for."**
→ `workflows.md` — organized by intent (write a note, do dev work,
review code, work offline, combine Claude + Codex, switch
machines...) rather than by tool.

**"I'm setting this up on a new or wiped machine."**
→ `setup.md` — `init.sh` (fresh-machine bootstrap) and first login
for Claude Code + Codex, the fast path for both.

**"I want to bring a real project in and work on it."**
→ `projects.md` — the `dev`/`docs`/`review`/`sandbox` tiers (you
drive the CLIs directly) vs. `--project=<name>` (Hermes chat drives
it) — what each needs, and the write-path rules that differ between
them.

**"How exactly do I phrase a delegation so it actually runs?"**
→ `delegation_phrasing.md` — the exact trigger templates, copy-paste
search+write examples for all three tools (local model, Claude,
Codex), and the verification rules (never trust the reply text —
`cat` the file).

**"Something's broken, or I want to know how a specific piece works."**
→ `hermes_operations.md` — the six Hermes profiles (chat + dashboard,
Claude/Codex/both), the port-9119 conflict, web search backend
selection and its limitations (ddgs is search-only — don't trust it
for weather/live data).
→ `agent_tier_operations.md` — the four direct-use profiles, mount
boundaries, the secrets-env guard, offline/write-permission findings.
→ `local_models.md` — Ollama setup, the full Codex sandbox
debugging history (seccomp/bubblewrap root cause and fix), the
verification hazards this project has actually hit.

**"Am I allowed to run this on subscription auth, or do I need API keys?"**
→ `account_safety.md` — the ToS line, why this stack is on the safe
side of it, and the rules that keep it there.

**"I want to know what's actually proven vs. still open."**
→ `features.md` — the living backlog: Resolved (what's done and
how, with the real debugging trail), Open (loose ends), Possible
(speculative ideas not started).

**"I want the history — why things are built this way, or the full
manual build steps."**
→ `reference/ai_dev_environment_architecture.md` — the original
architecture doc, ADRs, and full changelog of design decisions.
→ `reference/getting_started.md` — the literal longhand runbook
`setup.sh` now automates; only worth opening if you don't trust or
can't use `setup.sh` itself.
→ `_archive/` — superseded snapshots and one-off historical audit
notes, kept for the record but not day-to-day reading.

## The actual scripts (not docs, but load-bearing)

- `setup.sh` / `setup.bats` — the bootstrap script and its test
  suite. `setup.sh --verify` checks the live tree against what's
  embedded; `setup.sh --secrets-only` rebuilds just `~/.secrets`.
- `run.sh` — the day-to-day runner every guide above tells you to
  use instead of typing `docker compose` by hand.
- `init.sh` — run this FIRST on a new machine; see `setup.md`.
- `smoke_test.sh` — one command, checks the sandbox/search stack
  actually works on a live container right now (not whether the
  tree is bootstrapped — that's `health_check.sh`, run via
  `run.sh health`).
- `.vscode/tasks.json` — the same `run.sh` targets, reachable from
  VS Code's task picker.

## A note on trust

Not everything documented here is equally proven, but the important
things are: the Codex sandbox fix, `ddgs` search, per-item
`docker_clean`, the vault's read/write boundaries, and all four
project tiers have each been host-verified — not just written
down — with the evidence trail in `features.md`'s Resolved section
and `local_models.md`. If a doc claims something works, that's
where to check it was actually proven.
