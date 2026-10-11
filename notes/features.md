# Features & Open Items

**Companion to `architecture.md` and `authentication.md`. A running
backlog of things decided to build, verify, or figure out — not done
yet, tracked here so they don't get lost between sessions.**

## Open

- **Hermes project mount (`--project=<name>`) — BUILT
  extended to the dashboards the same day.** Lets Hermes chat AND
  dashboard profiles actually see and edit a real project, not just
  the vault. `run.sh --project=<name> hermes_all` (or
  `hermes`/`hermes_claude`/`hermes_codex`) mounts
  `~/workspace/projects/<name>` read-write at `/workspace` for that
  one invocation; `run.sh --project=<name> dashboard_all` (or
  `dashboard`/`dashboard_claude`/`dashboard_codex`) does the same
  for the persistent, browser-reachable form.

  Design note — pivoted mid-build from the originally-discussed
  plan: a separate `hermes_project.yaml` compose fragment doesn't
  work, because `hermes`/`hermes_claude`/`hermes_codex`/`hermes_all`
  are four DIFFERENTLY-NAMED services (that's how the profile matrix
  keeps them apart) — a single fragment file can't merge a volume
  into whichever one is actually running. Used `docker compose
  run`'s own `-v`/`-w` flags instead, applied at invocation time in
  `run.sh` — they attach to whatever service name is invoked, no
  matter which, so no new compose file was needed at all.

  The two forms use genuinely different mechanisms, both real
  now: ephemeral profiles get the mount via `docker compose run`'s
  own `-v`/`-w` flags at invocation time (no compose file needed).
  Dashboards (`up -d`) don't take run-time mount overrides that way,
  so they use the compose-fragment approach originally discussed —
  four tiny files (`hermes_dashboard(_with_<provider>)_project.yaml`),
  ONE PER DASHBOARD, deliberately not shared: a single fragment
  listing all four dashboard service names would make compose treat
  the three NOT actually being launched as new, incomplete standalone
  services with no image/build defined, which `up -d` would then
  also try to start. Confirmed via Docker's own compose-file merge
  docs before building: volumes merge additively by target-path
  uniqueness (a new mount path is appended, not a wholesale replace
  of the base service's existing mounts — credentials/vault mounts
  are untouched), and confirmed structurally with a real YAML parser
  that each fragment defines exactly one service, matching its own
  filename, before any of them were embedded.

  `--project` on any of the eight supported targets (4 ephemeral +
  4 dashboard) works; on anything else (`dev`/`docs`/`review`/
  `sandbox`) it refuses with a clear message rather than silently
  doing nothing. Dashboard-specific limitation, by nature of `up -d`:
  the mount is fixed for that instance's lifetime — switching
  projects means `run.sh down` and relaunching with a different
  `--project=`, not a mid-session change.

  Delegation calls need `workdir=/workspace` added explicitly —
  Hermes's terminal tool doesn't reliably pick up the container's
  own default working directory (same root cause as the `/opt/hermes`
  cwd finding). Documented in `delegation_phrasing.md`.

  Verified end to end, both halves: fresh bootstrap from the
  re-embedded `setup.sh` produces a `run.sh` where
  `--project=<name> hermes_all` correctly splices
  `-v .../projects/<name>:/workspace -w /workspace` into the compose
  invocation, and `--project=<name> dashboard_all`/`dashboard_claude`/
  `dashboard_codex`/`dashboard` each splice their OWN matching
  fragment file and no other — confirmed against a stub `docker`
  capturing exact argv for all eight supported targets plus the
  `-r`/`--remote-ollama` combination. A nonexistent project name is
  refused with the available-projects list; every unsupported target
  refuses instead of silently no-op'ing. `HERMES_PROJECT` is properly
  `export`ed (the ephemeral `-v`/`-w` path never needed this — bash
  expanded it locally — but the dashboard fragments' own
  `${HERMES_PROJECT}` needs a real environment variable for compose's
  YAML interpolation to see it, same reason `need_project()` exports
  `PROJECT` for `dev.yaml`). 33 embedded files now (was 29); 12 new
  bats tests total across both halves (static/grep style, matching
  this suite's existing convention for `run.sh`/compose-file
  coverage).

  Not built: paid inference provider for Hermes's own reasoning
  model (a separate, later idea from the same conversation — an
  OpenRouter/Anthropic-style `custom_providers` entry with a real
  API key, deliberately deferred, unrelated to this project-mount
  feature).

- **`init.sh` — a single master entry point for the whole stack.**
  Recorded. The gap it fills: `run.sh`'s bare interactive
  menu already IS the master entry point for a machine that's set
  up — but it lives inside the workspace, so on a virgin machine it
  doesn't exist yet, and the first-run gauntlet (bootstrap, claude
  browser login, codex device-auth, `hermes setup` before
  `dashboard_auth`, the `settings.json` model override) is all
  manual runbook-following. This is the terminal-flavored,
  nearer-term sibling of the few-clicks-setup idea parked under
  Possible (which stays parked as the eventual dashboard-surfaced
  version).

  Design direction, decided in advance: a **state detector, not a
  questionnaire** — check reality (Docker backend native/missing?
  workspace bootstrapped? secrets seeded? credentials on disk —
  the same checks that certified Run 2? Hermes configured?) and
  offer the FIRST missing step; when everything's green, hand off
  to `run.sh`'s menu. Idempotent and resumable — quit mid-login,
  re-run, it picks up where it left off. Same honest-limits
  philosophy as `migrate_docker_backend.sh`: it walks the user
  through browser/device-code steps it cannot automate.

  Where it lives: the **repo** level, outside the workspace (Run
  3's own precondition — setup.sh must come from the repo copy —
  proves why). VS Code story: the repo folder carries its own
  minimal `.vscode/tasks.json` with just the Init task; the
  workspace keeps the full daily-ops tasks.json. VS Code reads
  per-opened-folder, so the two coexist — fresh machine opens the
  repo (one task: Init), bootstrapped machine opens the workspace
  (everything else). State-detection logic gets bats coverage via
  mocked paths, same style as the migration script's tests.

  **Gate: implement only after Run 3** — the manual from-zero
  walkthrough of reference/getting_started.md IS the requirements document;
  every friction point encountered there becomes an init feature,
  so writing it earlier means guessing instead of encoding what
  was actually lived.

- **Decide the session-capture convention for the vault.**
  The mechanism already exists and needs no new infrastructure:
  `agent_inbox` is the one writable vault path for every agent and every
  profile (Claude Code, Codex, and eventually Hermes + Ollama alike),
  so whatever writes a session's output there works identically
  regardless of which agent ran. What's undecided is the *shape*:
  one running note per project in `vault/projects/`, standalone
  findings/decisions in `vault/ideas/`, cross-linked with
  `[[wikilinks]]` so Obsidian's graph view is actually useful instead
  of decorative.

  Deliberately deferred until after the first real Claude Code
  session — shape this around what an agent actually tends to
  produce unprompted, not a guess made in advance. Once decided, it
  becomes one concrete line added to `AGENTS.md`'s Working
  Conventions section (currently a passive permission — "worth
  remembering... belongs in agent_inbox" — not an actual instruction to
  do it).

- **Fragment-completeness audit: confirm the fragment set, then
  re-run.** See `_archive/finding.md` for the full audit table. The
  `gemma4:12b` audit was very likely run against the *original*
  12-file Claude Code output (first third of the source document),
  not the complete 28-file mechanical extraction produced later the
  same night — the specific gaps it reports (Appendices A/B/C,
  Backups, ADRs, Bootstrap & Recovery) are exactly the sections the
  complete archive has as dedicated files. Next step, in order:
  (1) `ls` `~/workspace/vault/agent_inbox/` and confirm which fragment
  set is actually on disk; (2) if it's the old 12-file set, extract
  the complete 28-file archive; (3) re-run the exact same audit
  prompt against it — that's the real test of whether any gaps
  remain. Independent of the outcome, the audit is a useful data
  point on `gemma4:12b`: the methodology was sound (section-by-
  section against exact line ranges) and it correctly identified
  genuine gaps in what it was actually given.

- **Google Drive as the cold-copy backup target — shape decided
  blocked only on a session that can run the one-time
  auth flow.** Fills the "one cold copy" slot in the VPS entry's
  backup posture. Decided shape, so the build session doesn't
  re-derive it:

  - Tool: **rclone with a `crypt` remote layered over the Drive
    remote** — client-side encryption of contents AND filenames, so
    Google only ever holds ciphertext. This is what makes it safe to
    include `personal/` in the backup; without the crypt layer the
    rule would have to be "exclude personal/", which guts half the
    backup's value.
  - Scope: **the whole vault, and only the vault.** `~/.secrets`
    NEVER goes to Drive, encrypted or not — those are live OAuth
    sessions to the Max and ChatGPT plans (the high-consequence
    leak already named in the VPS entry) and they're the one thing
    that's cheap to recreate by just logging in again.
  - Division of labor: **git things keep git remotes.** The
    infrastructure repo — and later the curated vault subset for
    the VPS — belong on a private git remote (history, diffs, audit
    trail). Drive's role is the encrypted blob copy of the whole
    vault including what git will never hold (`personal/`).
    Complements, not competitors.
  - Delivery: `scripts/backup.sh` plus a `run.sh backup` target,
    cron-able later if wanted.
  - Named upgrade path, not built now: **restic using rclone as its
    backend**, if snapshot retention ("the vault as of last
    Tuesday") is ever actually needed — the vault is already a git
    repo, so history exists; rclone crypt is the right-sized start.
  - Explicitly ruled out: **hosting the live vault ON Drive.**
    Consumer sync clients + a live Obsidian vault is a known
    conflict/corruption source, made worse here by container writes
    into the inbox; Drive for Desktop syncs Windows-side, forcing
    the vault across the WSL/Windows filesystem boundary the setup
    deliberately avoids; and a live plaintext vault on Drive puts
    `personal/` in a second trust domain, violating the
    one-trust-domain rule locked in with the VPS vault-topology
    decision. The vault's home stays on the laptop.

## Possible (Speculative)

Ideas worth not losing, not currently being worked toward. Distinct
from *Open* above: those have an agreed direction and something
actively blocking them; these are just candidates with no decided
priority yet.

- **Evaluate alternative agent orchestrators alongside Hermes.**
  Recorded no priority. The 2026 landscape now has
  several tools overlapping parts of Hermes's role, worth an
  evening's look each if a second data point next to Hermes ever
  seems useful: Goose (Block) and OpenHands are the closest
  local-agent analogues (OpenHands even sandboxes its work in
  Docker — philosophically close to this project's whole
  architecture); Open Interpreter and OpenCode are terminal-native
  options that can sit on the existing Ollama; Microsoft
  Conductor / Composio AO / Bernstein are a new crop of
  "orchestrator that delegates to Claude Code/Codex" tools —
  essentially Hermes's delegation layer productized, though mostly
  early-stage; Open WebUI / LibreChat / Jan are more polished
  dashboard-only layers (no delegation); **DeepSeek Harness (`dsh`)**
  is DeepSeek's own open-source agent runtime (developer preview
  alongside V4 Pro/Flash) — plug-in composable, and notably CAN
  call Claude Code or Codex as sub-agents itself, making it the
  closest functional overlap with Hermes of anything on this list.
  Two real cautions specific to it: it's an explicit developer
  preview ("APIs will change" — the same category of risk as the
  unpinned `nousresearch/hermes-agent:latest` tag that caused a
  whole undocumented tool surface to appear mid-project), and its
  auth surface matters — the DeepSeek API path would be this
  stack's first crack in the subscription/local-only posture
  (`account_safety.md`), while its local-via-Ollama/vLLM path
  wouldn't be. Separately, DeepSeek's V4 weights themselves need no
  harness at all to try as Hermes's own brain — `run.sh pull` +
  a `config.yaml` provider switch, same as any other local model.
  Any orchestrator evaluation would follow the existing
  provider-naming convention (hermes_<name>.yaml pattern or a
  sibling profile pair) and the prove-first-embed-after discipline.
  Notable: nothing found does this project's exact combination —
  local-model brain + subscription-authenticated CLI delegation +
  enforced container boundaries.

- **Vault access from Windows-native Obsidian, without moving the
  vault off WSL2's disk.** Candidate recorded. The premise "run
  Docker straight from Windows so the vault lives on Windows" was
  raised and doesn't actually hold — every image here is Linux
  (`ubuntu:24.04`, `nousresearch/hermes-agent`), so Docker Desktop
  always runs them inside a Linux VM regardless of which shell
  issues the `docker` command; there's no version of this stack
  without that layer. What's real and free to try right now: Windows
  Obsidian can already open the vault directly at
  `\\wsl.localhost\<distro>\home\<user>\workspace\vault\` — no
  code, no config change, `VAULT_DIR` untouched. The one thing worth
  actually testing before calling this done: cross-boundary file
  watching — does Obsidian's live-reload reliably pick up a file an
  agent just wrote from inside a container, or does it need a manual
  refresh. Fallback if that's flaky: point `VAULT_DIR` at an NTFS
  path instead (`/mnt/c/...`) so the bind mount is Windows-native on
  the container side too — real option, just carries the known
  WSL2 cross-filesystem I/O penalty, most relevant for heavy write
  volume rather than a lightly-edited markdown vault. Try the
  free option (Obsidian via `\\wsl.localhost\...`) first; only
  reach for the `VAULT_DIR` move if that's proven unreliable.

- **Windows on-ramp (`bootstrap.ps1`) — bare Windows → WSL2 → the
  stack.** Recorded. NOT a native-Windows port of the
  stack — that was considered and rejected: all images are Linux
  containers, which on Windows always run inside a Linux VM anyway
  (WSL2 or Hyper-V), and porting the bash/bats/symlink/chmod-700/
  UID-1000 semantics to PowerShell would double the embedded-file
  codebase against single-source-of-truth. WSL2 IS the Windows
  answer; this entry is only the missing first rung of the ladder.

  Shape: a thin PowerShell script whose whole job is getting a
  bare Windows machine to where the Linux story takes over —
  check/install WSL2 (`wsl --install -d Ubuntu`), enable systemd
  in the distro, get the repo in, hand off to `init.sh` inside
  WSL. Optional conveniences alongside: a Windows Terminal
  profile/shortcut that launches straight into `run.sh`, and a
  doc note that Obsidian-on-Windows can open the vault via
  `\\wsl$\` paths as an alternative to WSLg (ADR 0008).

  Gate: depends on `init.sh` existing first (see Open) — this is
  literally init's phase zero, so it cannot precede it.

- **Few-clicks setup — make the whole stack as user-friendly to
  stand up as possible.** Recorded explicitly "not
  now." If the FastAPI inspector (next entry) or any dashboard gets
  built, the natural next layer is collapsing the remaining manual
  bootstrap into a guided few-clicks flow: `run.sh` and
  `tasks.json` already reduced "type long compose commands" to
  "one word / one click," but first-run setup still means driving
  the login steps by hand (`claude`, `codex login --device-auth`,
  `hermes setup`, the dashboard password). A first-run wizard —
  surfaced through that same dashboard, or even just a
  `run.sh first_run` that walks the steps interactively — would
  close the gap. Depends on the inspector existing first; no
  decided priority on its own.

- **Workspace inspector/runner web app (FastAPI) — a single local
  pane of glass over the whole stack.** Candidate recorded
. One small FastAPI app showing: running containers and
  which compose profile they belong to (Docker SDK or `docker ps`
  via subprocess), Ollama status — local or the desktop LAN
  instance, same two endpoints either way (`/api/tags` for pulled
  models, `/api/ps` for what's loaded in VRAM), who currently holds
  port 9119, vault stats (agent_inbox item count, last-modified),
  and drift/health at a glance by shelling to `run.sh drift` /
  `health`. Possibly runner buttons later that just invoke `run.sh`
  targets — run.sh stays the single source of truth for HOW things
  start; the app is only a prettier finger on the same button.

  **Honest overlap check before building:** the Hermes dashboard
  (9119) already covers Hermes itself, and `run.sh ps` covers quick
  status. The app's only real value is the unified workspace-wide
  view plus click-to-run — build it for that or not at all.

  **Security shape decided in advance, same discipline as the VPS
  entry:** anything that can talk to the Docker socket is
  root-equivalent on the host, so — loopback-only on its own port
  (e.g. 127.0.0.1:9120, NOT 9119), **read-only inspector first**,
  runner/stop actions added second and deliberately; run it directly
  on the WSL host rather than as a container mounting
  `/var/run/docker.sock` (a socket-mounting container is the same
  risk class as the credential-mount concerns already recorded);
  and it never goes anywhere near the VPS without real
  authentication — if the VPS era arrives, this app is exactly the
  kind of control surface the allowlist bullet up there worries
  about. Frontend stays build-chain-free: one static page polling
  JSON endpoints (or Jinja) — no React tooling for a status page.

- **Hermes's own `delegation` tool (Task Delegation) — currently
  disabled, worth reconsidering for large multi-step tasks.**
  Directly motivated by a real failure: a single-session attempt to
  split a 55KB document into linked Obsidian notes filled context to
  85% and produced unreliable output (see `local_models.md`,
  "Claude Code Delegation via Hermes" — the batch-write rejection,
  the unprompted file-shrinking, the silent scope truncation).
  `delegation` was turned off early on, alongside `browser`,
  `computer_use`, `cronjob` — a reasonable call at the time, for a
  different reason (reducing scope for a first working setup), not
  because it was known to be unsuited to this.

  **Mechanics genuinely unverified — check real docs before
  enabling, same discipline as everything else that turned out to
  have a real gotcha tonight (Codex's `pty=true`, the git-repo
  requirement, PUID/PGID).** Open questions: does each delegated
  sub-task get its own fresh context window (which would directly
  solve the 85%-full problem)? Does it spawn separate model calls or
  coordinate within one? Does it inherit `HERMES_WRITE_SAFE_ROOT`
  and the vault mount restrictions automatically, or need its own
  configuration? None of this confirmed — first step next time is
  reading Hermes's own documentation on the tool, not guessing.

- **Gemini — currently blocked at the premise level, not just an
  implementation detail.** Checked before building anything, given
  how the Codex investigation went. Google Gemini CLI exists
  (`@google/gemini-cli`, npm, open-source), but **its subscription
  login path was shut down entirely on June 18, 2026** — Google's own
  developer blog: *"Gemini CLI and Gemini Code Assist IDE extensions
  will stop serving requests for Google AI Pro and Ultra, as well as
  those using it free of charge."* A live GitHub issue from July 1
  confirms this is still actively breaking for people trying it. The
  only remaining auth path is a raw `GEMINI_API_KEY` — metered,
  pay-per-token, the exact billing model the Claude/Codex delegation
  work was specifically built to avoid.

  Unlike the Codex entry below, this isn't "a real path with known
  gotchas" — the actual thing being asked for (subscription reuse, no
  API key) does not currently exist for Gemini, as a matter of
  Google's own recent policy change, not a technical hurdle. Not
  worth pursuing as a delegation target until/unless that changes;
  worth re-checking occasionally in case Google restores a
  subscription path (the "Antigravity" product Google is redirecting
  users toward is untested here and might be worth checking on its
  own terms someday, separately from this Hermes-delegation pattern).

- **Other subscription-capable providers — narrowed, not yet
  individually checked.** Before spending time on any vendor beyond
  Claude/Codex/Gemini, worth using evidence already in hand:
  Hermes's own `config.yaml` lists its known `fallback_model`
  providers with their auth type stated directly —
  `openrouter`/`zai`/`kimi-coding`/`kimi-coding-cn`/`minimax`/
  `minimax-cn`/`bedrock` are all **API-key-only** by Hermes's own
  design; only `openai-codex` and `nous` are marked
  `OAuth — hermes auth`. So none of Hermes's other *built-in*
  fallback options fit the no-API-key goal without a fundamentally
  different mechanism than what Hermes natively supports for them.

  This doesn't rule out those vendors having their *own* separate
  CLI with its *own* subscription-login path (the way Claude Code
  and Codex each do, independent of Hermes even knowing about it) —
  it only means Hermes's fallback-provider list isn't where to find
  one. Any candidate (Z.AI, Kimi/Moonshot, MiniMax, others) needs the
  same individual check Gemini got: does a real CLI exist, does it
  have subscription auth, is that path currently working — before
  assuming it behaves like Claude Code.

- **Hermes powered by the Claude/Codex subscription itself, instead
  of Ollama or a raw API key — checked against official docs;
  mostly doesn't work as hoped, and carries a real risk.**

  **The risk, found via Hermes's own GitHub issues, worth taking
  seriously:** a documented case exists of a similar third-party
  tool's creator ("OpenClaw") having their Anthropic account
  **banned** for routing subscription OAuth through a
  third-party client this way. An open Hermes issue explicitly warns
  *"Anthropic is actively enforcing against this pattern."* Given
  the effort already invested in this project's Claude Code setup,
  this specific mechanism is not worth the risk to the account —
  don't pursue it, regardless of what else is true below.

  **What it would even buy you, per Hermes's official docs, setting
  the risk aside:** the "Anthropic OAuth" provider only works on a
  **Claude Max plan with purchased extra/overage credits** — and
  explicitly does **not** draw from the normal Max plan allowance.
  Claude Pro doesn't qualify at all. So even ignoring the ban risk,
  this was never going to be "use the subscription already being
  paid for instead of an API key" — it's a separate paid-credits
  mechanism layered on top. Doesn't achieve the original goal.

  **Conclusion: don't pursue this entry.** The terminal-delegation
  approach above achieves everything actually wanted — Hermes
  getting real use out of the Claude Max subscription — without
  this one's cost or risk. This entry stays recorded so the dead end
  doesn't get rediscovered by trying the OAuth provider path again
  later.

- **Vector database over the vault, for semantic search beyond
  Obsidian's own notes.** `models/vector-db/` has sat reserved since
  v1.1 — mechanically straightforward whenever it's actually needed:
  Ollama (already in the stack) can serve embedding models directly
  (`nomic-embed-text`, `mxbai-embed-large`), so the new component is
  just the storage/query layer — Chroma or Qdrant, both already
  named in Exploration Notes.

  Not worth building now because there's no retrieval problem to
  solve yet: the vault's curated folders are still `.gitkeep`
  placeholders, and every agent already has direct read access to
  every file via its mounts — nothing stands between an agent and
  the content, so there's nothing for a vector search to speed up.

  Trigger conditions, either of which would make this worth
  revisiting: (1) the vault has grown enough real content that
  direct reads stop being practical — an agent can no longer just
  read the relevant folder and needs to find the right needle in a
  much bigger haystack; or (2) Hermes has a concrete, actual
  retrieval-augmented task it needs to do — not a vague "might be
  useful eventually." Claude Code and Codex are poor motivating use
  cases for this specifically, since their mounts already give them
  full direct vault visibility — this is really a Hermes-tier need,
  if it ever becomes one at all.

- **Hermes on a VPS, hooked up to Discord/Telegram for chat-based
  remote dev.** A common, real pattern other developers use — worth
  treating as a genuinely different risk profile than anything built
  so far, not just a hosting-location change. Real, concrete things
  to get right before attempting it, not after:

  - **The messaging-platform allowlist, currently unconfigured and
    already warning about it on every boot** — `"No env user
    allowlists configured... will deny unknown senders unless you
    configure platform allowlists... or explicitly opt in with
    GATEWAY_ALLOW_ALL_USERS=true."` Background noise on a
    LAN-only setup; a real access-control boundary the moment a bot
    is reachable from the open internet. `TELEGRAM_ALLOWED_USERS` (or
    equivalent) needs to be set deliberately, not left at whatever
    default currently applies.
  - **Copying `claude-home`/`codex-home` onto a VPS turns "box gets
    compromised" into "attacker has a live, authenticated Max/ChatGPT
    session to spend against"** — a meaningfully bigger consequence
    than anything at stake in a home-network compromise, and closer
    in kind to the OAuth-provider ban-risk already found and avoided
    earlier. Standard VPS hardening (SSH keys only, fail2ban,
    firewall default-deny) becomes load-bearing here, not optional.
  - **GPU access is rarely available/affordable on consumer VPS
    tiers** — the local-Ollama half of this whole setup likely
    doesn't come along; a VPS-hosted Hermes would probably run
    entirely on Claude/Codex delegation, on top of an ongoing hosting
    bill plus the existing subscriptions.
  - **Vault topology — decided in advance, same way the
    Codex naming was: the vault is NEVER VPS-only.** The laptop stays
    canonical; the VPS receives only the curated subset — `agent_inbox`
    plus the read-only curated folders, which is by construction
    everything except `personal/`. `personal/` never leaves the home
    network: putting the sole copy of it on a rented,
    internet-reachable box would invert the risk model this whole
    architecture exists to enforce, and a single copy anywhere is a
    backup posture of zero. One genuine catch to solve at build
    time, not after: the vault's git repo currently tracks
    `personal/` (setup.sh `.gitkeep`s it), so pushing that repo to
    any remote ships personal data — either add `personal/` to the
    vault's `.gitignore` (and give it its own local-only backup
    path, e.g. `backups/`), or sync at folder level (e.g. Syncthing)
    instead of git, which also handles the two-way flow better: a
    VPS Hermes writes into `agent_inbox`, so changes travel in BOTH
    directions, and unattended git two-way sync is where conflicts
    fester. Resulting backup posture: laptop (canonical) + VPS
    (working subset) + one cold copy (`backups/` or a private remote
    for the curated folders) — three locations, personal data in
    exactly one trust domain.
  - **Credential posture — decided in advance: the VPS
    runs on API keys BY DESIGN, not as a degraded fallback.** The
    subscription OAuth sessions (Max, ChatGPT plan) never ship to
    the VPS — they're personal logins with no per-machine
    revocation, and the CLIs read them from local disk, so any
    machine running delegation necessarily holds usable tokens
    while it runs. API keys are the server-native opposite:
    revocable in one click if the box is compromised, and
    budget-cappable so a runaway agent burns a limit, not a card.
    Division of labor that follows: the VPS Hermes runs
    Ollama-tier/API-key work (always-on capture into
    `agent_inbox`, light queries, Telegram/Discord chat); heavy
    Claude Code / Codex delegation stays a LAPTOP activity — that's
    where the powerful-and-cheap subscription tools live and where
    the security model wants them. Named fallback, only if remote
    delegation ever becomes genuinely necessary: fetch credentials
    at container start over SSH/Tailscale into a tmpfs mount,
    wiped on stop — understood clearly as protecting at-rest
    exposure (disk snapshots, recycled disks, backups) and NOT
    in-use compromise, which is unavoidable physics of how these
    CLIs authenticate.
  - **Go/no-go gate — decided in advance: the desktop dashboard
    rehearsal decides whether the VPS happens at all.** Before any
    hosting bill: run `hermes_dashboard` (Ollama-only variant — no
    credentials copied to a second machine) on the desktop, reached
    from the laptop via SSH tunnel (`ssh -L 9119:127.0.0.1:9119`,
    dashboard keeps its loopback-only binding — which is also
    exactly the access pattern the VPS should use later). The
    question it answers cheaply: does remote Hermes become a real
    habit, or does it idle? Habit → VPS validated before a dollar
    is spent, and the rehearsal has already exercised remote
    access, gateway auth, a second vault mount, and the two-way
    `agent_inbox` sync question on two machines physically in
    reach. Idle → no VPS, money and a security project saved. VPS
    role if it happens: lightweight always-on satellite, never a
    relocation of the workshop — and sync carries its
    `agent_inbox` writes home continuously, so the VPS never holds
    data that exists nowhere else (sync ≠ backup; losing the box
    costs setup time, not data).

  Good news: the skill-based delegation, credential-mount pattern,
  and vault-boundary design all transfer to a VPS context basically
  unchanged — nothing built so far is wasted if this gets picked up.
  Worth its own dedicated session given the real security work
  involved, not a quick add-on to an existing one.

## Resolved

- **Codex-via-Hermes writes to agent_inbox: RESOLVED.**
  Real root cause found after two honest mid-course corrections
  (full investigation trail in `local_models.md`) — `codex exec`'s
  trust check wants a `.git` directly in its invoked CWD, not just
  an ancestor's; `agent_inbox` had none. Fix: `setup.sh` now
  `git init`s `agent_inbox` as its own nested repo (bare, zero
  commits) during every bootstrap, excluded from the vault's own
  top-level git tracking. Verified across `hermes_codex`, `hermes_all`,
  and `dashboard_all` — all three write mechanisms (Codex, Claude,
  Hermes's own `write_file`) confirmed working, real files checked
  directly, no reliance on Hermes's own account of what happened.
  126 bats tests total (5 new), full fresh-bootstrap validation
  passed, `--verify` stayed clean at 33/0. One-time manual fix for
  workspaces bootstrapped before this: `cd
  ~/workspace/vault/agent_inbox && git init`.

- **Docker Desktop → native docker-ce migration: EXECUTED, CERTIFIED,
  and proven reversible.** The whole thing ran through
  the stack's own tooling (`docker_status` → `docker_migrate` →
  `bootstrap` → `check_all`), delivered as
  `scripts/migrate_docker_backend.sh` + three run.sh targets +
  three VS Code tasks, all bats-covered. Final certification on
  real hardware: health 51/0, drift 29/0, bats 106/106 under the
  native daemon; full profile matrix re-certified (hermes_all
  interleave clean, dashboards, direct tier); GPU proven via
  nvidia-container-toolkit; Desktop's WSL integration OFF.

  Three real-hardware findings, each patched WITH a regression-guard
  bats test — none catchable in sandbox testing:
  1. **enable-vs-restart sequencing**: apt starts dockerd during
     install, so `enable --now` never re-read the daemon.json
     nvidia-ctk wrote → "could not select device driver nvidia".
     Fix: explicit `systemctl restart docker`.
  2. **CLI path lies in the hybrid state**: --revert keeps docker-ce
     installed, so /usr/bin/docker stays on PATH while Desktop's
     proxy serves the socket. Fix: --check asks the daemon itself
     (`docker info` OperatingSystem → "Docker Desktop" vs "Ubuntu").
  3. **WSL-restart resurrection**: Desktop's Apply & Restart bounces
     the distro; a disabled-but-unmasked unit came back
     enabled+active — hidden by the script's own suppressed stderr +
     unconditional success message. Fix: revert MASKS
     docker+docker.socket and reports actual is-enabled/is-active
     state; migrate unmasks first.

  Reversibility witnessed in BOTH directions, as the original
  constraint demanded: revert leg — `Daemon: Docker Desktop`,
  health 51/0 served by Desktop with the native service stopped;
  return leg — fully idempotent re-entry (exists-skipping),
  `Daemon: Ubuntu 24.04.4 LTS`, service active, check_all green.
  Everything stays daemon-agnostic; the switch-back recipe lives in
  the script's own --revert output.

  Residuals, deliberate: Desktop's stack-image copies NOT purged
  yet — only after the native path survives real day-to-day use
  (purge happens in Desktop's own UI; unreachable from the distro
  with integration off). Desktop autostart-off is a one-click
  Windows-side step. Original migration sequence and constraints
  preserved below in this entry's Open-era text for the record:

  *(original Open entry)* **Migrate the stack from Docker Desktop to native docker-ce
  inside WSL2 Ubuntu.** Recorded. Motivation: fewer
  standing apps on the laptop — Docker Desktop stays installed (still
  needed for other, non-stack use) but the stack itself moves to a
  native daemon inside the distro, and Desktop's autostart goes off.
  The two daemons are fully separate (separate image stores, separate
  sockets), so this is coexistence, not replacement.

  Sequence, decided in advance: (1) Docker Desktop → Settings →
  Resources → WSL integration → toggle OFF for Ubuntu, so the
  distro's `docker` is the native one, not Desktop's injected CLI
  shim; (2) confirm systemd in `/etc/wsl.conf` (`[boot]` /
  `systemd=true`), install `docker-ce` + `docker-compose-plugin`
  per the official apt docs, add the user to the `docker` group;
  (3) install `nvidia-container-toolkit` — the "no Container
  Toolkit needed" note in `ollama.yaml` was true only *via Docker
  Desktop*, which bundles the GPU runtime; native docker-ce needs
  the toolkit for GPU passthrough; (4) rebuild/re-pull images —
  all state survives untouched because it lives in bind mounts
  (`~/.secrets`, the vault, and the Ollama models under
  `${MODELS_DIR}`, so no multi-GB re-downloads and no re-logins);
  (5) verify with the stack's own tooling: `run.sh health`,
  `run.sh drift`, `bats setup.bats`, then one `run.sh
  hermes_claude` delegation to prove the credential mounts;
  `which docker` should say `/usr/bin/docker`, not a
  `/mnt/wsl/docker-desktop` path; (6) only after green: purge the
  stack's containers/images from Desktop's side.

  `run.sh` and `.vscode/tasks.json` need zero changes — the tasks
  route everything through `run.sh`, which calls whatever `docker`
  is on the distro's PATH. Caveat while both daemons hold copies:
  don't run both simultaneously or published ports (11434, 9119)
  can clash; self-resolves once Desktop's side is purged.

  **Gate: happens only after the current test pass is finished** —
  a known-good baseline first (health/drift/bats green, confirmed
  live), so any post-migration misbehavior is
  attributable to the daemon swap alone. This is effectively a
  mini disaster-recovery drill scoped to the Docker layer only.

  **STATUS UPDATE — tooling built, migration not yet
  run.** `scripts/migrate_docker_backend.sh` now exists (embedded
  file #29): `--check` / `--migrate` / `--revert`, wired as
  `run.sh docker_status` / `docker_migrate` / `docker_revert` and
  three VS Code tasks, with 8 bats tests (mocked-PATH shim/native
  detection, the refuses-while-shim gate, and a static test proving
  the script contains no package-removal commands — the
  reversibility constraint below is now ENFORCED by the suite, not
  just stated). The gate still holds: nobody has run
  `docker_migrate` yet.

  **Constraint: the Docker Desktop path must stay available, not
  just installed.** This is a reversible switch, never a burned
  bridge: nothing in the stack may come to *depend* on docker-ce
  specifics — compose files, run.sh, and tasks.json stay
  daemon-agnostic (they already are; keep it that way). Switching
  back is just: re-enable Desktop's WSL integration for Ubuntu +
  `sudo systemctl stop docker` (or disable the native service) so
  the CLI shim wins the PATH again — then the same compose files
  rebuild under Desktop exactly as before, with all state in the
  same bind mounts. Don't purge Desktop's side until the native
  path has survived real day-to-day use for a while, and document
  the switch-back recipe wherever the migration itself gets
  documented — both directions, same doc.


- **hermes_all (combined Claude Code + Codex image): confirmed
  working.** Built per explicit request as a mechanical
  merge of the two individually-proven single-provider images
  (hermes_claude, hermes_codex) — deliberately deferred until both
  worked separately, per the original naming-convention discussion.
  Proof: three interleaved delegation calls in one continuous
  session — `claude -p`, `codex exec`, `claude -p` again — all
  returned clean with no login prompt and no cross-provider
  interference, the one risk individual per-provider testing
  couldn't have caught. UNTESTED labels stripped from run.sh,
  hermes_all.yaml, tasks.json, and setup.sh's closing summary
  (now seven of eight Hermes profiles verified working).

  **`hermes_dashboard_with_all.yaml` is ALSO now confirmed,
  same day** — three interleaved delegation calls
  through the standing gateway, reached remotely via the native
  Win11 app, all clean. This closes the entire supervisor-agent
  effort: every one of the eight Hermes profiles (four ephemeral,
  four dashboard; both providers alone and combined) is now proven
  end to end, not just built. See `_archive/testing_plan.md` §1.8/§1.8b.


- **Agent tier (dev/docs/review/sandbox) fully verified post-rebuild,
.** All four profiles run for the first time since the
  full wipe, in four staged sub-tests (A sandbox, B dev, C docs +
  review — see `_archive/testing_plan.md` §1.7). Full operational detail now
  lives in `agent_tier_operations.md`; summary here:

  - Agent image builds clean from empty Docker, both CLIs installed,
    both credential mounts (`/home/ubuntu/.claude*`,
    `/home/ubuntu/.codex`) proven with no login prompt — the last
    unverified piece of the post-wipe persistence story, now closed.
  - Every mount boundary held exactly as designed across all four
    profiles: project rw/ro per profile, `agent_inbox` writable
    everywhere (even under `review`'s read-only project), the
    curated vault read-only, `personal/` absent everywhere,
    `sandbox` with no vault at all, `network_mode: none` blocking
    `docs`/`review` completely. Host-side file ownership confirmed
    correct (uid 1000, not root).
  - Real work succeeded: `claude -p --permission-mode acceptEdits`
    created an actual file, correctly owned.
  - **Two new operational findings, both about non-interactive AI
    CLI use, not this tier specifically** — so they apply to Hermes
    delegation too: (1) plain `claude -p` write tasks stall on an
    unanswerable approval prompt — `--permission-mode acceptEdits`
    is required; (2) `claude -p` has no self-timeout offline — it
    hangs indefinitely rather than failing fast, needs an external
    `timeout` wrapper in any context where network isn't guaranteed.
  - **Settled the open Codex git-trust question** from the earlier
    Supervisor-agent entry: `--skip-git-repo-check` is the standing
    pattern for ephemeral/non-repo delegation (confirmed clean on
    this tier's sandbox test); real project directories already
    satisfy the check via their own `git init`, so neither flag is
    needed there.
  - One correction to the earlier bubblewrap/sandbox-mode note:
    Codex's `workspace-write` vs `read-only` default is NOT fixed by
    invocation mode as first assumed — a direct-shell test showed
    `workspace-write` where the dashboard test showed `read-only`,
    same Codex version. Current best explanation is piped-stdin vs
    TTY. Practical rule either way: always pass `--sandbox
    workspace-write` explicitly for any write-intended call.


- **Supervisor agent, Claude Code half: confirmed working.** Hermes
  delegates to an already-authenticated Claude Code session via its
  official `claude-code` skill — `claude -p "task" --allowedTools
  Read,Edit --max-turns N` through the terminal tool — reusing the
  exact Max subscription login already proven this week, no new auth,
  no ban risk (the safe path, not the OAuth-provider one ruled out
  below). Confirmed with a real response from `claude-opus-5[1m]`,
  no login prompt. Getting there required extending the official
  Hermes image with a custom Dockerfile and fixing three real bugs
  along the way — a wrong mount-path guess (corrected by asking
  Hermes to introspect its own `$HOME` rather than assuming), a
  stale build cache silently masking a completely failed install,
  and `/root`'s default permissions blocking any non-root process
  from reaching the installed binary at all. Full recipe and the
  debugging story in `local_models.md`. Codex's half uses the same
  credential-reuse mechanism and is now ALSO confirmed working —
  see the entry below.

- **Supervisor agent, Codex half: confirmed working.**
  Hermes delegates to an already-authenticated Codex session via
  `codex exec "task"` through the terminal tool — reusing the exact
  ChatGPT-plan login already proven, no new auth. Confirmed with a
  real response (`CODEX DELEGATION OK`), no login prompt, from a
  totally fresh build on a laptop whose workspace and Docker state
  had both been wiped to zero first.

  **What actually happened, vs. what was anticipated in advance:**
  the pre-recorded `pty=true` requirement and the git-repository
  requirement were both real and both confirmed. The anticipated
  bubblewrap uid-map error (seen previously in `dev.yaml`'s boundary
  test) did NOT appear in this container — and a later dashboard
  run's raw output closed the question by observation: Codex warns
  it can't find bubblewrap on PATH and falls back to its bundled
  copy, sandboxing as read-only, and the call succeeds. Graceful
  degradation, not the fatal uid-map failure. One genuinely new finding neither prediction
  covered: Hermes's own terminal tool errors (exit 126) on a raw
  top-level `cmd1 && cmd2` chain — unrelated to Codex, a Hermes
  wrapper quirk — fixed by wrapping the whole chain as one string:
  `bash -c "cmd1 && cmd2 && cmd3"`. Applies to any multi-command
  delegation through Hermes, Claude or Codex alike.

  On the git-repository requirement specifically: confirmed that
  `git init` in the target directory before the exec call works.
  Also confirmed `codex exec --skip-git-repo-check` exists as an
  alternative that skips the requirement outright — worth
  considering as the standing pattern given the container is
  ephemeral (`run --rm`) and gets a fresh filesystem on every single
  launch, meaning a bare `git init` approach means re-doing it every
  time. **Open follow-up:** which of the two is the one actually
  in use going forward hasn't been settled — decide and update
  `hermes_codex.yaml`'s comment once it has.

  The billing question is CLOSED, though not via `/status`: running
  `codex /status` through Hermes's terminal tool fails with "stdin
  is not a terminal" — it's an interactive-TUI slash command, not
  scriptable via exec. But the answer was already in hand from the
  container-side `auth.json` inspection: `auth_mode: "chatgpt"` with
  `OPENAI_API_KEY: null` — direct evidence it authenticates via the
  ChatGPT subscription, not an API key.

  **Dashboard combination ALSO confirmed, same day:**
  `hermes_dashboard_with_codex.yaml` returned `CODEX DASHBOARD OK`
  through the persistent gateway with no login prompt — the third
  profile now claiming port 9119. All Codex pieces are now embedded
  in `setup.sh` (`hermes_codex.Dockerfile`, both yamls; the
  static-musl-binary install needed no `/root` permissions fix,
  unlike Claude's — see `local_models.md`), and `run.sh` gained a
  `dashboard_codex` target. Both halves of the supervisor-agent
  idea, in both ephemeral and persistent form, are done.

- **Claude Code subscription auth: confirmed working end-to-end,
  plus two bootstrap bugs found and fixed along the way.** The
  `claude-home` persistence mount (host-visible bind mounts, not a
  Docker-managed volume) now confirmed to survive `--force-recreate`
  without re-prompting for login — the actual property it exists to
  guarantee. Along the way: (1) the placeholder `claude-home.json`
  was being `touch`'d into a genuinely empty file, which crashes
  Claude Code's first launch with a JSON parse error — fixed by
  seeding `{}` instead; (2) the first attempt at that fix
  unconditionally overwrote the file on every bootstrap re-run,
  silently wiping a real login — fixed with a guard that only seeds
  `{}` if the file is missing or still empty. Full detail in
  `authentication.md`'s two newest addenda.

- **Codex CLI subscription auth: confirmed working end-to-end,
  root cause found after two sessions of debugging.** Login via
  `codex login --device-auth` (device-code flow — the default
  browser flow's `localhost:1455` callback can never reach a
  container; prerequisite: enable device code authorization in
  ChatGPT Security Settings). Billing confirmed against the ChatGPT
  plan, not API metering (`/status` shows the plan and monthly-limit
  bar; `/usage` shows lifetime tokens and streaks). The persistence
  bug — login never surviving a recreate despite a
  verified-working bind mount — was Codex's
  `cli_auth_credentials_store` defaulting to `"auto"`, which routed
  the credential to a store that died with the container instead of
  writing `auth.json` to the mounted path. Fix: seed
  `cli_auth_credentials_store = "file"` into
  `~/.secrets/codex-home/config.toml` **before** the first login.
  Ruled out along the way, with evidence: broken mount (host and
  container byte-identical, three checks), hostname-tied credential
  (hostname changed across recreates, `installation_id` didn't,
  behavior uncorrelated). Now baked into `setup.sh` /
  `reference/getting_started.md` (guarded seeding + the `codex-home` mount in
  all four profiles) with `setup.bats` regression tests. Full detail
  in `authentication.md`.

- **Both agents verified against the real mount boundaries, from
  inside a live session.** Claude Code, in a real working session,
  confirmed the architecture's core promises from the agent's own
  perspective: `/vault` listing shows every curated folder and no
  `personal/` at all; writing to `/vault/programming` fails
  (read-only, kernel-enforced); writing to `/vault/agent_inbox`
  succeeds. The design goal from day one — "run AI agents for dev
  work without exposing personal data" — demonstrated working, not
  just configured.

- **Third agent verified: Hermes + Ollama (local tier) passed the
  same boundary test — and surfaced three independent enforcement
  layers.** Hermes's own write allowlist
  (`HERMES_WRITE_SAFE_ROOT`, extended to include the inbox), Unix
  permissions (tools run as uid 10000; host inbox needed one-time
  `chmod o+w`), and the kernel's read-only mounts (verified through
  the terminal tool, which bypasses Hermes's allowlist — proving the
  mount layer isn't redundant). `personal/` absent from every
  listing. The isolation is now demonstrated to be a property of the
  container, not the agent: cloud subscription agents and a local
  5B model all inherit identical walls. Full detail in
  `local_models.md`.

*(nothing else yet)*


---

## Resolved — Codex sandbox saga

### Resolved: Codex-via-Hermes write failures (both machines) — root-caused and fixed

The "laptop mystery" (Codex writes failing via Hermes despite the
git-trust fix) is closed, and it turned out to be TWO stacked causes,
neither machine-specific in the way originally assumed:

1. **Daemon seccomp blocked user namespaces.** Codex's
   `--sandbox workspace-write` on Linux is bubblewrap, which must
   create an unprivileged user namespace — and the docker daemon's
   default seccomp profile blocks that on BOTH machines (proven:
   `unshare -U` → "Operation not permitted" under the default
   profile, OK under `seccomp=unconfined`; `danger-full-access`
   always worked because it skips sandbox construction entirely).
   Fix: `security_opt: [seccomp=unconfined]` on the six
   codex-capable compose files (`hermes_codex`, `hermes_all`, both
   codex dashboards, `dev`, `sandbox` — deliberately NOT
   `docs`/`review`, which are offline by design).
2. **The "bundled bubblewrap" is a lie in these images.** Codex
   0.147.0's startup warning promises a bundled bwrap fallback; at
   shell-launch time it panics instead
   (`linux-sandbox/src/launcher.rs`: "no system bwrap was found on
   PATH and no bundled codex-resources/bwrap binary was found next
   to the Codex executable" — RUST_LOG=debug trace, MSI-PC). The
   laptop passed after fix 1 alone because its 6.6 kernel carries
   codex's `apply_patch`/Landlock write leg; MSI-PC's 5.15 kernel
   (Landlock ABI v1) does not, so it needed the shell leg working —
   i.e. real bwrap. Fix: system `bubblewrap` baked into all three
   codex-capable Dockerfiles (`agent`, `hermes_codex`, `hermes_all`).

Also fixed while in there: **codex is version-pinned everywhere**
(`ARG CODEX_VERSION=rust-v0.147.0` for the musl binaries,
`@openai/codex@0.147.0` for npm) — `releases/latest` floated, so two
images built hours apart could silently diverge; during this
investigation identical-version-across-images was luck, not
guarantee. Bump deliberately, retest the workspace-write delegation,
then update the tag.

**Acceptance, host-verified ** the exact
originally-failing delegation
(`codex exec --skip-git-repo-check --sandbox workspace-write`,
workdir=/vault/agent_inbox) writes successfully on BOTH machines,
through BOTH ephemeral `hermes_all` AND `dashboard_all`, on a fresh
workspace — plus Claude and Hermes's own `write_file` into the new
inbox subfolders. Full matrix green. MSI-PC closed WITHOUT the
kernel update (bwrap alone carried it); `wsl --update` off 5.15
remains optional hygiene there, no longer load-bearing.

Guards added: 11 health_check checks, 8 bats tests (suite 130→138),
root-cause comments in `hermes_codex.yaml` and the Dockerfiles.

### Resolved: agent_inbox output subfolders

`reports/`, `research/`, `sessions/` inside `agent_inbox` — report
organization WITHOUT a second writable root (single-funnel design
deliberately kept; extending `HERMES_WRITE_SAFE_ROOT` was considered
and declined). Writable by every tool automatically because
permissions live on the MOUNT, not per-folder. Embedded in setup.sh
(mkdir phase + .gitkeeps tracked by the inbox's nested repo + health
checks + bats), so DR drills recreate them. Codex rule: keep
`workdir=/vault/agent_inbox` (the `.git` root, for the trust check)
and put the subfolder in the relative filename — `reports/foo.md`.

---

## 1. features.md — new entry

### Resolved: ddgs/uv build break in hermes_claude, hermes_codex, hermes_all Dockerfiles

The shared ddgs install step (`uv pip install --python ... ddgs`) started
failing with `uv: not found` (exit 127) across all three hermes
Dockerfiles. Root cause: `nousresearch/hermes-agent:latest` is unpinned
and silently stopped shipping `uv` on PATH. Fix — an explicit uv install
inserted immediately before the ddgs RUN block in each Dockerfile:

```dockerfile
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
    && mv /root/.local/bin/uv /usr/local/bin/uv
```

Applied to all three live Dockerfiles (confirmed via the `astral.sh`
marker) and to the matching heredocs embedded in `setup.sh`, so a future
fresh bootstrap or DR regeneration produces already-correct Dockerfiles
instead of reproducing the break.

Guarded by a new `setup.bats` test asserting the install step is present
in all three Dockerfiles *and* comes before the ddgs line — not just
present somewhere in the file. The pre-existing ddgs tests only checked
the ddgs line itself and would not have caught this regression.

---

### Open: Codex CLI delegation — model whitelist + code_mode_host failures (not fully root-caused)

Two distinct failures hit in sequence testing Codex CLI delegation
through Hermes:

1. `The '<model>' model is not supported when using Codex with a ChatGPT
   account.` — OpenAI-side issue, not project-specific: newly-released
   models in Codex's picker aren't always whitelisted yet for
   ChatGPT-subscription login. Seen with several different model names
   in the wild. Workaround: pin an older, established model explicitly
   (`-m gpt-5.1-codex` or similar).

2. `The workspace execution tool failed to start because
   codex-code-mode-host was unavailable.` — hit when delegating against
   the `hermes_dashboard_with_all` long-running profile. Two possible
   causes, not yet distinguished:
   - a `code_mode_host = false` toggle under `[features]` in
     `~/.codex/config.toml`
   - the `codex-code-mode-host` companion binary never getting
     installed, since this project's Dockerfiles pull a raw pinned musl
     `codex` binary rather than installing via the official npm
     package/installer — possibly the only install path that bundles
     the companion executable

   Diagnostic, not yet run:
```bash
   cat ~/.codex/config.toml | grep -A2 "\[features\]"
   command -v codex
   ls -la "$(dirname "$(command -v codex)")" | grep -i code-mode
```
   Also confirm the dashboard container was actually recreated
   (`docker inspect <container> --format '{{.Created}}'`), not just
   restarted — `up -d` profiles keep their birth-time image/settings
   until an explicit `down` + relaunch.

   The error stopped reproducing after rephrasing the delegation
   instruction, without confirming which (if any) of the above was the
   real cause. Treat as unresolved/intermittent, not fixed.

---

## 2. delegation_phrasing.md — addition

> **Literal-instruction-echo risk:** asking a CLI to "write the text 'X'
> to file Y" can result in the entire instruction sentence landing in
> the file instead of just X. Phrasing that separates the destination
> from the exact content avoids this — e.g. "create file Y containing
> exactly this one line: X" rather than "write the text 'X' to file Y".

---

## 3. hermes_operations.md (or wherever CLI troubleshooting lives) — addition

> **Claude Code CLI: "Failed to authenticate: OAuth session expired and
> could not be refreshed"** — check host vs. container clock skew
> first: `date` on host vs. `docker exec <container> date`. WSL2
> containers can drift after sleep/resume, and OAuth validation is
> time-sensitive, so a valid session can read as expired. If clocks
> match, it's a genuine expired session — re-login as the hermes user
> so refreshed credentials land in the mounted secrets path:
> `docker exec -it -u 1000 -e HOME=/opt/data/home <container> claude`
> and follow the login prompt.
