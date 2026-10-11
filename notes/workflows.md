# Workflows — What To Reach For, Depending What You're Doing

The stack has a lot of pieces (`quick_reference.md` lists all of
them). This doc answers the other question: **given what I'm
actually trying to do right now, which piece is the right one?**

## "I just want to think out loud / ask a quick question"

```bash
run.sh hermes
```
Local model, fully private, no delegation, no cost. Good for: quick
lookups, rubber-ducking a problem, drafting a rough idea before
committing to it. If a thought is worth keeping, ask it to save the
note — see "capturing notes" below.

## "I want to capture a note, idea, or something to revisit later"

Two options, same destination underneath:

- **Through Hermes** (`run.sh hermes` or the dashboard): ask it to
  write the thought into `agent_inbox` — that's the one path
  every profile can always write to, review's read-only project
  included. Good when you're mid-conversation and don't want to
  break flow to open an editor.
- **Directly in Obsidian**, if it's running under WSLg (see
  `reference/getting_started.md` Phase 4): faster for anything longer than a
  sentence, and you get the full vault's structure (`ideas/`,
  `research/`, etc.) instead of everything landing in one inbox
  folder.

Either way, `agent_inbox` is meant to be triaged — periodically move
things out of it into the right curated folder once you've decided
where they belong.

## "I want to explore/brainstorm a new idea, possibly with AI help"

Start local (`run.sh hermes`) — it's free and fast for divergent
thinking. If the idea needs real research, a second opinion from a
stronger model, or actual code to become concrete, escalate mid-
conversation by delegating:

```
Use your terminal tool to run: claude -p "<the actual question or task>"
```

No need to restart in a different profile — `hermes_claude` /
`hermes_codex` are for when you know upfront you'll want delegation;
if you started in plain `hermes` and change your mind, just exit and
relaunch with the profile that has the CLI you want.

## "I want to do real development work on a project"

```bash
touch ~/.secrets/<project>.env    # once per project, empty is fine
run.sh dev <project>
```

You're driving `claude`/`codex` yourself here, not through Hermes —
full project mounted read-write, vault available, network on. This
is the tier for actual sustained work, not quick pings.

Remember the write flags, or the CLIs will silently refuse to change
anything:
```bash
claude -p --permission-mode acceptEdits "<task>"
codex exec --sandbox workspace-write "<task>"
```

For iterative back-and-forth rather than one-shot tasks, just run
`claude` or `codex` interactively (no `-p`/`exec`) instead — you get
the normal conversational session.

## "I want to review or audit a project without risking changing it"

```bash
run.sh review <project>
```
Project is mounted read-only — any accidental write attempt fails
loudly instead of silently succeeding. Offline too, so this is also
the profile for reading code on a plane. Findings go into
`agent_inbox` (the one thing this profile can still write).

## "I need to work with no network" (travel, unreliable connection, or just want isolation)

```bash
run.sh docs <project>     # project stays read-write
run.sh review <project>   # project read-only
```
Both are genuinely offline (`network_mode: none`) — Claude Code and
Codex are installed but **cannot function**, since they need to
reach their APIs. This tier is for file/doc work, not AI-assisted
work. Don't try `claude -p` here expecting a fast failure — it can
hang with no self-timeout; `Ctrl+C` it if you do.

## "I just want to try something throwaway, don't want it touching anything real"

```bash
run.sh sandbox
```
No project mount beyond its own scratch space, no vault access at
all. Good for testing a command, trying a library, or checking
whether an idea even works before giving it a real project home.

## "I want to use Claude and Codex together in one session"

```bash
run.sh hermes_all        # ephemeral, both providers
run.sh dashboard_all     # same, persistent
```
Confirmed working with interleaved calls — claude, then codex, then
claude again, in one continuous session, no cross-provider
interference. Patterns that work well:

- **Second opinion:** ask Hermes a question, then delegate the same
  question to Claude and compare. Cheap local take first, stronger
  model only when it earns it.
- **Split by strength:** interleave freely — Codex for a mechanical
  refactor, Claude for the design question about it, back to Codex
  to apply.
- **Escalate, don't restart:** started in plain `hermes` and want
  delegation now? Exit and relaunch with the right profile — sessions
  are ephemeral by design, nothing's lost that isn't already in
  `agent_inbox`.

Exact delegation phrasing (this is the part that has to be
precise): `delegation_phrasing.md`. Subscriptions-vs-API-keys and
staying inside the ToS lines: `account_safety.md`.

## "I want an assistant reachable from my phone / another room / not tied to a terminal"

```bash
run.sh dashboard_claude    # or dashboard_codex
```
Then `http://localhost:9119` from any browser on the machine, or
the native desktop app. Same delegation capabilities as the
ephemeral chat profiles, just always-on instead of one-shot.

Needs a one-time password (separate from any model/provider setup,
and it doesn't survive a full `~/.secrets` wipe — check if you've
done this since the last rebuild):
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
Auth is mandatory here even though the port is loopback-only — the
dashboard's own safety check can only see its internal container
bind, not Docker's host-side restriction, so it refuses to serve
without a configured auth provider either way. Don't use the Nous
OAuth option instead; that adds a cloud login this tier doesn't need.

## "I want to switch which machine's GPU is doing the thinking"

- **Laptop's own Ollama** (default): no flag needed.
- **Desktop's Ollama**: add `-r` / `--remote-ollama` before any
  target, e.g. `run.sh --remote-ollama hermes_claude`. Also needs
  `hermes-home/config.yaml`'s `model.provider:` line pointed at the
  right `custom_providers` entry (`custom:Ollama-Desktop`) —
  editing that file is still the one thing that isn't a zero-edit
  switch yet.
- **Which model, once the endpoint's chosen**: `/model` inside any
  session, no file editing needed. Add `--global` to make the
  choice stick for future sessions too.

## "I want to switch which Docker backend runs the stack"

Two certified modes; the only manual step is Docker Desktop's
WSL-integration toggle (GUI only — Settings → Resources → WSL
integration):

- **Native docker-ce** (the daily driver): toggle OFF →
  `run.sh docker_migrate`. Idempotent — re-running skips what's
  already installed.
- **Win Docker (Desktop)**: `run.sh docker_revert` FIRST, then
  toggle ON → Apply & Restart → new terminal. The revert masks the
  native service so the restart cycle can't resurrect it.

Either direction: `run.sh docker_status` afterward, and trust the
**`Daemon:`** line, not the CLI-path line — the daemon identifies
itself, the path can lie when both stacks are installed. Each
daemon keeps its own image store, so the first profile launch after
a switch rebuilds images; models and logins live in bind mounts and
carry over untouched.

## "Something feels broken and I don't know which tier to blame"

Start at the bottom of the stack and work up — it isolates the
problem fastest:
1. `run.sh health` — is the workspace itself intact?
2. `run.sh models` — is Ollama up and does it have a model?
3. `run.sh sandbox`, ping `claude -p "hi"` directly — does the CLI
   itself work, no Hermes involved?
4. Only then suspect Hermes's own config (`hermes-home/config.yaml`)
   or the delegation phrasing (see `quick_reference.md`'s
   "if something's stuck" section, or `local_models.md`).
