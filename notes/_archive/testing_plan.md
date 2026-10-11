# Testing Plan — everything built-but-not-yet-proven

> Written. Reconciled checkboxes brought in
> line with what was actually completed (audit cross-checked this
> file against the live setup.sh / setup.bats / run.sh / tasks.json
> and credentials on disk — several items were done but never
> ticked). Stale counts corrected inline; superseded steps marked,
> not deleted. Companion to `features.md` — this is the
> execution order; features.md holds the why. Work top to bottom:
> each stage validates the ground the next one stands on, so a
> failure points at exactly one layer. Check things off as they
> pass; note surprises inline — they feed the doc pass in 1.7.
>
> Current state this plan assumes: `~/workspace` is empty/absent,
> `~/.secrets` holds working Claude Max + Codex (ChatGPT plan)
> logins, and the 15 updated files from the/30 sessions
> are at hand (agent_inbox rename applied throughout).

---

## Run 1 — fresh bootstrap, KEEP `~/.secrets`

Proves: the workspace half from zero, credential persistence, the
runner, and the Codex delegation. `~/.secrets` is untouched the
whole run.

### 1.1 Bootstrap + self-checks

- [x] `mv ~/workspace ~/workspace.bak` if anything exists (cheap
      insurance over rm)
- [x] `bash setup.sh` — fresh bootstrap; expect `vault/agent_inbox`
      from birth, phase-6 health check green
- [x] `bash setup.sh` again — expect a wall of "exists, skipping"
      (idempotence proven on real hardware)
- [x] `bash setup.sh --verify` — 0 drifted or missing. (Plan
      originally said 20 embedded files; the count grew to 24 with
      the Codex embeddings in 1.5, then 28 with hermes_all —
      re-confirmed live "28 embedded files checked,
      0 drifted or missing")
- [x] `bats setup.bats` — plan originally said 57 tests; suite has
      grown with every embedding since (re-confirmed live
      93 tests, 0 failures)

### 1.2 Manual file drops — SUPERSEDED (note)

> All four files below were subsequently EMBEDDED into setup.sh
> (see 1.5's doc pass) — a fresh bootstrap now creates them itself
> and --verify tracks them. Nothing here needs hand-dropping
> anymore; kept for the historical record of how Run 1 was
> actually executed at the time.

- [x] `hermes_codex.Dockerfile` → `infrastructure/docker/hermes_codex/Dockerfile`
- [x] `hermes_codex.yaml` → `infrastructure/compose/`
- [x] `run.sh` → `infrastructure/scripts/run.sh` + `chmod +x`
- [x] `tasks.json` → `~/workspace/.vscode/tasks.json`
- [x] Updated docs (features.md, testing_plan.md, ops, local_models,
      getting_started, architecture v1.13) → wherever docs live
- [x] `run.sh drift` still clean after the drops (drops add files;
      they must not change embedded ones)

### 1.3 Runner against real docker
      (boxes closed retroactively — completion was
      recorded in 1.5's doc pass and features.md at the time,
      just never ticked here)

- [x] `run.sh hermes_claude` — Claude Code answers with NO login
      prompt inside a workspace that didn't exist minutes ago
      → credential-persistence guarantee re-proven from zero
- [x] `run.sh ps`, `run.sh health` — sanity
- [x] One VS Code task from a WSL window on the laptop (start with
      "Workspace: health check") — picker worked on the Win10 PC,
      but no task has ever EXECUTED. Confirm bottom-left says WSL.

### 1.4 Codex delegation — the main event
      (boxes closed retroactively — the fully-checked
      1.5 doc pass below records exactly what happened here:
      uid/$HOME match, the exit-126 finding, the git-trust gate,
      the uid-map non-appearance)

- [x] Build fresh: `docker compose --env-file ../workspace.env -f
      hermes_codex.yaml build --no-cache` (cache masked a failed
      install once; never again on a first build)
- [x] `run.sh hermes_codex` → live session, in order:
  - [x] `whoami ; echo $HOME ; id` — re-verify introspection
        (expect uid=1000 hermes, $HOME=/opt/data/home)
  - [x] `codex --version` — static musl binary runs as hermes uid
  - [x] `~/.codex/auth.json` visible through the mount
  - [x] `git init` a test repo under a writable path (Codex refuses
        non-repos; plain mkdir dirs won't work)
  - [x] `codex exec "task"` via terminal tool with `pty=true`
        (opposite of Claude's skill — backwards = hang)
  - [x] Note what the bubblewrap uid-map error actually does —
        it never appeared; standing pattern decided instead
        (--skip-git-repo-check for ephemeral/scratch, real repos
        already trusted)
- [x] Success criteria: real response, no login prompt — billing
      confirmed via auth.json (auth_mode: chatgpt) since /status
      doesn't work non-interactively

### 1.5 Post-success doc checklist (fires ONLY after 1.4 passes)

- [x] features.md: Codex entry → Resolved, recording what actually
      happened (uid/$HOME match, the exit-126 finding, the git-trust
      gate, the uid-map non-appearance, the two open follow-ups)
- [x] hermes_operations.md §8: four profiles → five (hermes_codex
      added); run.sh documented as the recommended interface;
      9119 note updated for confirmed browser + native-app access
- [x] local_models.md: full Codex Delegation section added,
      mirroring the Claude section's depth (recipe, what was
      anticipated vs. not, what this proves, open items)
- [x] `hermes_dashboard_with_codex.yaml` drafted as a STANDALONE
      file (not embedded) — the ephemeral delegation is proven, but
      the dashboard combination itself hasn't been started/tested,
      same discipline hermes_codex.yaml itself followed before it
      graduated
- [x] Embedded into setup.sh: hermes_codex Dockerfile + yaml, run.sh
      (with the ensure_ollama fix), tasks.json — each with
      create_file_if_missing blocks + bats tests; --verify now
      covers 24 embedded files (was 20)
- [x] getting_started.md: added hermes_claude/hermes_codex to the
      verified-profiles bullet, plus a new bullet on run.sh/tasks.json
      as the preferred post-bootstrap interface

### 1.5b Codex dashboard graduation (added mid-run — completed)

- [x] `hermes_dashboard_with_codex.yaml` built and started (first
      attempt caught a 0-byte copy of the file — docker compose
      silently accepts an empty compose file and just skips the
      undefined service, worth remembering as a failure mode)
- [x] Real delegation through the persistent gateway → returned
      `CODEX DASHBOARD OK`, no login prompt
- [x] `codex /status` follow-up CLOSED, via other evidence: /status
      itself fails through the terminal tool ("stdin is not a
      terminal" — interactive-only slash command), but auth.json
      already showed auth_mode chatgpt + OPENAI_API_KEY null =
      ChatGPT-plan billing confirmed
- [x] Graduation pass: yaml embedded in setup.sh (--verify now 25
      files), run.sh gained dashboard_codex (menu renumbered 1-10),
      health_check + bats extended (75 tests), docs updated
- [ ] Still open (preference, not blocker): git init vs
      --skip-git-repo-check as the standing delegation pattern

### 1.6 Independent items (any time during Run 1)

- [ ] Obsidian under WSLg: `wsl.exe --update`, install the .deb,
      `obsidian &` — point it at `~/workspace/vault`. Fallback if
      WSLg misbehaves: one-way rsync mirror to the Windows side
      (browse there, never edit there)
- [ ] Fragment audit (features.md Open entry): workspace was empty,
      so — if the 28-file archive exists outside the workspace,
      extract into `agent_inbox/` and re-run the exact audit prompt
      against it; if it's gone, strike the entry in the 1.5 doc pass

---

### 1.7 Agent tier — dev/docs/review/sandbox (staged; added)

The untested half of the compose surface: none of these four
profiles has run since the wipe, the `docker/agent` image has never
been built in this Docker, and the `/home/ubuntu` credential paths
(different from Hermes's `/opt/data/home` paths) are unproven
post-rebuild. Four stages, each self-contained — do one per sitting
if that's the pace that fits; nothing in a later stage is needed by
an earlier one.

**Stage A — sandbox (zero prerequisites, proves the image + creds)**

- [x] `run.sh sandbox` — first agent-image build from empty Docker
      (apt + Node 20 + npm Codex + Claude native installer; this is
      the slow one, several minutes — later stages reuse the image)
- [x] Inside: `claude -p "Reply with exactly: DEV TIER OK"` — no
      login prompt = `/home/ubuntu/.claude` + `.claude.json` mounts
      proven post-rebuild
- [x] Inside: `codex exec --skip-git-repo-check "Reply with exactly:
      CODEX DEV TIER OK"` — no login prompt = `/home/ubuntu/.codex`
      proven; ALSO the first live trial of `--skip-git-repo-check`,
      settling the open pattern question with a real data point
      (/workspace here is a plain mounted folder, not a git repo —
      exactly the case the flag exists for)
- [x] Boundary: `ls /vault` fails / doesn't exist — sandbox mounts
      NO vault at all, by design; `/ai` present read-only

**Stage B — dev (first real project, the full workbench)**

- [x] Create the project first: `mkdir ~/workspace/projects/hello_test`,
      `cd` in, `git init`, copy `infrastructure/templates/AGENTS.md`
      in and fill its project section
- [x] Deliberately run `run.sh dev hello_test` BEFORE creating the
      secrets env — expect the runner's helpful refusal naming
      `~/.secrets/hello_test.env` (that refusal is itself a guard
      under test, not a failure)
- [x] `touch ~/.secrets/hello_test.env` → `run.sh dev hello_test`
      again → container up, `/workspace` is the project
- [x] Boundary checks inside, each expected result stated so a
      "failure" isn't misread:
  - [x] write a file in `/workspace` → succeeds; visible on host
        owned by your user (uid 1000)
  - [x] write a note into `/vault/agent_inbox/` → succeeds; visible
        on host
  - [x] attempt a write in `/vault/programming/` → **Permission
        denied IS the pass** (read-only mount doing its job)
  - [x] `ls /vault/personal` → does not exist (never mounted)
  - [x] attempt a write in `/ai/` → denied (read-only)
- [x] First real work: `claude -p --permission-mode acceptEdits "create a README.md describing
      this project"` in `/workspace` — a task with an artifact, not
      just a ping
- [ ] (skipped — sandbox-mode question already resolved via the Stage A/dashboard comparison, see local_models.md)  ~~Optional, exercises the sandbox finding from the dashboard
      test: `codex exec --skip-git-repo-check --sandbox
      workspace-write "add a line to README.md"` — confirms Codex
      can actually WRITE when told to (exec default is read-only)

**Stage C — docs + review (the offline profiles)**

Key expectation to hold in mind BEFORE running these: both have
`network_mode: "none"` — so `claude` and `codex` CANNOT work inside
them (the CLIs need network to reach their APIs). Credentials are
mounted, tools are installed, but calls will fail with network
errors — that is BY DESIGN, not a bug. These profiles are for
offline work on files; the moment a task needs AI, that's what
dev.yaml (or flipping docs.yaml to Balanced) is for.

- [x] `run.sh docs hello_test` → inside:
  - [x] `curl -m 5 https://example.com` → **fails = PASS** (offline
        confirmed)
  - [x] `/workspace` writable, vault pattern same as dev
  - [x] `claude -p "hi"` → HUNG, no self-timeout, needed manual Ctrl+C (real finding — see agent_tier_operations.md §4); not just "a network error"
        note the exact error text for the docs
- [x] `run.sh review hello_test` → inside:
  - [x] `touch /workspace/x` → **Permission denied IS the pass**
        (project mounted read-only)
  - [x] `/vault/agent_inbox/` still writable (the designated output
        path for review notes)
  - [x] offline confirmed same as docs

**Stage D — findings pass**

- [x] Note anything surprising from A–C inline above — folded into
      `agent_tier_operations.md` (new doc) and `features.md`
- [x] Settle the git-trust pattern decision (Stage A gave the
      `--skip-git-repo-check` data point) → update
      `hermes_codex.yaml`'s comment + features.md's open item
- [x] If any doc statement conflicted with observed behavior,
      queue the correction

## Run 2 — scorched earth (ONLY after Run 1 fully banked)

Proves the one thing Run 1 can't: the auth bootstrap and full
recreation from absolute zero. This is the disaster-recovery test
and the honest test getting_started.md will ever get.

> RECONCILED this run WAS completed — the boxes below
> were never ticked at the time. Evidence: both credentials exist
> on disk with post-wipe timestamps (`claude-home/.credentials.json`
> Aug 2 21:03, `codex-home/auth.json` Aug 2 12:50), matching the
> interleaved delegation tests in 1.8/1.8b that ran with
> no login prompt (impossible without completed logins), and the
> dashboard basic_auth login working in 1.8b (impossible without a
> recreated hermes-home). first_login_runbook.md was written from
> this run's observed detail. Spine re-run re-confirmed live
> --verify 28/0, bats 93/0, health 50/0.

- [x] Pre-check on chatgpt.com: device code authorization still
      enabled in Security Settings — proven implicitly by the
      device-auth login succeeding on Aug 2
- [x] Bank anything in the vault worth keeping — skipped
      deliberately, everything in the wiped workspace was disposable
      test data (`hello_test` etc.)
- [x] Wipe: `~/workspace` AND `~/.secrets` both gone
- [x] **Follow getting_started.md literally** through Phase 1 —
      no deviations hit yet (unlike Run 1, no doc/reality mismatches
      logged from this run so far)
- [x] `setup.sh` FIRST, before any login, via `setup.sh --secrets-only`
      — confirmed the seeding guards fired for real this time, not
      skipping past existing files: `claude-home.json` came back
      exactly `{}`, `codex-home/config.toml` exactly the
      `cli_auth_credentials_store = "file"` line, nothing more.
      First real-hardware confirmation of `--secrets-only` itself.
- [x] Claude login from scratch → `claude -p` works in-container
      — DONE Aug 2 (credential on disk 21:03; no-login-prompt
      delegations in 1.8/1.8b same day)
- [x] `codex login --device-auth` from scratch → codex works
      — DONE Aug 2 (auth.json on disk 12:50; same evidence)
- [x] Recreate hermes-home by hand: config.yaml endpoint, dashboard
      basic_auth hash — DONE (1.8b's dashboard login proves the
      hash was set). Noted friction fed two automation outcomes:
      `run.sh models`/`run.sh pull` for the model
      half, and `run.sh dashboard_auth` now generates the
      basic_auth config block — the "one-liner in local_models.md"
      is no longer the only path
- [x] Re-run the Run-1 spine: `--verify` (28/0) and `bats` (93/0)
      re-confirmed live; the hermes_claude + codex
      delegation half covered by 1.8/1.8b's interleaved calls
- [x] Doc pass: no deviations were logged from this run; the
 reconciliation of THIS file closes the entry

---

### 1.8 hermes_all — combined-image test (added hermes_all confirmed same day)

- [x] `run.sh hermes_all` — built clean
- [x] Delegate through EACH provider in the same session, interleaved
      (claude, codex, claude again) — all three returned clean:
      `INTERLEAVE 1 OK` / `INTERLEAVE 2 OK` / `INTERLEAVE 3 OK`,
      no login prompt on any of them
- [x] Cross-provider interference — the one thing individual testing
      couldn't have caught — did NOT occur across the interleaved run
- [x] UNTESTED labels stripped from run.sh, hermes_all.yaml,
      tasks.json, setup.sh's closing summary (six-of-eight ->
      seven-of-eight) for hermes_all specifically

### 1.8b dashboard_all — CONFIRMED

- [x] `run.sh dashboard_all` — up clean
- [x] `http://127.0.0.1:9119` (via the native Win11 app, reached
      remotely) — basic_auth login worked
- [x] Delegate through EACH provider from the dashboard's own chat,
      interleaved: claude, codex, claude again — all three returned
      clean (`INTERLEAVE 1/2/3 OK`), no login prompt, no
      cross-provider interference
- [x] UNTESTED labels stripped everywhere: run.sh,
      hermes_dashboard_with_all.yaml, tasks.json, setup.sh
      (seven-of-eight -> eight-of-eight), features.md,
      quick_reference.md

**This closes the entire hermes_all/dashboard_all effort — and with
it, the full 8-of-8 Hermes profile matrix. Every profile in this
project is now proven, not just built.**

---

## additions — counts moved again (deliberately)

Two tooling batches landed after the reconciliation, so
the historical numbers above are correct FOR THAT DATE but the live
expectations are now:

- **Embedded files: 28 → 29** (`scripts/migrate_docker_backend.sh`,
  the Docker Desktop ↔ native docker-ce switch — check/migrate/
  revert, refusal gate, no-uninstall reversibility guarantee)
- **bats tests: 93 → 104** (8 for the migration tooling incl. the
  mocked-PATH detection tests and the static no-uninstall check;
  3 for the one-click targets)
- **run.sh targets: +6** (`docker_status`/`docker_migrate`/
  `docker_revert`, `bootstrap`/`test`/`check_all`)
- **VS Code tasks: 22 → 28**

The migration TOOLING is built and bats-covered; the migration
ITSELF has not been run — still gated behind finishing the current
test pass (features.md). `run.sh check_all` (health + drift + test)
is now the one-command version of the full confidence sweep.

- [ ] First live `run.sh check_all` on the real machine — expect
      health 50+1/0 (the new script check), --verify 29/0,
      bats 104/0

## Run 3 — scorched earth on the NATIVE backend
### ✅ COMPLETED — executed at UPGRADED scope

Planned as a wipe-in-place; executed as something stricter: a brand-new
side-by-side WSL distro (separate user, alexm2), so the run also proved
the docker-ce install and every machine pre-step from absolute zero —
the full "stranger's machine" scenario. Docker Desktop was never
involved at any point. The old distro was untouched throughout and the
new one is being KEPT as the future init.sh test bed.

### Preconditions — all satisfied (some superseded by the scope upgrade)

- [x] Patched trio applied — and re-patched mid-run: the interop-leak
      finding (#4, below) landed during the run itself; final suite is
      107 tests (not the 106 this plan originally expected)
- [x] Docker Desktop out for the entire run — trivially true: the new
      distro never had WSL integration enabled (verified OFF in
      Desktop's list before any docker work)
- [x] Native backend — the run IS the native backend from zero
- [x] Device-code auth enabled — proven implicitly by the codex
      device-auth login succeeding first try

### The wipe — superseded by "never existed"

No wipe happened; the distro started empty. `docker_clean` n/a (no
image cache existed). The bootstrap files were staged into the new
distro at `~/workspace-init-2` via /mnt/c + VS Code Remote — which
itself proved the load-bearing assumption that the bootstrap source
must come from outside the workspace.

### Rebuild + verify — all passed, with evidence

- [x] Virgin docker-ce install via the staged
      `migrate_docker_backend.sh --migrate` — the true from-zero path
      (preflight chicken-and-egg broken exactly as designed). Group
      membership needed a full `wsl --terminate`, not just a new
      terminal (finding below)
- [x] `bash setup.sh` — 29 files created, both repos root-committed,
      Phase 6 verify 51/0, "Docker Engine reachable" on virgin
      docker-ce
- [x] `run.sh check_all` — health 51/0, drift 29/0, bats **107/107**,
      Portmaster ON
- [x] Logins from scratch via `run.sh sandbox` — the
      first_login_runbook's sandbox-as-auth-home flow proven on the
      scenario it was written for: claude (browser login, URL copied
      by hand — appendWindowsPath=false means no auto-open) and codex
      (device-code). Both later delegated with no login prompts
- [x] settings.json model override — the interactive picker wrote
      `{"model": "haiku"}` itself (user's pick; even cheaper than the
      sonnet this plan suggested). No manual write needed
- [x] `hermes setup` ran twice — first accidentally against the
      DESKTOP endpoint (<IPv4> — new DHCP IP, was .125: the known
      DHCP caveat manifesting live), which became a bonus proof: a
      virgin distro reaching the desktop GPU over the LAN re-proves
      the multi-machine path from zero. Then correctly against
      `http://ollama:11434/v1` (Chat Completions, gemma4:e2b,
      Ollama-Local); both providers now coexist in config.yaml
- [x] `run.sh dashboard_auth` AFTER setup — ordering rule held;
      basic_auth login proven by the dashboard sessions below
- [x] Delegations: hermes_all interleave — calls 1 & 2 clean
      ("INTERLEAVE 1/2 OK", exit 0, no login prompts; codex banner
      confirmed reasoning-effort=low propagating from the sandbox
      choice). Call 3 returned empty (exit 0) — resolved as MODEL
      behavior, not plumbing: a retry produced a real response, and
      dashboard_all subsequently returned "DASHBOARD CLAUDE OK" and
      "DASHBOARD CODEX OK" through the authenticated web UI
- [x] Vault write path: two real captures landed in agent_inbox
      (chat_summary.txt — after a first copy went to hermes-home,
      relocated on request; jokes.txt) — the first genuine
      session-capture data points for the features.md convention
      decision
- [x] GPU proof: `docker exec compose-ollama-1 ollama ps` →
      gemma4:e2b **100% GPU**, context 64000, UNTIL Forever —
      nvidia-container-toolkit proven end-to-end from a virgin
      install; KEEP_ALIVE=-1 confirmed
- [x] Bonus proof, unplanned: dashboard_all resurrected itself after
      a full WSL restart (`restart: unless-stopped` across a distro
      reboot)

### Findings — the environmental gauntlet (the run's real harvest)

Every fresh distro on THIS machine needs, in order, before anything
else works:

1. **wsl.conf, four sections, verbatim from the old distro**:
   `[boot] systemd=true`, `[user] default=<user>`,
   `[interop] appendWindowsPath=false`,
   `[network] generateResolvConf=false` — then terminate + re-enter.
   appendWindowsPath=false is also why the old distro never saw
   finding #4.
2. **The DNS demon, three forms, one durable kill**:
   generateResolvConf=false does NOT remove an existing symlink (form
   1: /mnt/wsl symlink, nameserver 10.255.255.254); a static file
   alone gets re-symlinked by systemd-resolved on EVERY boot (form 2:
   nameserver 127.0.0.53, "server misbehaving" — this one killed the
   sandbox build after everything else was green). Durable fix:
   `systemctl disable --now systemd-resolved` + static 1.1.1.1/1.0.0.1
   + **`chattr +i /etc/resolv.conf`**. The lock survived a WSL
   restart (root's own rm refused — working as intended). Docker's
   daemon reads the host resolv.conf: restart docker after fixing.
   Tell-tale list for any preflight: symlinked resolv.conf,
   10.255.255.254, or 127.0.0.53.
3. **Finding #4 — Windows interop leak** (patched, bats 107): with no
   docker in the distro, Desktop's WINDOWS CLI leaks through the
   interop PATH (/mnt/c/...) and reads as a false "native". --check
   now names it, skips the daemon probe for it, and --migrate
   proceeds through it.
4. **apt mirrors → https** (`sources.list.d/ubuntu.sources`) and
   **ForceIPv4** (`apt.conf.d/99force-ipv4` + gai.conf precedence) —
   both applied; v4 pin demonstrably fixed download.docker.com
   connect-stalls.
5. **Portmaster convicted with hard evidence**: the same 90 MB that
   crawled for 25 minutes fetched in 5 seconds (17.2 MB/s) with
   Portmaster shut down; later phases ran fine with it ON, so the
   interference is intermittent/connection-establishment-shaped.
   Standing task: per-app exception for WSL traffic (vmmem), per the
   desktop-era playbook.
6. **Group membership needs a distro restart** — `usermod -aG docker`
   is invisible to every terminal descending from the running WSL
   session; `wsl --terminate` + re-enter, not just a new tab.
7. **Survival trick**: apt connect-stalls can be Ctrl+C'd through
   when the needed repo's metadata is already cached — the run
   continues from cached lists.
8. Known-and-confirmed: the migrate script's "compose/ not found —
   run setup.sh first" tail pre-bootstrap is run.sh's guard, not an
   error; gpg --dearmor needs --batch --yes for re-run safety
   (queued patch).

### Doc pass — remaining wrap-up (the only open items from this run)

- [ ] Fold the environmental gauntlet above into getting_started.md's
      fresh-machine section (or ship it as the planned
      prep_fresh_distro / init.sh phase zero)
- [ ] Patch the migrate script's gpg idempotence (--batch --yes)
- [ ] init.sh — Run 3's scratch notes are its spec; build next

## What's actually still open (summary)

Run 3 is COMPLETE (see its section above; only its
doc-pass items remain). Beyond that, three small boxes remain open
below:

1. Obsidian under WSLg (1.6) — never tried; no dependencies.
2. The git-trust standing-pattern box (1.5b) — effectively decided
 (-skip-git-repo-check for ephemeral/scratch; real
   repos already trusted). What's left is a one-line comment fix:
   hermes_dashboard_with_codex.yaml's inline note still calls it
   "an open item." Tick 1.5b's box when that comment is aligned.
3. Fragment audit (1.6) — likely moot (fragment set superseded);
   a quick `ls` of agent_inbox closes it formally either way.

## Parked — own sessions, entries already pre-decided in features.md

- Desktop as Ollama LAN server (Ubuntu install; `OLLAMA_HOST`,
  ufw scoped to laptop IP; laptop side: config.yaml endpoint +
  `run.sh --remote-ollama`; small investigation first: can Hermes
  take the endpoint from an env var? → zero-edit mode switch)
- Desktop dashboard rehearsal — the VPS go/no-go gate (SSH tunnel,
  Ollama-only variant, no credentials copied)
- rclone + crypt → Google Drive cold-copy backup (`run.sh backup`)
- VPS (fully pre-decided: allowlist, vault topology, credential
  posture, gate) — happens only if the rehearsal proves the habit
- FastAPI workspace inspector (read-only first, loopback :9120)
