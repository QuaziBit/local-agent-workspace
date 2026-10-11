# Local Models — Ollama + Hermes

**Companion to `architecture.md` (Appendix C) and `authentication.md`.
Everything learned getting the local agent tier running for real —
the smoke test that turned Appendix C from "pending validation" into
a working stack. Same purpose as `authentication.md`: none of this
should need rediscovering.**

## Working Configuration (verified end-to-end)

- **Backend:** Ollama container (`ollama.yaml`), GPU passthrough
  enabled, `OLLAMA_CONTEXT_LENGTH=64000`, `OLLAMA_KEEP_ALIVE=-1`
- **Agent:** Hermes (`hermes.yaml`, official `nousresearch/hermes-agent`
  image), configured via `hermes setup` → Full setup → Custom endpoint
- **Endpoint:** `http://ollama:11434/v1`, API mode **Chat Completions**
  (service name, not localhost — both files passed together with two
  `-f` flags so the compose project merges and the name resolves)
- **Model:** `gemma4:e2b` — 100% GPU on an RTX 2060 6GB, 1.8GB total
  footprint including the 64K cache, ~4s warm turns
- **Tools:** trimmed to the working set in
  `platform_toolsets.cli`: clarify, code_execution, file, memory,
  session_search, skills, terminal, todo. Everything network-touching,
  privilege-hungry, or act-unattended (browser, web, computer_use,
  cronjob, delegation, image_gen, tts, vision) removed — re-enable
  individually, deliberately, never by default.
- **Terminal backend:** local (i.e., inside Hermes's own container).
  NOT docker — that requires mounting the Docker socket, the
  privilege escalation deliberately parked in `features.md`.

Run it:

```bash
cd ~/workspace/infrastructure/compose
docker compose --env-file ../workspace.env -f ollama.yaml up -d
docker compose --env-file ../workspace.env -f ollama.yaml -f hermes.yaml run --rm hermes
```

**Note on `-f ollama.yaml`:** every run command in this document
includes it because that's what was actually used at the time it was
tested — `depends_on` originally made it mandatory. That dependency
was later removed (see `hermes_operations.md`, section 9) once the
desktop-GPU endpoint made it clear a hard local dependency was wrong
when `config.yaml` points elsewhere. `-f ollama.yaml` is now
**optional** — include it only when actually using the local
endpoint; omit it when pointed at a remote one (no idle container).

**`${MODELS_DIR}/ollama` fills up with root-owned files — plan for
`sudo` when actually deleting it.** The official `ollama/ollama`
image runs as root, with no `PUID`/`PGID`-style remapping the way
Hermes has. Every model blob and manifest it writes into the
mounted models directory lands root-owned on the host. Invisible
during normal use (nothing needs to modify these files, only read
and recreate containers), but a genuine wall the first time anyone
tries `rm -rf` on the parent workspace directory — a plain
`rm -rf ~/workspace` fails partway through with `Permission denied`
on every path under `models/ollama/`. Fix is simply `sudo rm -rf`
for that one operation; nothing else in this project needs sudo for
routine cleanup, so it's easy to forget this specific exception
exists.

**Check what's actually pulled before trusting a model name in
`config.yaml`** — worth running this first any time `base_url` gets
switched between endpoints, since the laptop's local Ollama and the
desktop's are two separate instances with two separate model
libraries. A model pulled on one is not automatically present on the
other (confirmed: `gemma4:e4b` exists on the desktop but was never
pulled on the laptop's local container):

```bash
docker compose --env-file ../workspace.env -f ollama.yaml exec ollama ollama list
```

## Model Requirements — check BEFORE pulling anything

Hermes has two hard requirements a model must meet, and one of them
is invisible until runtime unless you check:

1. **≥64K runtime context.** Hermes refuses to start a conversation
   below 64,000 tokens ("Ollama runtime context is too small").
   Its system prompt alone (tool definitions included) is ~12.6K
   tokens — the floor is not arbitrary.
2. **`tools` and `thinking` capabilities.** Hermes sends
   thinking-mode requests; a model without the `thinking` capability
   fails with `HTTP 400: "<model>" does not support thinking`
   (hit for real with llama3.2). Without `tools`, agentic use breaks
   at the first tool call.

**The pre-flight check for any candidate model:**

```bash
docker compose --env-file ../workspace.env -f ollama.yaml exec ollama ollama show <model>
```

Read two things: the **Capabilities** list (must include `tools` and
`thinking`) and **context length** (must be ≥ 65536 — see next
section for why the model's own ceiling matters).

## Finding: qwen3's 40K ceiling (correction to Appendix C)

`architecture.md` Appendix C recommends the Qwen family. **As
packaged in Ollama, qwen3 (8B and 14B) has a 40,960-token maximum
context** — below Hermes's 64K floor, and it is a *ceiling*, not a
default: `OLLAMA_CONTEXT_LENGTH=64000`, a Modelfile variant with
`PARAMETER num_ctx 65536`, and Hermes-side `ollama_num_ctx` were all
tried, and Ollama clamped every one back to 40,960 (visible in server
logs as `n_ctx_slot = 40960` and in `ollama ps` CONTEXT column).

**qwen3 cannot be used with Hermes as packaged.** The Appendix C
recommendation needs revisiting — candidates with ≥128K windows and
both capabilities (gemma4 confirmed; qwen2.5-coder worth verifying
with `ollama show` before trusting).

## Finding: three context-length knobs, and which ones actually work

1. **`OLLAMA_CONTEXT_LENGTH` (server env, in ollama.yaml)** — sets
   the runtime context *up to the model's own ceiling*. Wins only
   when the model's ceiling is above it (worked with gemma4's 131K;
   lost to qwen3's 40K).
2. **Modelfile variant** (`FROM <model>` + `PARAMETER num_ctx 65536`
   → `ollama create <model>-64k -f Modelfile`) — bakes the context
   into a model variant. Shares weight blobs with the base (no
   re-download, no extra disk). Needed when a model's *default* is
   low but its ceiling allows more. Still cannot exceed the ceiling.
3. **Hermes `ollama_num_ctx` config** — inert in Chat Completions
   mode: Ollama's OpenAI-compatible endpoint has no way to receive
   Ollama-specific options per request. Harmless to set, does
   nothing here.

## Finding: KEEP_ALIVE=-1 vs model swapping on a small card

`OLLAMA_KEEP_ALIVE=-1` keeps every loaded model resident forever —
right for agent use (no reload latency between turns), wrong default
when swapping models on 6GB VRAM: the old model sits in memory while
the new one loads beside it. Manual eviction between swaps:

```bash
docker compose --env-file ../workspace.env -f ollama.yaml exec ollama ollama stop <model>
```

(`ollama stop` unloads from memory only; the model stays on disk.)
`ollama ps` confirms — empty table = nothing resident.

## Measured results on this hardware (RTX 2060 6GB, desktop using ~1.4GB)

| Model | Weights (Q4_K_M) | Load w/ 64K cache | Placement | Warm turn |
|---|---|---|---|---|
| qwen3:8b(-64k) | 5.2 GB | 11 GB | 65%/35% CPU/GPU | minutes (and blocked by 40K ceiling anyway) |
| gemma4:e4b (8.0B) | ~5 GB | split | CPU/GPU split | ~18 s |
| gemma4:e2b (5.1B) | ~3 GB | **1.8 GB** | **100% GPU** | **~4 s** |

Two lessons in that table: (a) the KV cache can double a model's
memory footprint — context length is memory, visibly; (b) fitting
*entirely* in VRAM is worth more than parameter count — e2b at 100%
GPU is ~4.5× faster than the bigger e4b split across CPU/GPU.
Gemma's `e`-naming is MatFormer effective-capacity, not raw size —
e2b is a 5.1B model.

**Hardware note:** this machine turned out to have a usable RTX 2060
6GB visible from WSL (Docker Desktop exposes the Windows GPU
automatically with a current NVIDIA driver — no Container Toolkit
install was needed; the compose `deploy:` GPU block was sufficient).
The revived 2013 box (2060 Super, 8GB) remains the target for the
bigger-model tier: its extra 2GB is exactly the difference between
e4b-class models splitting vs. fitting.

## Hermes operational notes

- **Config and all state live on the `hermes-home` mount**
  (`~/.secrets/hermes-home/` ↔ `/opt/data`) — survives recreates,
  same pattern as claude-home/codex-home. **But:** the official image
  runs as root internally, so everything it writes is root-owned on
  the host — reads/edits need `sudo`. Accepted friction for this
  tier; the alternative (chown after every run) fights the image.
- **Config file is the source of truth, not the wizard.** The wizard's
  tool screen committed defaults on a stray ENTER; the fix was
  editing `platform_toolsets.cli` in config.yaml directly. Wizard
  follow-up screens for tools you're disabling: Skip every one.
- **Skills ≠ capabilities.** The banner lists skills (github, email,
  obsidian...) that look alarming next to a trimmed tool list —
  skills are instruction documents; they can only act through
  enabled *tools*. The tool list is the constraint that matters.
- **Setup wizard choices that matter:** Full setup (NOT Quick
  Setup — that routes through Nous Portal's hosted cloud, defeating
  the offline tier's purpose); provider = "Custom endpoint (enter
  URL manually)" (NOT "Ollama Cloud" — that's ollama.com's hosted
  service, despite the name); platforms screen = select nothing.
- **Vault mounts: deliberately absent** from hermes.yaml in this
  first pass — see Appendix C. Adding the per-subfolder pattern
  (personal/ never listed) is the next step now that connectivity
  is proven, as its own deliberate change.
- Hermes ships first-class provider entries for **Claude Code and
  Codex CLI** — the supervisor-agent idea in `features.md` is an
  officially supported configuration, not a hack. The docker.sock
  constraint there still stands unchanged.

## Boundary Verification — Hermes (passed, three layers deep)

Hermes ran the same three-part vault test as Claude Code and Codex
(list `/vault`, write to `programming/`, write to `agent_inbox`) and
passed — but getting there surfaced **three independent enforcement
layers**, each doing a distinct job:

1. **`HERMES_WRITE_SAFE_ROOT`** — Hermes's own write allowlist,
   default `/opt/data`, governing the `write_file`/`patch` tools
   only. Blocked *all* vault writes (including the legitimate inbox)
   until extended in hermes.yaml:
   `HERMES_WRITE_SAFE_ROOT=/opt/data:/vault/agent_inbox`
   (colon-separated prefixes). **The terminal tool bypasses this
   guard entirely** — which is why the mount layer isn't redundant:
   it catches what the app-level guard doesn't.
2. **Unix file permissions** — Hermes is privilege-separated: the
   container's init runs as root (hence root-owned files in
   hermes-home/), but **tool execution runs as uid=10000(hermes) by
   default**. The host-owned inbox (1000:1000) rejected it with
   plain `Permission denied` at first.

   **Real fix, confirmed working:** Hermes ships official `PUID`/
   `PGID` environment variables (LinuxServer.io-style convention,
   documented at hermes-agent.nousresearch.com/docs/user-guide/docker)
   that remap the internal hermes user to match the host UID —
   exactly the same reasoning as this project's own agent Dockerfile
   using UID 1000. Set in hermes.yaml:
   ```yaml
   environment:
     - PUID=1000   # match: id -u <host-user>
     - PGID=1000
   ```
   Confirmed: files Hermes writes now land owned by the host user
   directly — openable in VS Code/nano with zero sudo, matching
   Claude Code and Codex exactly.

   **Known upstream bug** (nousresearch/hermes-agent#35025): any
   non-default PUID makes the boot hook re-`chown` every
   Hermes-managed directory (sessions, logs, memories, skills, and
   more) on **every** container start, not just the first. Since
   this project runs Hermes with `run --rm` (fresh container per
   launch), every single invocation pays that cost — noticeably
   slower startup. Worth it for correct file ownership; not worth
   fighting further at current data volume.

   **Do not use Compose's `user:` directive as a shortcut** — Hermes's
   boot script explicitly rejects `docker run --user`, since it
   breaks s6-overlay's root-level bootstrap. `PUID`/`PGID` are the
   only supported path.

   (The earlier workaround, `chmod o+w` on the inbox to let uid
   10000 write there at all, is superseded by this fix and no
   longer needed with PUID/PGID set — kept here for the record in
   case PUID/PGID are ever removed.)
3. **Read-only mounts (kernel)** — `touch /vault/programming/...`
   through the terminal tool (past layer 1) failed with
   `Read-only file system`. Verified with an unprivileged UID; the
   mount flag is what's enforcing, not file ownership.

And `personal/` was absent from every listing — never mounted, same
as both cloud agents observed.

**Reporting-quality caveat for this tier:** the 5B model executed
all commands faithfully but repeatedly misattributed *which error
hit which path* in its prose summaries (calling a permissions
failure "read-only," hedging about files that plainly succeeded).
Trust the raw command output it shows, not its narrative summary —
and expect to read exit codes yourself.

## Web Dashboard (verified working)

Hermes ships a browser admin panel (config, API keys, sessions,
logs, memory, cron, skills) — FastAPI backend + React frontend on
**port 9119**, activated with `HERMES_DASHBOARD=1`. Verified
reachable and usable from the Windows browser at
`http://127.0.0.1:9119` with password auth.

**Auth is mandatory, fail-closed — and here's the subtlety that
cost the first attempt:** Docker's host-side port mapping
(`-p 127.0.0.1:9119:9119`) restricts which host interfaces reach
the port, but *inside* the container the dashboard must bind
`0.0.0.0` in its own network namespace or Docker has nothing to
forward to. The dashboard's safety logic only sees that internal
non-loopback bind and refuses to serve without an auth provider —
it cannot see the host-side restriction. So a Dockerized dashboard
always requires auth, even when it's effectively loopback-only.
There is no unauthenticated public-bind option, by design.

**Password auth setup (stays fully local — do NOT use the Nous
OAuth option, which adds a cloud login to the offline tier):**

```bash
# 1. generate a hash
docker compose --env-file ../workspace.env -f ollama.yaml -f hermes.yaml run --rm hermes \
  python -c "from plugins.dashboard_auth.basic import hash_password; print(hash_password('your-password'))"

# 2. add to ~/.secrets/hermes-home/config.yaml (sudo):
#    dashboard:
#      basic_auth:
#        username: <name>
#        password_hash: "<hash>"
```

**One-off launch** (dies with the terminal — fine for occasional use):

```bash
docker compose --env-file ../workspace.env -f ollama.yaml -f hermes.yaml run --rm \
  -p 127.0.0.1:9119:9119 -e HERMES_DASHBOARD=1 hermes gateway run
```

**Persistent option:** `hermes_dashboard.yaml` (generated by
setup.sh) runs the same image as a standing daemon (`gateway run`,
`restart: unless-stopped`, loopback-only port). Deliberately a
separate profile from hermes.yaml — ephemeral chat and a standing
dashboard are different usage patterns and shouldn't share a file.
Both mount the same hermes-home, so config/memory/sessions are
shared across modes.

## Native Desktop App, Pointed at the Container (verified working)

Hermes also ships an official native desktop app (Electron + React,
Windows/macOS/Linux) — a genuinely nicer chat UI than the web
dashboard. By default it runs its **own** local agent natively on
whatever machine it's installed on — meaning full, uncontained
filesystem/terminal access on that machine, none of this project's
isolation. Deliberately avoided: the native Windows install was
uninstalled rather than pointed at anything, once confirmed it held
no data worth keeping.

**The desktop app supports a documented "Remote gateway" mode** —
the polished UI, backed by the exact isolated container instead of
a local install. Confirmed working end-to-end.

**Setup:**

1. Get the dashboard backend running (same one used for browser
   access — reused, not a separate thing):
   ```bash
   docker compose --env-file ../workspace.env -f ollama.yaml -f hermes_dashboard.yaml up -d
   ```
2. In the desktop app: **Settings → Gateway → Remote gateway**
   (**not** "Hermes Cloud" — that's a one-click OAuth login to Nous's
   hosted service, the same cloud dependency this whole tier exists
   to avoid, sitting right next to the option actually wanted).
3. **Remote URL:** `http://127.0.0.1:9119`. Sign in with the same
   `basic_auth` credentials already set for the web dashboard.
   **Save and reconnect** (not "Save for next restart" — that
   defers the switch instead of testing it immediately).

**A confusing false alarm worth recording, so it isn't rediscovered
as a real bug:** immediately after connecting, using the composer's
"test connection"-style action produced `uid=197609(alexm)` and a
`/opt/data: No such file` error — looking exactly like the
connection had silently failed and reverted to running locally on
Windows (that UID is WSL's Windows-interop mapping, not anything
that exists inside a container). It hadn't. That specific action
appears to use a different code path than a real chat turn — a
genuine terminal command sent through an actual conversation
(`hostname ; id ; ls -la /opt/data`) returned a real Docker
container hostname, `uid=1000(hermes)` (the exact PUID remap already
proven elsewhere), and a fully populated, internally consistent
`/opt/data` listing (`config.yaml`, `sessions/`, `skills/`,
`kanban.db`, `SOUL.md`, multi-day real timestamps) — impossible to
have been fabricated. **Trust a real conversational turn's tool
output over any dedicated "test"/"check connection" button** if the
two ever seem to disagree.

**Confirmed conclusively** by asking directly inside a real chat
turn: *"Say hello and tell me what model you are"* returned *"I am
Hermes Agent, an intelligent AI assistant created by Nous
Research"* — the real agent identity, not a bare model self-ID,
confirming the full agent loop (not just an API passthrough) is
running inside the container and driving the native UI.

### A model/endpoint switch doesn't apply to an already-open chat session

A long, initially confusing debugging thread: after switching
`config.yaml`'s `base_url` from the desktop's LAN address back to
the local `http://ollama:11434/v1`, every symptom pointed at the
switch having silently failed — `ollama ps` stayed empty, GPU usage
stayed at zero, and Hermes's own logs kept showing
`🌐 Endpoint: http://<IPv4>:11434/v1` (the *old* desktop
address) on every attempt, with calls ending in `⚡ Interrupted
during API call` or timing out entirely.

Ruled out, with real evidence, before finding the actual cause:
direct `curl` from inside the container confirmed the network path
and the model tag were both genuinely fine; a full
`down --remove-orphans` + `up -d --force-recreate` from the correct
directory confirmed the container and its config were reading
correctly; closing and reopening the desktop app and reselecting the
model in Settings made no difference either.

**Root cause: an already-open chat session appears to bind to
whatever endpoint/provider was active when that session was
created, and does not pick up a later `config.yaml` change** — not
on app restart, not on reconnecting the gateway, not on recreating
the container. None of those touch the session's own stored state.
**Fix: start a genuinely new chat** (not reconnect, not refresh —
an actual new conversation). The new session picked up the corrected
local endpoint immediately, with the GPU active on the very next
message.

**Lesson for next time an endpoint or model switch "isn't taking
effect" despite every backend check passing: test in a brand-new
chat before suspecting the network, the container, or the config
file** — a stale open session is a real, repeatable failure mode
here, and it produces symptoms (wrong endpoint in the logs, silent
GPU inactivity, connection-shaped errors) that look exactly like a
backend problem from every angle except this one.

## Claude Code Delegation via Hermes (verified working)

Hermes can delegate coding tasks to an already-authenticated Claude
Code session, reusing the exact Max subscription login proven all
week — no new auth, no API key. Confirmed end-to-end. Corrects the
"unverified guess" status from `features.md`'s supervisor-agent
entry to a real, working recipe.

### The working recipe

**Dockerfile** (`infrastructure/docker/hermes_claude/Dockerfile`)
— extends the official Hermes image, since we don't control its own:

```dockerfile
FROM nousresearch/hermes-agent

USER root
RUN curl -fsSL https://claude.ai/install.sh | bash \
    && chmod 755 /root \
    && chmod -R a+rX /root/.local \
    && ln -s /root/.local/bin/claude /usr/local/bin/claude
```

**Compose file** (`hermes_claude.yaml`) — deliberately separate
from the proven `hermes.yaml`, same discipline as `ollama.yaml`/
`hermes_dashboard.yaml` staying apart from what already works:

```yaml
services:
  hermes_claude:
    build:
      context: ../docker/hermes_claude
      dockerfile: Dockerfile
    environment:
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
    stdin_open: true
    tty: true
    # depends_on deliberately removed — include -f ollama.yaml only
    # when actually using the local endpoint (see hermes_operations.md)
```

```bash
docker compose --env-file ../workspace.env -f ollama.yaml -f hermes_claude.yaml run --rm hermes_claude
```

Delegate, from inside a session:

```
claude -p "task" --allowedTools Read,Edit --max-turns 10
```

### Three bugs found and fixed getting there

1. **Wrong mount destination guessed first — corrected by asking
   Hermes to introspect itself, not by assuming.** Initial guess was
   `/root/.claude`, assuming Claude Code would run as root since
   that's how the binary was installed. Wrong — `PUID=1000`/
   `PGID=1000` (already required for regular Hermes use) means tool
   *execution* runs as UID 1000, not root. Confirmed by literally
   asking Hermes to run `whoami ; echo $HOME ; id` — showed
   `uid=1000(hermes)`, `$HOME=/opt/data/home`. That path sits
   *inside* the already-mounted `/opt/data` (the `hermes-home`
   mount) — Docker handles this nested-mount pattern fine, the more
   specific mount just takes precedence for that sub-path.

2. **A stale build cache masked a completely failed install.** The
   first `build` finished in 0.2 seconds with the install line
   showing `CACHED` — looked successful. But `which claude` inside
   the running container came back empty. Forcing `--no-cache`
   revealed the real install taking 28.6 seconds — the first attempt
   had genuinely never run for real. Lesson: an instantly
   "successful" build of a step that should take real time is itself
   a signal to distrust — Docker's cache only records that a command
   exited 0 last time, not that it did anything useful.

3. **`/root` blocks traversal for any non-root user, regardless of
   permissions on what's inside it.** Even after a real install,
   `which claude` still failed until this was understood. `/root` is
   mode `700` by default — no `chmod` on a target file matters if the
   *path to it* is blocked at the parent directory first. A first
   attempted fix copied just the launcher script
   (`/root/.local/bin/claude`) into `/usr/local/bin` — made it
   *findable* (`which claude` worked), but running it failed with
   `error: unknown command 'claude'`, because the copied file turned
   out to be a **script**, not a compiled binary (confirmed via
   `file`), depending on other files under `/root/.local/share` that
   got left behind by copying only the one file. Final fix: don't
   move anything — widen `/root`'s own permissions (`chmod 755 /root`,
   `chmod -R a+rX /root/.local`) so every file the installer created
   stays exactly where it expects to find the others.

### A model-reporting failure, caught mid-investigation

While diagnosing #3, asking Hermes (running `gemma4:e2b`) to
`head -30` the launcher script returned 21 lines literally reading
"ASCII text" — not real file content, a garbled restatement of what
the *previous* `file` command had said. Same unreliable-verbatim-
reporting pattern already on record from the original boundary
testing (see "Boundary Verification — Hermes" above) — not a one-off.
**Don't trust this model tier to relay detailed multi-line output
faithfully; verify through a second channel, or switch to a larger
model for debugging sessions that need accurate reporting.**

### A more serious failure: fabricating a result from memory, not garbling one

Days later, running the identical delegation command
(`claude -p "say hello..."`) against `hermes_dashboard.yaml` — a
container that was independently confirmed, twice over
(`which claude` failing, and `docker ps` showing plain
`nousresearch/hermes-agent` with no custom build), to have **no
`claude` binary installed at all** — Hermes still returned a
complete, plausible, confidently-framed result: the exact same
`claude-sonnet-5` response text from the earlier, genuinely real
test on `hermes_claude`. Session memory had retained that
prior exchange, and rather than attempt the command and report a
real "not found" error, it presented a **recalled result as a fresh
execution**, with nothing marking it as such.

This is a meaningfully worse failure than the garbled-`head`
incident above — that was a live command producing a corrupted
report; this was **no command being run at all**, with a fabricated
but entirely plausible result standing in its place. A convincing
answer is not evidence something happened. **Any claimed result from
this model tier that "conveniently" matches something from earlier
in the same session — a prior test, a prior file's content — needs
independent verification before being trusted, especially across a
persistent-memory session where a genuinely fresh command and a
recalled one are indistinguishable from the reply alone.**

### The mirror case: fabricating a confident FAILURE, not just a success

A second, independently confirmed instance of this failure mode —
this time on a fresh desktop install, so it's not specific to one
machine's session history. Asked to save a chat to
`/vault/agent_inbox/chat_summary.txt` through `dashboard_all`,
Hermes gave **three consecutive, detailed, technically-worded
refusals** — citing a `HERMES_WRITE_SAFE_ROOT` violation — across
both its own `write_file` tool AND a raw `bash -c` shell command
passed through the terminal tool (which has no concept of a "safe
writing root" to reason about at all). One refusal even displayed
the correct root string with `/vault/agent_inbox` literally inside
it, then concluded that same path was "outside" it — internally
inconsistent, not just wrong.

Checked directly (`docker exec ... cat`, then host-side `ls`): the
file was there. It had been the entire time. Every refusal was
fabricated narration, not a real restriction — the exact mirror of
the fabricated-success case above, but for failure instead of
success. Told directly "I can see the file now," Hermes replied "I
understand that you are seeing a file" — registering the contrary
evidence — and then **repeated the identical false refusal anyway**,
unmoved by it. The conversation itself will not self-correct this;
arguing with it in-chat does not help.

**Practical rule this earns, stronger than the one above:** never
trust Hermes's own narrated success OR failure for a file operation
— verify independently (`docker exec`, host-side `ls`/`cat`) for
anything that actually matters, every time, regardless of how
confident, detailed, or technically plausible the in-chat account
sounds.

**Not every write failure is fabricated, though — worth telling the
two apart.** In the same session, a separate `claude -p` write
(bare, no `--permission-mode acceptEdits`, cwd left at default)
genuinely did not produce its file — confirmed by the same direct
check coming back empty. That's the ordinary, well-known permission
gate, not fabrication. And a write with the flag present but an
**absolute** cross-mount path (`/vault/agent_inbox/x.txt`) also
genuinely failed, while the identical task with `workdir=` pointed
directly at the target directory AND a **relative** filename
genuinely succeeded — confirmed the same way. See
`delegation_phrasing.md`'s "Writing outside the default cwd"
section for the exact working pattern. The lesson isn't "assume
every failure is fake" — it's "assume nothing either way without
checking."

### Codex-via-Hermes writes — root cause found, permanently fixed

A long investigation, with two honest mid-course corrections, landed
on the real cause and a real fix. Full chain, wrong turns included —
kept in the record because each one ruled something out cleanly:

1. `codex exec --sandbox workspace-write` failed to write into
   `/vault/agent_inbox` via Hermes's terminal tool, consistently,
   across `hermes_codex` AND `hermes_all`. `--add-dir` didn't help.
   `bwrap`/bubblewrap confirmed absent (system + bundled) in both
   images. `--sandbox danger-full-access` (bypassing the sandbox
   entirely) succeeded — read at the time as proof the sandbox
   couldn't initialize in this environment AT ALL.
2. **Correction #1:** a genuinely interactive Codex session
   (`run.sh sandbox`, native pty via `docker exec -it`, no Hermes
   involved) wrote a real file successfully, verified independently
   via `docker inspect`'s mount source + `find`/`cat`. So bubblewrap
   clearly CAN initialize in this stack — the failure was narrower:
   something Hermes-delegation-specific, not a platform limitation.
   Working theory at this point: Hermes's `pty=true` construction
   not providing real terminal semantics.
3. **Correction #2:** a `--project`-mounted real git repo, delegated
   through the SAME `hermes_codex` profile, SAME non-root `hermes`
   user — succeeded. That ruled out privilege/pty-construction as
   the differentiator too, since the context was identical to every
   failing `agent_inbox` attempt.
4. **Root cause, confirmed:** `codex exec`'s trust check wants a
   `.git` directory DIRECTLY in the CWD it's invoked from — not
   satisfied by an ancestor directory's repo (the vault's own
   top-level `.git`, one level up, didn't count), and not satisfied
   by `--skip-git-repo-check` alone (which only suppresses the
   refusal message, not the underlying trust/boundary computation).
   `agent_inbox` had neither. A **bare `git init`, zero commits**,
   directly inside `/vault/agent_inbox` was sufficient — confirmed
   by the exact same previously-failing command succeeding
   immediately after, verified at a real host shell prompt (no
   Hermes narration involved in the check at all).
5. **Confirmed generalizing**, same session: re-tested across
   `dashboard_all` for all three write mechanisms (Codex, Claude,
   Hermes's own `write_file`) — all three succeeded, verified via
   `git status` inside `agent_inbox` showing the real files as
   untracked entries.

**Permanently fixed at the infrastructure layer**: `setup.sh` now
`git init`s `agent_inbox` as its own nested repo (bare, zero
commits) during bootstrap, idempotent, and excludes it from the
vault's own top-level git tracking (a nested `.git` would otherwise
show up there as a confusing "gitlink" entry). Every future fresh
install gets this automatically — see `features.md`'s Resolved
section.

**Practical implication, now settled rather than hypothesized:**
Codex was never broadly broken — real project work through `dev`
was very likely fine the whole time, and Codex-via-Hermes writes to
`agent_inbox` specifically now work too, on any workspace bootstrapped
with the current `setup.sh`. On an OLDER workspace (bootstrapped
before this fix), a one-time `cd ~/workspace/vault/agent_inbox &&
git init` resolves it immediately, same as it did here.

### Confirmed working

```
claude -p "say hello and tell me what model you are" --allowedTools Read,Edit --max-turns 3
```

Returned a real response from `claude-opus-5[1m]` (the 1M-context
variant) — no login prompt, confirming the mounted credentials were
used directly, the exact Max session authenticated days earlier.

Worth knowing for real use: the default working directory inside the
container is `/opt/hermes` (the install location), not any project —
always pass `workdir=` explicitly so delegated tasks operate on real
code, not the container's own install files.

**Controlling which Claude model gets used — confirmed working.**
With no override, Claude Code defaulted to `claude-opus-5[1m]` — the
most expensive option, worth being deliberate about for automated
delegation. Since `claude-home` is bind-mounted to the exact path
Claude Code reads its settings from, a plain host-side file edit is
enough, no rebuild:

```bash
sudo nano ~/.secrets/claude-home/settings.json
```
```json
{
  "model": "sonnet"
}
```

Confirmed on the very next `run --rm` — no restart needed, since a
fresh container reads the file at startup. Re-running the same
identity-check prompt returned `claude-sonnet-5`, in ~161 tokens
total, with a clean, accurate tool-call trace this time (unlike the
`head -30` misreport earlier — worth noting this session reported
faithfully, so the earlier issue isn't universal, just not
reliable). `--model <alias>` also works as a per-call override on
top of this default (`opus`, `sonnet`, `haiku`), confirmed via
Anthropic's own docs, not tested directly here.

### What this proves

The delegation idea from `features.md`'s "Supervisor agent" entry is
no longer speculative — Claude Code's half is fully confirmed,
reusing the subscription through the safe terminal-delegation path
(not the risky OAuth-provider mechanism ruled out earlier). Codex's
half is now ALSO confirmed — see the next section.

## Codex Delegation via Hermes (verified working)

Same credential-reuse mechanism as Claude Code above, reusing the
already-authenticated ChatGPT-plan login via `codex-home` — no new
auth. Confirmed end-to-end from a totally fresh build (workspace and
Docker state both wiped to zero first): a real `codex exec` call
returned `CODEX DELEGATION OK`, no login prompt.

### The working recipe

**Dockerfile** (`infrastructure/docker/hermes_codex/Dockerfile`) —
extends the official Hermes image, but takes a genuinely different
path than Claude's: Codex ships a statically linked musl release
binary on GitHub, so there's no `/root`-permissions fix to apply at
all — the binary drops straight into `/usr/local/bin` and is
executable by any uid as-is:

```dockerfile
FROM nousresearch/hermes-agent
USER root
RUN curl -fsSL -o /tmp/codex.tar.gz \
      https://github.com/openai/codex/releases/latest/download/codex-x86_64-unknown-linux-musl.tar.gz \
    && tar -xzf /tmp/codex.tar.gz -C /tmp \
    && mv /tmp/codex-x86_64-unknown-linux-musl /usr/local/bin/codex \
    && chmod 755 /usr/local/bin/codex \
    && rm /tmp/codex.tar.gz \
    && codex --version
```

**Compose** (`infrastructure/compose/hermes_codex.yaml`) — same
`hermes-home` + per-subfolder vault pattern as every other profile,
mounting `codex-home` at `/opt/data/home/.codex`. Introspection
confirmed identical to the Claude container: `uid=1000(hermes)`,
`$HOME=/opt/data/home` — same base image, and it held.
`~/.codex/auth.json` confirmed present and correctly populated
(`auth_mode: chatgpt`) through the mount.

### What was anticipated correctly, vs. what wasn't

The two gotchas recorded in advance from Codex's own skill docs were
both real: invocation is `codex exec "task"` (not `-p`), and it
**requires `pty=true`** — get that backwards and the call hangs.
Codex also **refuses to run outside a git repository** — confirmed,
with two working fixes: `git init` in the target directory before
the exec call, or `codex exec --skip-git-repo-check` to skip the
requirement outright. Which of the two is the better standing
pattern is still an open question (see below) — the container is
ephemeral (`run --rm`), so a bare `git init` approach means redoing
it on every single launch.

The anticipated bubblewrap uid-map error (seen previously in
`dev.yaml`'s boundary test, "setting up uid map: Permission denied")
did **not** appear in this container — and a later dashboard run
showed what actually happens instead: a soft warning, *"Codex could
not find bubblewrap on PATH... Codex will use the bundled bubblewrap
in the meantime"*, followed by a successful call. So the sandbox
nesting concern resolves gracefully here, not fatally. Closed by
observation.

Three operational details from the same raw exec output, worth
knowing before real delegation work:

- **`sandbox: read-only` is NOT a blanket exec-mode default —
  correction.** The dashboard test showed read-only;
  a direct-shell agent-tier test with the exact same Codex version
  showed `workspace-write` by default instead. Working hypothesis:
  it tracks whether stdin is piped (the dashboard run printed
  "Reading additional input from stdin...", the direct-TTY run
  didn't) rather than the invocation mode itself. Practical
  takeaway either way: don't assume write access — pass
  `--sandbox workspace-write` explicitly on any call meant to
  actually change files, through Hermes or direct.
- **`model: gpt-5.4-mini`, `reasoning effort: low`** — delegation
  currently runs the cheap/fast tier by default. For heavier tasks:
  `-m <model>` per call or a config.toml default — the exact mirror
  of the `settings.json` model note on the Claude side.
- **`approval: never`** in exec mode — Codex won't pause to ask;
  combined with read-only sandbox that's safe, but worth
  re-checking the combination if the sandbox is ever widened.

One genuinely new finding neither prediction covered: Hermes's own
terminal tool errors (**exit 126**) on a raw top-level `cmd1 && cmd2`
shell chain — this is a Hermes wrapper quirk, unrelated to Codex
entirely. Fix: wrap the whole chain as a single string instead of
letting Hermes's tool parse the `&&`:

```
bash -c "mkdir -p /tmp/codex-test && cd /tmp/codex-test && git init && codex exec 'task'"
```

This applies to any multi-command delegation call through Hermes —
Claude or Codex alike — not just this specific test.

### What this proves

Both halves of the `features.md` "Supervisor agent" idea are now
confirmed working, through the identical safe credential-reuse
mechanism, on the same base image, with the same PUID/PGID host-
ownership pattern. The two providers needed genuinely different
Dockerfiles (root-permissions widening vs. a static binary) — a
useful data point against assuming a third future provider will
mirror either one exactly; check its actual install method before
guessing.

### The dashboard combination (verified same day)

`hermes_dashboard_with_codex.yaml` — the persistent
dashboard/gateway variant — was built and confirmed immediately
after: a real delegation through the standing gateway returned
`CODEX DASHBOARD OK`, no login prompt, using the shared `basic_auth`
credentials from `hermes-home` with zero new auth setup. It's the
third profile claiming port 9119. Now embedded in `setup.sh` with a
`run.sh dashboard_codex` target.

One dead end worth recording: `codex /status` does NOT work through
the terminal tool — it fails with "stdin is not a terminal," being
an interactive-TUI slash command rather than something scriptable
via exec. The billing question it was meant to answer is closed by
other evidence anyway: the container-side `auth.json` shows
`auth_mode: "chatgpt"` with `OPENAI_API_KEY: null` — ChatGPT-plan
authentication confirmed directly.

### Codex git-trust pattern — DECIDED

Resolved with real evidence rather than picked arbitrarily, and the
answer turned out to depend on context rather than being a single
global choice:

- **Hermes-delegated Codex calls (ephemeral scratch dirs, e.g.
  `/tmp/codex-test`): `--skip-git-repo-check` is the standing
  pattern.** The agent-tier Stage A test ran it directly in a
  fresh, non-repo `/workspace` with zero complaints — clean
  success, no extra step. `git init`-per-call also works (proven
  earlier via the dashboard test) but is wasted effort for a
  directory that's about to be destroyed anyway when the container
  exits (`run --rm`).
- **Real project work under `dev.yaml`: the question doesn't
  arise.** A real project directory already IS a git repo — Stage
  B's `hello_test` had `git init` run once as part of project
  setup, not per delegation call — so neither flag is needed there
  at all.

`hermes_codex.yaml`'s comment updated to reflect this as the
confirmed recommendation, not an open choice.

## Open items for this tier
- Model research for the 8GB card: candidates need ≥64K real context
  + tools + thinking; verify each with `ollama show` before
  recommending. Update Appendix C's qwen3 recommendation. Leads
  worth checking first (not yet verified here): `mistral-nemo:12b`,
  `gemma3:12b`, `qwen3.5:9b`. Already ruled out: `phi4:14b` (capped
  at 16K context, per its own documentation — below the floor).
- Confirm `OLLAMA_CONTEXT_LENGTH=64000` is actually still in effect
  on the desktop — a load was observed with only 8192 runtime
  context despite the model's real 131072 ceiling being unchanged
  (`ollama show` confirmed the model itself was fine). Most likely
  cause: the env var not surviving an app restart that wasn't a full
  quit-and-relaunch. Check via `[Environment]::GetEnvironmentVariable
  ("OLLAMA_CONTEXT_LENGTH", "Machine")` before trusting any future
  desktop-GPU timing numbers.

## LAN Ollama — the Desktop GPU (verified working, 8GB card)

The desktop's RTX-class 8GB card is reachable from the laptop over
the regular home network — no hotspot, no workaround, config as
simple as pointing `base_url` at an IP. Getting there took real
debugging; the destination is clean.

**Working config** (`~/.secrets/hermes-home/config.yaml`, both the
`model:` block and `custom_providers:`):

```yaml
base_url: http://<IPv4>:11434/v1
```

**IP stability — read before trusting this number long-term:**
`<IPv4>` is DHCP-assigned on the desktop's regular Wi-Fi and can
change on a reboot unless a DHCP reservation is set for it in the
router/gateway admin (Xfinity app → Connected Devices → the desktop
→ reserve its address). Until a reservation is confirmed set,
treat this IP as "current, not guaranteed" — verify with `ipconfig`
on the desktop if a connection stops working after a desktop reboot.

**Desktop prerequisites, all required:**

```powershell
# System environment variables (persist across reboots; need a
# FULL Ollama quit-and-relaunch from the tray to take effect —
# closing a window is not enough, and neither is an auto-update
# restart)
OLLAMA_HOST=0.0.0.0
OLLAMA_CONTEXT_LENGTH=64000
```

```powershell
# Windows Firewall — verify no stray Block rules exist; approving
# an early security-alert popup as "Private only" silently created
# explicit BLOCK rules for the Public profile, which persisted even
# after the intended Allow rules existed (Block beats Allow in
# Windows Firewall regardless of order)
Get-NetFirewallRule -DisplayName "*llama*" | Format-Table DisplayName, Enabled, Direction, Action, Profile
# Remove any row with Action: Block
```

**Third-party firewalls (Portmaster or similar) — check explicitly,
don't assume "off" means off:** Portmaster's UI toggle for a running
service does not necessarily stop its kernel-level filter drivers.
A global **"Force Block Incoming Connections"** setting was engaged
and silently dropped every inbound attempt to Ollama, with no
visible error — connections just timed out, indistinguishable from
a network routing problem. The fix is a per-app override (Portmaster
→ the blocked connection → **App Setting**, not the "Allow IP"
button on an individual connection — Force settings override
per-IP allows by design) turning Force Block off specifically for
`ollama.exe`, leaving the global protection intact for everything
else.

**Verification, in order — don't skip to the top:**

```powershell
# 1. Ollama answers itself, locally, on the LAN-facing address
curl.exe http://<desktop-ip>:11434/api/version

# 2. the actual reachability test, from the laptop
Test-NetConnection <desktop-ip> -Port 11434
```

**The false lead worth remembering:** every earlier symptom (laptop
can't ping desktop, desktop can't ping laptop, a phone on the same
Wi-Fi can't reach it either) looked exactly like router-level
wireless client isolation on the Comcast gateway, whose admin panel
is app-locked with no local isolation toggle to check. That
diagnosis was reasonable given the evidence at the time but turned
out to be wrong — the real cause was entirely on the desktop
(Portmaster + the hidden firewall Block rules). A Windows Mobile
Hotspot experiment (laptop and desktop both joined to the desktop's
own hotspot, bypassing the gateway entirely) was what isolated the
true cause — traffic still failed even with the gateway completely
out of the path, which is what correctly redirected the
investigation back to the desktop itself. The hotspot was the
diagnostic tool that found the real bug, not the fix — once
Portmaster and the firewall rules were corrected, the *original*
LAN address worked directly, no hotspot needed.

**Lesson for next time this gets set up on a different machine:**
check third-party firewall software (Portmaster, Little Snitch,
similar) and existing Windows Firewall rules for the target app
*before* assuming a network-level cause — isolation and app-level
blocking produce identical symptoms (silent timeout, both
directions) and are easy to misattribute to the wrong layer.


---

## Closure — seccomp, bwrap, and the four verification hazards

### The ending: seccomp + missing bwrap

The full causal chain, for the record: workspace-write = bubblewrap
= unprivileged user namespaces = blocked by the docker daemon's
default seccomp profile (both machines' daemons — the probe that
proved it: `docker run --rm <hermes image> bash -c "unshare -U true"`
fails under the default profile, succeeds with
`--security-opt seccomp=unconfined`). On top of that, the 0.147.0
musl binary has NO working bundled bwrap despite its startup warning
claiming otherwise — it panics at shell launch (launcher.rs, caught
via `RUST_LOG=debug`). The laptop masked leg 2 because kernel 6.6's
Landlock lets codex's `apply_patch` fallback write without any
shell; MSI-PC's 5.15 could not. Fixes: compose-level
`seccomp=unconfined` + system bubblewrap in the images + version
pin. Both machines confirmed end-to-end.

### Verification hazards — now four flavors

1. Local model **fabricates** a delegation result (recalled prior
   content presented as fresh execution — the original case).
2. Local model reports failure honestly but **misdiagnoses** it
   (narration drift: "missing its required bwrap runtime" wording
   that implied a different codex build than reality).
3. **`codex exec` exits 0 on task failure.** A failed write still
   returns success to the shell — Hermes then truthfully relays a
   false success from a lying exit code. Never trust codex's exit
   status for task outcomes.
4. **Hermes silently substitutes its own `write_file`** for a
   failed CLI delegation, leaving real files on disk that falsely
   "prove" the CLI worked (observed: joke-file session, MSI-PC).
   Attribution must be checked, not just file existence.

Rule unchanged, now with teeth: the only verdict is a host-side
`ls`/`cat` of the target file — and knowing WHICH tool wrote it.

### The raw-capture diagnostic pattern

When a delegation fails and the narration can't be trusted, capture
codex's own output via bash redirection (a write by BASH, not by
codex, so it lands even when codex's sandboxed writes fail):

```
Use your terminal tool with workdir=/vault/agent_inbox and pty=true to run: bash -c "codex exec --skip-git-repo-check --sandbox workspace-write '<task>' > codex_raw.log 2>&1; echo EXIT_CODE=$? >> codex_raw.log"
```

Add `-e RUST_LOG=debug` (via `docker exec`) for the sandbox
backend's own errors — that's what surfaced the launcher panic.
For direct `docker exec` CLI tests, remember credentials live at
the hermes user's home: `-u 1000 -e HOME=/opt/data/home`, or the
CLI runs credential-less and 401s.

### security_opt is container-CREATION-time

Ephemeral profiles (`run --rm`) pick up compose changes on every
launch. `up -d` dashboards keep their birth-time image AND settings
until a real recreate — `run.sh down` + relaunch; a `restart` is
NOT enough. Verify with:
`docker inspect <name> --format '{{.HostConfig.SecurityOpt}}'`.
