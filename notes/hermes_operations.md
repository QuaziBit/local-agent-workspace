# Hermes Operations — Quick Reference

Condensed steps only — for the reasoning, debugging history, and
why each of these exists, see `local_models.md`.

**A known unpinned risk, not yet fixed:** `hermes.yaml` and every
hermes-tier Dockerfile pull `FROM nousresearch/hermes-agent:latest`
— a floating tag. A whole new delegation mechanism (`delegate_task`
+ named skills, async batching, a curator/memory subsystem) showed
up unannounced in one session with no image rebuild trigger on this
project's side, most plausibly because that upstream tag moved.
Codex was pinned to a fixed version for exactly this class of risk
(`local_models.md`) — `nousresearch/hermes-agent` hasn't had the
same treatment yet. Confirmed unaffected by this so far: the write
boundary (`HERMES_WRITE_SAFE_ROOT`) is enforced identically under
both the old and new delegation mechanisms — but any other upstream
change could land the same way, silently, on the next rebuild.

## 1. Editing `hermes.yaml` — the compose file

Host-owned, plain `nano`, no sudo:

```bash
nano ~/workspace/infrastructure/compose/hermes.yaml
```

Container-level settings live here — things Hermes can't change
from inside itself:

- `environment:` — `HERMES_WRITE_SAFE_ROOT`, `PUID`/`PGID`,
  `HERMES_DASHBOARD`
- `volumes:` — vault mounts, the `hermes-home` mount

## 2. Editing `config.yaml` — Hermes's own settings

Root-owned (Hermes's container init runs as root) — needs `sudo`:

```bash
sudo nano ~/.secrets/hermes-home/config.yaml
```

Alternative that avoids `sudo`: run `hermes config edit` *inside* a
session instead — opens an editor inside the container where
permissions match. (Untested here, but exists.)

**Git identity for `agent_inbox`'s commits** is seeded automatically
by `setup.sh` at `~/.secrets/hermes-home/home/.gitconfig`
(`hermes@localhost` / `Hermes Agent`) — without it, the Review tab's
Commit button fails with "Author identity unknown." Guarded like
every other seed: a fresh bootstrap never overwrites a value already
set. To use a real identity instead, just edit that file directly —
no rebuild needed, every container reads the same bind mount.

## 3. Running Hermes — interactive chat

```bash
cd ~/workspace/infrastructure/compose
docker compose --env-file ../workspace.env -f ollama.yaml -f hermes.yaml run --rm hermes
```

Both `-f` flags together, every time — merges the two into one
compose project so `ollama` resolves as a hostname. `run --rm` =
ephemeral, exits when the chat session ends.

## 4. Running Hermes — web dashboard

**One-off** (dies when the terminal closes):

```bash
docker compose --env-file ../workspace.env -f ollama.yaml -f hermes.yaml run --rm \
  -p 127.0.0.1:9119:9119 -e HERMES_DASHBOARD=1 hermes gateway run
```

**Persistent** (`restart: unless-stopped`):

```bash
docker compose --env-file ../workspace.env -f ollama.yaml -f hermes_dashboard.yaml up -d
```

Either way: open `http://127.0.0.1:9119`, log in with whatever's
set in `config.yaml`'s `dashboard.basic_auth`.

Generate a new password hash anytime:

```bash
docker compose --env-file ../workspace.env -f ollama.yaml -f hermes.yaml run --rm hermes \
  python -c "from plugins.dashboard_auth.basic import hash_password; print(hash_password('your-password'))"
```

## 5. Common edits — quick lookup

| Change | Edit | File |
|---|---|---|
| Switch model / endpoint | `model:` block AND `custom_providers:` block — **both places** | config.yaml |
| Trim enabled tools | `platform_toolsets.cli:` list | config.yaml |
| Dashboard login | `dashboard: basic_auth:` | config.yaml |
| Allow inbox writes | `HERMES_WRITE_SAFE_ROOT=/opt/data:/vault/agent_inbox` | hermes.yaml |
| Host-owned files (not uid 10000) | `PUID=1000` / `PGID=1000` | hermes.yaml |
| Enable dashboard | `HERMES_DASHBOARD=1` | hermes.yaml |
| Web search backend | `web: backend: "ddgs"` | config.yaml |
| Terminal default working dir | `terminal: cwd: /vault/agent_inbox` (default is `.`, relative/unpredictable) | config.yaml |

## 6. Pointing at the desktop GPU instead of the laptop

**Confirmed working, current config** (both places from row 1 above):

```yaml
base_url: http://<IPv4>:11434/v1
```

That IP is DHCP-assigned — verify with `ipconfig` on the desktop if
a connection stops working after a desktop reboot, and see whether
a DHCP reservation ever got set for it (removes this caveat
permanently). `config.yaml` already keeps the hotspot and local
addresses as commented alternatives right above the live line —
easiest way to switch back if needed.

Prerequisites on the desktop (Ollama app): `OLLAMA_HOST=0.0.0.0` and
`OLLAMA_CONTEXT_LENGTH=64000` as **System** environment variables —
and this needs a full **Quit** from the tray, not just closing a
window, or the new process won't read them (confirmed: a load was
seen running at only 8192 context despite this being set, most
likely from an incomplete restart).

Two firewall layers both have to allow it, and both have a specific
trap:

- **Windows Firewall** — a security-alert popup approved as
  "Private only" silently creates explicit **Block** rules for
  Public too. Those persist and win over any Allow rule regardless
  of what's added later. Check: `Get-NetFirewallRule -DisplayName
  "*llama*" | Format-Table DisplayName, Enabled, Direction, Action,
  Profile` — remove any `Block` rows.
- **Third-party firewalls (Portmaster, etc.)** — the app's "off"
  toggle doesn't always stop its underlying service/filter drivers.
  Check for a **"Force Block Incoming Connections"** setting; the
  fix is a per-app override (not a per-IP "Allow" — Force settings
  beat those), turning it off specifically for `ollama.exe`.

Full diagnostic story — including the false lead that looked exactly
like router isolation but wasn't — in `local_models.md`.

## 7. Checking which models are actually available

The laptop's local Ollama and the desktop's are **two separate
instances with two separate model libraries** — pulling a model on
one doesn't make it exist on the other. Run this before trusting a
model name in `config.yaml`, especially right after switching
`base_url` between the two:

```bash
docker compose --env-file ../workspace.env -f ollama.yaml exec ollama ollama list
```

(Targets whichever endpoint `ollama.yaml` is currently configured
for — this checks the laptop's local container specifically. There's
no equivalent single command for the desktop's from here; check
`ollama list` directly on the desktop instead.)

## 8. Six Hermes profiles, and the three that conflict

- `hermes.yaml` — ephemeral chat, Ollama only
- `hermes_claude.yaml` — ephemeral chat, Ollama + Claude Code
- `hermes_codex.yaml` — ephemeral chat, Ollama + Codex (confirmed
  working — see `features.md`; `codex exec "task"`, not
  `-p`, requires `pty=true`, and needs the target directory to be a
  git repo — or pass `--skip-git-repo-check`)
- `hermes_dashboard.yaml` — persistent, Ollama only, dashboard/remote-gateway reachable
- `hermes_dashboard_with_claude.yaml` — persistent, Ollama + Claude Code, dashboard/remote-gateway reachable (confirmed working)
- `hermes_dashboard_with_codex.yaml` — persistent, Ollama + Codex, dashboard/remote-gateway reachable (confirmed working — `CODEX DASHBOARD OK` through the gateway, no login prompt)

Named for the provider, not "experimental" — this is a permanent,
confirmed-working profile, not a testbed meant to be overwritten by
whatever gets tried next.

**Recommended interface: `scripts/run.sh` instead of typing any of
this by hand.** `run.sh hermes_codex`, `run.sh dashboard_claude`,
a bare `run.sh` for an interactive menu — confirmed working
end-to-end and it automates the `-f ollama.yaml`
decision from section 9 below (`ensure_ollama` brings the local
service up itself when needed, since `docker compose run` doesn't
start anything beyond the named service). VS Code tasks in
`.vscode/tasks.json` call the same script — Ctrl+Shift+P -> "Tasks:
Run Task." The raw `docker compose` commands below still work and
are useful for understanding what's actually happening, but
`run.sh` is the thing to reach for day to day.

Two more targets, added while working through a fresh
rebuild: **`run.sh models`** brings ollama up if needed and lists
what's actually pulled — the quick way to check after any wipe
whether a model needs re-pulling. **`run.sh pull [model]`** does
the pulling, defaulting to `gemma4:e2b` if no name is given. Both
work standalone, independent of any Hermes profile.

**Updating** is its own target: `run.sh update <ollama|hermes|claude|
codex|all>` (see `quick_reference.md`). It never touches data, only
images; Codex is check-only because it is pinned deliberately.

**Naming convention for future providers, decided in advance so it
doesn't need re-deriving:** each new delegated CLI gets its own pair,
same two-tier shape and same provider-named pattern —
`hermes_<name>.yaml` (ephemeral) and `hermes_dashboard_with_<name>.yaml`
(persistent) — never merged into an existing provider's files, and
never called "experimental" for the same reason `hermes_claude.yaml`
isn't. Both Codex profiles have now completed that path: proven
first, embedded after — the full pair exists in `setup.sh` alongside
Claude's.

**All three dashboard profiles (`hermes_dashboard.yaml`,
`hermes_dashboard_with_claude.yaml`, `hermes_dashboard_with_codex.yaml`)
publish `127.0.0.1:9119` and can't run at the same time** —
Docker refuses the second one while the port's taken. Run
`down` (or `run.sh down`) on whichever is currently up before
starting the other. To have both simultaneously instead, remap
one's host port (e.g. `127.0.0.1:9120:9119`) in the compose file.
Confirmed reachable from both a browser and the native Win11
desktop app over `127.0.0.1:9119` via WSL2's default localhost
forwarding — no extra networking config needed on this machine.

## 9. `-f ollama.yaml` is optional — include it only for the local endpoint

None of the six profiles hard-depend on the local Ollama service
(deliberately removed — a hard dependency would force starting it
even when `config.yaml` points elsewhere, like a desktop GPU over
the LAN). **Whether to include `-f ollama.yaml` depends entirely on
which `base_url` is currently active in
`~/.secrets/hermes-home/config.yaml`:**

- **`base_url: http://ollama:11434/v1`** (the local container) →
  include `-f ollama.yaml`, or the hostname won't resolve:
  ```bash
  docker compose --env-file ../workspace.env -f ollama.yaml -f hermes_dashboard_with_claude.yaml up -d
  ```
- **`base_url` pointing at a remote address** (e.g.
  `http://<IPv4>:11434/v1`, the desktop) → omit it entirely, no
  idle local container:
  ```bash
  docker compose --env-file ../workspace.env -f hermes_dashboard_with_claude.yaml up -d
  ```

Forgetting `-f ollama.yaml` while pointed at the local endpoint
fails loudly (`depends on undefined service "ollama"`) — easy to
fix, just add it back. The opposite mistake (including it while
pointed remotely) fails silently — no error, just an unused
container quietly consuming resources. Worth checking `config.yaml`
first if unsure which mode is currently active.

## 10. Web search — `web_search` / `web_extract`, and why the browser tool isn't the answer

Two separate capabilities exist for reaching the outside world, and
Hermes will reach for the wrong one if left unconfigured: the
**browser tool** (`browser_exec` and friends), and **`web_search`/
`web_extract`**. For "look something up online" questions, the
search pair is the right tool — cheaper, faster, and it doesn't
need a Chrome instance at all. The browser tool is for actually
driving a page (clicking, filling forms, JS-heavy sites) and, in
this containerized setup, fails outright with
`chrome-not-running: no supported browser is running and none
could be launched` — there's no desktop Chrome inside the
container for it to attach to, and the bundled headless Chromium
that ships in the image doesn't launch cleanly by default (a known
upstream flag-injection bug: the container correctly decides it
needs `--no-sandbox --disable-dev-shm-usage`, sets it in the wrong
env var, and the browser fails silently on that). None of that
matters for search-style questions — `web_search` sidesteps the
browser tool entirely.

### Backend selection

```yaml
web:
  backend: "ddgs"
```

in `~/.secrets/hermes-home/config.yaml` — same file, same `sudo
nano` + next-session-picks-it-up rules as every other Hermes
setting in section 2 above. `ddgs` (DuckDuckGo) is the free, no-key
option and the one this project runs on: no account, no API key,
installed at image build time (see below) so it works the moment a
container starts.

### `ddgs`'s real limitation — search only, no extraction

`web.backend: "ddgs"` gives Hermes **`web_search` only** — titles,
snippets, and links. It does NOT provide `web_extract` (reading a
specific page's full content). Confirmed behavior: a search-based
question ("what are the top GPUs") works cleanly — Hermes finds
good sources and summarizes from snippets. But asking it to pull
the full content of one of those URLs fails with an extraction
error, because there's no extract backend configured at all under
`ddgs` alone.

**Practical consequence — don't trust `ddgs`-sourced answers for
anything time-sensitive.** Weather is the clearest failure case:
asked "what's the weather in X, is there rain today," a `ddgs`
search returned a forecast for the WRONG DAY (said "rain tomorrow"
when asked about today) with numbers that didn't match live
conditions — because there's no extract step to actually read a
current-conditions page, only whatever a search snippet happened
to say, which can be stale, cached, or from an aggregator's
day-ambiguous SEO copy. For weather specifically, use a real
weather tool/API instead of routing through `ddgs` search. The
same caution applies to anything else where "current" matters:
stock prices, scores, breaking news — `ddgs`-only search is fine
for general knowledge lookups, not for live data.

**If full-page extraction becomes something you actually need**
(not just occasionally), the only backend that's both free and
covers extraction is **self-hosted Firecrawl** — real infrastructure
weight (its own multi-service deployment), so only worth adding if
`web_extract` failures become a recurring annoyance rather than a
one-off. Paid options (Tavily, Exa, Parallel, cloud Firecrawl) cover
it too but go against this project's no-new-accounts posture.
Self-hosted **SearXNG** is the free option for BETTER SEARCH quality
(aggregates multiple engines) without solving extraction — if it's
ever added, `SEARXNG_URL` must point at a compose service hostname
(e.g. `http://searxng:8080`), never `localhost` — same lesson as
`ollama` needing `-f ollama.yaml` to resolve as a hostname.

### Getting `ddgs` installed — `uv`, not `pip`

The `nousresearch/hermes-agent` base image's venv (`/opt/hermes/.venv`)
has **no `pip` at all** — confirmed by hand:
`python3 -m pip --version` → `No module named pip`, and
`ensurepip` had to install pip from scratch before it existed.
The image manages Python packages with **`uv`** instead. The
correct one-off install, if a container is ever missing `ddgs`:

```bash
docker exec <container> uv pip install --python /opt/hermes/.venv/bin/python3 ddgs
```

The `--python` flag is not optional — without it, `uv pip install`
looks for `VIRTUAL_ENV` or an auto-discovered `.venv` in the exec's
working directory, neither of which a plain `docker exec` sets.

This is now baked permanently into the image instead of needing a
manual install after every clean/rebuild: all three hermes
Dockerfiles (`hermes_claude`, `hermes_codex`, `hermes_all`) run
`uv pip install --python /opt/hermes/.venv/bin/python3 ddgs` at
build time, with an `import ddgs` check that fails the BUILD
(not a user's first `web_search` call) if it ever breaks. **Gap,
not yet closed:** the plain `hermes.yaml`/`hermes_dashboard.yaml`
profiles (Ollama-only, no Claude/Codex) pull
`image: nousresearch/hermes-agent` directly with no build step at
all — this fix doesn't reach them; they'd still need the manual
`uv pip install` above, or a small dedicated Dockerfile, if `ddgs`
is ever needed there.

## After any config.yaml or hermes.yaml edit

Changes take effect on the **next** `run --rm` — no separate reload
step, since each run starts a fresh container reading the current
file state.
