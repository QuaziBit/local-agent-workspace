# AI Dev Environment — Project Handoff Report
*Prepared for starting a fresh chat with full context.
Supersedes the report — adds the docker-backend migration
tooling and the one-click bootstrap/test/check_all targets.*

## What this project is

A Docker/WSL2-based multi-agent development environment: a local
Obsidian vault as the knowledge base, Claude Code and Codex CLI as
the coding agents, and Hermes (a local-model-driven orchestrator) as
the layer that can delegate to either — or both — on request. Runs
on a Windows 11 laptop (WSL2) as the primary machine, with an
optional Windows 10/11 desktop as a second Ollama host reachable
over the LAN. Everything authenticates via existing subscriptions
(Claude Max, ChatGPT Plus) — no API keys, no per-token billing.

The whole thing is a real, git-tracked repo (27+ commits, local
git only — no hosted remote, by choice; this is a personal
learning project, not a production system). Current stated
priority: the workspace must be easy to set up and usable right
away — CI, scanning, and production-hardening are consciously
deferred.

## Current status: fully proven — and now fully *reconciled*

Every piece of the intended architecture has been built, tested on
real hardware, and documented, including two full disaster-recovery
drills. New since the last report: a audit cross-checked
`testing_plan.md` against the actual `setup.sh` / `setup.bats` /
`run.sh` / `tasks.json` and found the plan was badly behind reality —
lots of completed work was never ticked. That's now fixed (see "The
 reconciliation" below). Live re-verification the same
day: `setup.sh` clean, `--verify` 28/0, `bats` 93/0, health 50/0.
Then on two tooling batches landed (see below), moving
the live expectations to: --verify 29/0, bats 104/0, 28 VS Code
tasks — none of it yet run on the real machine (`run.sh check_all`
is the one-command way to prove the whole batch).

**The complete Hermes profile matrix (8 of 8), all confirmed:**

| Profile | Form | Providers | Status |
|---|---|---|---|
| `hermes` | ephemeral | none (local model only) | confirmed |
| `hermes_claude` | ephemeral | Claude Code | confirmed |
| `hermes_codex` | ephemeral | Codex | confirmed |
| `hermes_all` | ephemeral | **both**, combined image | confirmed |
| `hermes_dashboard` | persistent | none | confirmed |
| `hermes_dashboard_with_claude` | persistent | Claude Code | confirmed |
| `hermes_dashboard_with_codex` | persistent | Codex | confirmed |
| `hermes_dashboard_with_all` | persistent | **both**, combined image | confirmed |

The combined (`_all`) profiles were proven with an **interleaved**
test — `claude`, then `codex`, then `claude` again, in one continuous
session — specifically to catch cross-provider interference that
testing each alone couldn't. All clean, no login prompts, no
interference. The dashboard variant was confirmed reached remotely
via the native Windows Hermes app.

**Plus, separately proven:**
- The direct-CLI "agent tier" (`dev`/`docs`/`review`/`sandbox`):
  all four profiles, full mount-boundary sweep, real work task
  completed.
- Desktop-as-second-Ollama-host: full multi-machine matrix, both
  providers delegate correctly with the desktop driving Hermes,
  runtime model switching, local↔desktop switching.
- The bootstrap/rebuild story: `setup.sh` builds the whole
  workspace from nothing; `--verify` catches drift; `--secrets-only`
  rebuilds just the credential store; both "wipe everything,
  rebuild from the runbook" drills passed — and Run 2's completion
  is now *evidenced*, not just claimed (see next section).

## The reconciliation (new)

`testing_plan.md`'s checkboxes had fallen far behind the actual
work. The audit resolved this:

- **Run 2 (scorched earth) was genuinely completed** but its boxes
  were never ticked — the "NOT YET DONE" login steps actually
  happened on Aug 2. Evidence: `claude-home/.credentials.json`
  (Aug 2 21:03) and `codex-home/auth.json` (Aug 2 12:50) both on
  disk with post-wipe timestamps, matching the same-day
  no-login-prompt interleaved delegation tests (impossible without
  completed logins) and the dashboard basic_auth login (impossible
  without a recreated hermes-home).
- **Stale counts fixed**: the plan said 20 embedded files (actual:
  28 = 24 `create_file_if_missing` + 4 orientation scaffolds,
  asserted by a bats test) and 57 bats tests (actual: 93);
  `quick_reference.md` said 82 tests (also fixed to 93).
- **§1.2's "manual file drops" step marked SUPERSEDED** —
  `run.sh`, `tasks.json`, and the hermes_codex files are all
  embedded in `setup.sh` now; nothing needs hand-dropping.
- **`run.sh dashboard_auth`** now automates the password-hash half
  of hermes-home recreation, which the plan's "by hand" item
  predated.

**Three corrected doc files are staged, ready to drop into the
repo** (produced may or may not be applied yet — check):
`testing_plan.md` (reconciled, with the evidence written into the
Run 2 section and a "what's actually still open" summary),
`quick_reference.md` (82→93), and `features.md` (two new entries —
see Open items below).

**After reconciliation, only three test items remain open, all
small:** Obsidian under WSLg (never tried, no dependencies); a
one-line comment fix (`hermes_dashboard_with_codex.yaml` still
calls the git-trust flag "an open item" though it was decided
 — `hermes_codex.yaml` records the decision); and the
likely-moot fragment audit (fragment set was superseded; an `ls`
of agent_inbox closes it formally).

**One doc-gap still unfixed (worth doing):** the
`templates/AGENTS.md` copied into every new project still says
`/vault/00-inbox` and "lowercase-with-hyphens" — both stale since
the v1.13/v1.14 decisions (path renamed to `agent_inbox`,
snake_case adopted project-wide).

## The tooling (`run.sh` + `setup.sh` + `tasks.json`)

- `run.sh` is the single entry point. Targets:
  `hermes`/`hermes_claude`/`hermes_codex`/`hermes_all` (ephemeral),
  `dashboard`/`dashboard_claude`/`dashboard_codex`/`dashboard_all`
  (persistent), `dev`/`docs`/`review`/`sandbox` (direct CLI),
  `models`/`pull` (Ollama management, auto-pulls via
  `ensure_model`), `dashboard_auth` (password hash, terminal-only
  since VS Code can't mask input), `down`/`ollama_down`,
  `docker_clean` (confirm-then-prune), `health`/`drift`/`ps`.
  `--remote-ollama` switches any target to the desktop's Ollama.
- `setup.sh --verify`: 29 embedded files tracked (28 live-confirmed
 + the migration script added).
  `--secrets-only` rebuilds just `~/.secrets`.
- `.vscode/tasks.json` — 28 one-click VS Code tasks wrapping
  `run.sh` (22 live-confirmed + 6 added three Docker
  backend tasks, plus Workspace bootstrap / test suite / check all).
- Test suite: 104 bats tests (93 live-confirmed; 11
  added for the migration tooling and one-click targets).
- New `run.sh` targets (none yet run live):
  `docker_status`/`docker_migrate`/`docker_revert` (wrapping
  `scripts/migrate_docker_backend.sh` — reversible Desktop ↔ native
  docker-ce switch, refuses while the Desktop shim owns the PATH,
  --revert uninstalls nothing and a bats test enforces that), and
  `bootstrap`/`test`/`check_all` (setup.sh re-run, the bats suite,
  and the health+drift+test sweep — the local stand-in for CI).

## Real findings worth knowing (the hard-won debugging gold)

- **`claude -p` won't write files non-interactively without
  `--permission-mode acceptEdits`** — silently waits for approval
  nobody can give. Applies to Hermes-delegated Claude write tasks
  too.
- **`codex exec` needs `--sandbox workspace-write`** to write —
  its default is TTY-dependent, not fixed.
- **`codex exec` needs `--skip-git-repo-check`** for scratch/
  non-repo directories (real `git init`-ed projects don't).
- **Hermes's terminal tool chokes on raw `&&` chains** — wrap in
  `bash -c "cmd1 && cmd2"`.
- **`claude -p` has no offline self-timeout** — hangs forever with
  no network; wrap in `timeout` for anything that might run
  offline.
- **`hermes-home`'s config.yaml has no seeded default** — after a
  wipe, Hermes silently falls back to a stale bundled template,
  which is why the setup wizard fires inconsistently.
- **`hermes setup` rewrites config.yaml wholesale**, wiping
  `dashboard.basic_auth` — always run `hermes setup` before
  `dashboard_auth`, never after.
- **`CLAUDE_CODE_OAUTH_TOKEN` is a one-time bootstrap key only** —
  once `.credentials.json` exists, Claude Code renews itself and
  never reads the env var again (proven by deliberately breaking
  it). The credential is ordinary portable data: no OS-keychain
  tier on Linux; moving the files out breaks login, moving them
  back restores it. Gotcha: if both `ANTHROPIC_API_KEY` and the
  OAuth token are set, the API key silently wins — metered billing
  with no warning.
- **Claude Code defaults to its most expensive model** — override
  via `~/.secrets/claude-home/settings.json` (`{"model":
  "sonnet"}`); picked up on next run, no restart.
- **Hermes delegation runs default to `/opt/hermes` as cwd** —
  pass `workdir=` explicitly or delegated tasks operate on the
  wrong files.
- **Local-model fabrication risk (serious):** `gemma4:e2b` once
  returned a complete, confident "result" for a delegation against
  a container that had NO claude binary at all — it was a recalled
  prior response presented as fresh execution, not an error. Any
  Hermes-reported result that conveniently matches earlier session
  content needs independent verification.
- **Upstream Hermes bug (#35025):** any non-default PUID makes the
  boot hook re-chown every Hermes-managed dir on EVERY start — with
  `run --rm`, every launch pays it. Works fine, just slow starts.
- **Bubblewrap sandbox nesting degrades gracefully** — Codex falls
  back to its bundled copy with a warning.

## Where things live

The real repo (shared as `ai_env.zip`) — a restructure to
`infra/`+`docs/`+`references/`+`_archive/` was proposed (with a
tested `git mv` script) but still not applied; currently the
original layout:

- `scripts/` — `setup.sh`, `run.sh`, `setup.bats`,
  `.vscode/tasks.json`, plus `extra/` (diffable copies of every
  compose file and Dockerfile) and `config_example/`.
- `notes/ai_env_notes/main/` — all the docs: `readme.md` (start
  here), `getting_started.md` (bootstrap runbook),
  `testing_plan.md` (reconciled — apply the staged
  version), `features.md` (living backlog — apply the staged
  version), `hermes_operations.md` + `agent_tier_operations.md` +
  `local_models.md` (deep references), `quick_reference.md`
  (cheat sheet — apply the staged version), `workflows.md`,
  `architecture.md` (ADRs; changelog reaches v1.14 though its own
  header table lags at v1.12 — known inconsistency),
  `authentication.md` + `first_login_runbook.md`, `finding.md`.

## Open items (nothing blocking)

- **Docker Desktop → native docker-ce migration (NEW, in
  features.md Open):** move the stack to docker-ce inside WSL2
  Ubuntu for fewer standing apps; Docker Desktop stays installed
  (needed for other use) and its stack copies get purged only
  after the native path proves itself. Full six-step sequence
  written into the entry, including: disable Desktop's WSL
  integration first; `nvidia-container-toolkit` IS required with
  native docker-ce (the "no toolkit needed" note in `ollama.yaml`
  was Desktop-specific); all state survives in bind mounts (no
  re-logins, no model re-downloads). **Hard constraints:** gated
  until the current test pass is finished, and the Docker Desktop
  path must remain available — a reversible switch, nothing may
  come to depend on docker-ce specifics; the switch-back recipe is
  in the entry. `run.sh`/`tasks.json` need zero changes either way.
- **Few-clicks setup (NEW, in features.md Possible, explicitly
  "not now"):** if the FastAPI inspector ever gets built, add a
  guided first-run flow (wizard or `run.sh first_run`) collapsing
  the manual login steps. Depends on the inspector existing first.
- Session-capture convention for the vault — still undecided,
  deliberately deferred until after the first real Claude Code
  session shapes it.
- VPS: fully pre-decided on paper, gated on the
  desktop-dashboard-via-SSH-tunnel rehearsal — neither started.
- Obsidian under WSLg — never actually tried.
- FastAPI workspace inspector — speculative, not started.
- rclone+crypt → Google Drive backup (`run.sh backup`) — shape
  decided, not built.
- Deliberately deferred: small-balance ($5) API-key trials, and
  Hermes-side `CLAUDE_CODE_OAUTH_TOKEN` as an alternative to
  file-based credential mounts.
- Small fixes queued: the `templates/AGENTS.md` staleness
  (00-inbox path + hyphen naming), the
  `hermes_dashboard_with_codex.yaml` comment alignment, the
  architecture doc's header-version lag.

## How to pick this back up in a new chat

Paste this report in, plus (ideally) the actual `readme.md` and the
**reconciled** `testing_plan.md` if you want full fidelity — this
report is a faithful summary but those files are the real source of
truth. First things to check in a new session: whether the staged files got
applied to the repo (five code files: setup.sh, setup.bats, run.sh,
tasks.json, migrate_docker_backend.sh — plus four docs:
testing_plan, quick_reference, features, this report), whether the
first live `run.sh check_all` has been run (expected: --verify 29/0,
bats 104/0), and whether `docker_migrate` has been attempted yet
(it shouldn't be, until the test pass is banked). From there, a fresh Claude should be able to orient
immediately: what's proven, what's still open, and where the sharp
edges are.
