# Quick Reference — Running Everything

One page, no explanations of *why* — just what to type. For the
reasoning behind any of this, see `hermes_operations.md`,
`agent_tier_operations.md`, and `local_models.md`.

## Before anything

```bash
docker ps                                     # anything already running?
~/workspace/infrastructure/scripts/run.sh health # health checks, should all be OK (67)
```

## The chat tiers (Hermes — a local/remote model driving, delegates on request)

```bash
run.sh hermes            # local model only, no delegation, fully private
run.sh hermes_claude      # + can delegate coding tasks to Claude Code
run.sh hermes_codex       # + can delegate coding tasks to Codex
run.sh hermes_all         # + BOTH Claude Code and Codex
```
All three: ephemeral, gone when you exit. Add `-r` /
`--remote-ollama` before the target to use the desktop's Ollama
instead of the laptop's.

Inside any of these, to actually delegate, be explicit — bare
`claude -p "..."` gets chatted back at, not executed:
```
Use your terminal tool to run: claude -p "<task>"
Use your terminal tool with pty=true to run: codex exec --skip-git-repo-check "<task>"
```
Trigger phrasing only — add `--permission-mode acceptEdits` (claude)
/ `--sandbox workspace-write` (codex) for any task that needs to
WRITE, or it silently does nothing. Full copy-paste examples:
`delegation_phrasing.md`. Wrap multi-command shell chains:
`bash -c "cmd1 && cmd2"` (Hermes's terminal tool errors on a raw `&&`).

**Some Hermes builds also have `delegate_task` + named skills**
(`'claude-code'`, `'codex'`) as an alternative to the terminal-tool
pattern above — async background execution, same write boundary
underneath. Confirmed on both `hermes_all` and `dashboard_all`. See
`delegation_phrasing.md`'s Additions section for the full findings,
including a caught-and-diagnosed fabrication pattern with a concrete
avoidance (always give the full absolute destination path). Also
worth knowing: `config.yaml`'s `terminal: cwd:` (defaults to `.`)
can be set to `/vault/agent_inbox` so plain writes don't need
`workdir=` spelled out every time — same doc.

## The standing dashboard (same as above, but always-on + reachable remotely)

```bash
run.sh dashboard           # local model only
run.sh dashboard_claude    # + Claude Code delegation
run.sh dashboard_codex     # + Codex delegation
run.sh dashboard_all       # + BOTH providers
run.sh down                # stop whichever one is running
```
Open `http://localhost:9119` (browser or the native desktop app).
Only one of the three can run at a time (same port). Auth is
mandatory — see "One-time setup" below if you haven't set a
password yet.

## Direct tier (you type `claude`/`codex` yourself, no Hermes in the loop)

```bash
run.sh sandbox              # throwaway scratch space, no vault, no project
run.sh dev <project>        # full project work, vault read-write on agent_inbox
run.sh docs <project>       # offline file/doc work (no network — AI CLIs can't reach out)
run.sh review <project>     # read-only project, offline — audit without risk of changing anything
```
`dev` needs `~/.secrets/<project>.env` to exist first (`touch` it,
empty is fine) — the runner tells you if it's missing.

Inside `dev`, for the CLIs to actually **write** files:
```
claude -p --permission-mode acceptEdits "<task>"
codex exec --sandbox workspace-write "<task>"
```
(A real project directory already has its own `git init`, so
neither CLI's git-trust flags are needed there.)

## Web search (`web_search` / `web_extract`)

```yaml
# ~/.secrets/hermes-home/config.yaml
web:
  backend: "ddgs"     # free, no key — search only, no extraction
```
`ddgs` gets Hermes real search results without the browser tool
(which fails in this containerized setup — no Chrome to attach to).
**Limitation: search only.** No `web_extract`, and don't trust it
for anything time-sensitive (weather, live scores/prices) — it
answered a weather question with the wrong day's forecast because
there's no live-page read behind it, only a search snippet. Use a
real API for that instead. Full story, backend options, and the
`uv`-not-`pip` install gotcha: `hermes_operations.md` §10.
Copy-paste search+write examples, all three tools: `delegation_phrasing.md`.

## Updating the tools

```bash
run.sh update ollama       # pull the newest image, recreate the container (models kept)
run.sh update claude       # no-cache rebuild of every image with Claude Code
run.sh update hermes       # pull the Hermes base image, rebuild images built on it
run.sh update codex        # CHECK ONLY: pinned vs latest, plus the bump steps
run.sh update all          # ollama + claude + codex check (hermes is never included)
```
Models, logins and the vault live outside the images, so none of this
touches them. Running containers keep the old image until stopped and
relaunched (`run.sh down`, then your usual target). Run
`smoke_test.sh` after `update hermes` — upstream `:latest` can break.
Codex is pinned on purpose; bumping it is a deliberate edit, not an
update.

## Ollama / model management

```bash
run.sh models              # what's pulled on the currently-configured endpoint
run.sh pull                # pull gemma4:e2b (the default)
run.sh pull <model>         # pull something else
```
Inside any Hermes session, switch models without touching any file:
```
/model                      # opens the picker
/model <name> --global      # switch AND persist across future sessions
```
Switching the *provider* (local vs. desktop) still means editing
`~/.secrets/hermes-home/config.yaml`'s `model.provider:` line to
`custom:Ollama-Local` or `custom:Ollama-Desktop` — no zero-edit
switch for this part yet.

## One-time setup (only needed once per fresh `~/.secrets`)

```bash
bash setup.sh --secrets-only        # seed empty ~/.secrets structure
run.sh sandbox                       # then, inside:
claude                                #   normal browser login
codex login --device-auth             #   device-code login
exit
hermes setup                          # inside `run.sh hermes` (plain profile):
                                       #   Full setup -> Custom endpoint ->
                                       #   http://ollama:11434/v1 -> Chat Completions
```
Dashboard password (separate from the above):
```bash
docker compose --env-file ../workspace.env -f ollama.yaml -f hermes.yaml \
  run --rm hermes python -c \
  "from plugins.dashboard_auth.basic import hash_password; print(hash_password('your-password'))"
# then add to ~/.secrets/hermes-home/config.yaml:
#   dashboard:
#     basic_auth:
#       username: <name>
#       password_hash: "<hash>"
```

## Everyday utility

```bash
run.sh ps                  # what's running right now
run.sh drift                # confirm setup.sh's files match what's on disk
bats setup.bats              # full regression suite (141 tests)
run.sh test                  # same suite, via the runner
run.sh check_all             # health + drift + test, one command
run.sh bootstrap             # re-run setup.sh (idempotent)
run.sh docker_status         # Docker backend: Desktop shim or native?
```

## Docker backend — which daemon runs the stack

Two certified modes, one manual lever (the WSL-integration toggle in
Docker Desktop's GUI — Settings → Resources → WSL integration; no
script can flip it for you):

```
Toggle OFF  +  run.sh docker_migrate   →  native docker-ce  (daily driver)
Toggle ON   +  run.sh docker_revert    →  Win Docker / Desktop backend
```

Order matters on the way to Desktop: **revert first, then toggle ON**
(the script's own output walks you through it). Coming home is
toggle OFF first, then migrate.

Lost track of which state you're in?
```bash
run.sh docker_status        # the "Daemon:" line is the authority —
                            # the CLI-path line can lie in hybrid states
```
Notes: each daemon has its own image store (first profile launch
after a switch rebuilds; models and logins ride the bind mounts
either way). Full detail: `scripts/migrate_docker_backend.sh`.

## Ports and conflicts

- **9119** — any dashboard (only one at a time)
- **11434** — local Ollama, if running

## If something's stuck

- `claude -p` in an offline profile (`docs`/`review`) hangs forever,
  no self-timeout — `Ctrl+C` it, or wrap future automation in
  `timeout 15 claude -p ...`
- "No inference provider configured" — `hermes-home/config.yaml`
  has no valid provider; run `hermes setup` from a plain `hermes`
  session (fixes it for every profile, they share the file)
- A dashboard container from a prior session lingering:
  `docker rm compose-hermes_dashboard*` (safe — all state is in
  bind mounts, not the container)
