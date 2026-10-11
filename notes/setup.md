# Setting Up a Fresh Machine

Two phases, run in order: `init.sh` gets the machine and workspace
bootstrapped; then a one-time login gets both CLIs authenticated.
Nothing to memorize — both phases are interactive and tell you what's
next.

## Phase 1: `init.sh`

One script, run FIRST on any machine. Detects what's missing, offers
the next step, resumes where it left off.

```
<repo>/init.sh                    the script (next to setup.sh,
<repo>/init.bats                  setup.bats, migrate_docker_backend.sh
<repo>/.vscode/tasks.json         — all four must sit together)
```

```bash
bash init.sh              # interactive: scan, then offer the next fix
bash init.sh --check      # report only — changes nothing, always exit 0
bats init.bats            # the script's own test suite (29 tests)
```

**How it goes, start to finish:**

1. `bash init.sh` → flags the first gap, asks. Say `y`.
2. If the fix needs a restart (wsl.conf write, docker install), it
   tells you: `wsl --terminate <distro>` from Windows, re-enter, run
   `bash init.sh` again. It resumes at the next gap.
3. Repeat until it prints **"All green"** — hands off to `run.sh`,
   init's job is done forever on that machine.

Order it walks (each needs the one before it): machine env (systemd,
DNS, apt/https, git identity, bats) → docker backend → workspace
(`setup.sh`) → logins → hermes config.

The workspace step also auto-copies `setup.sh` + `setup.bats` from
next to `init.sh` into `~/workspace/infrastructure/bootstrap/` after
bootstrapping — no manual copy step needed. It COPIES, never moves:
the staged files next to `init.sh` must survive, since a later
`init.sh --check` compares against them.

**Machine-aware, not just WSL-aware.** Detects WSL via
`/proc/version` before touching DNS/`wsl.conf` at all. Off-WSL (real
Ubuntu, a VM, a cloud box), it skips the WSL-specific checks —
`127.0.0.53` is the normal systemd-resolved default there, not a
symptom. The apt/network check is genuinely probe-based on any
platform: a real timed connection to the apt mirror, not just
"have the mitigation files been applied."

**What it can NOT do** (tells you exactly, with the steps):
Docker Desktop's WSL-integration toggle (Windows GUI only), the
claude/codex interactive logins (launches `run.sh sandbox` and prints
the walk — see Phase 2 below), `wsl --terminate` (Windows side),
Portmaster exceptions (its own UI).

**Everyday use after setup:** none — that's `run.sh`'s job. Re-run
`init.sh --check` only when something feels off after a
reboot/update, or on any new machine.

---

## Phase 2: First login — `run.sh sandbox`

**Sandbox is the interactive-auth home.** Zero prerequisites: no
`~/.secrets/<project>.env` guard, no vault involvement, network on,
a real interactive TTY — so `claude`/`codex` can be typed plainly and
their login flows, model pickers, and reasoning modes driven by hand.
`docs`/`review` can never do this (offline by design); `dev` adds an
env-file step for no benefit at auth time.

**Do this deliberately, not incidentally: everything set
interactively in sandbox propagates to every other profile**, because
all profiles bind-mount the same credential homes (`claude-home`,
`claude-home.json`, `codex-home`). Log in once, pick a default model,
set a reasoning-effort mode — `dev`, `docs`, `review`, and every
Hermes delegation profile inherit it. Confirmed in practice: a
reasoning-effort choice made interactively showed up in later
`codex exec` runs from the same mounts.

```bash
bash setup.sh --secrets-only     # seed empty ~/.secrets structure
run.sh sandbox                   # then, inside:
claude                           #   browser login; pick model/theme
codex login --device-auth        #   device-code login; set modes
exit
```

That's the whole normal path. The rest of this doc is the
`dev`-tier bootstrap flow (`CLAUDE_CODE_OAUTH_TOKEN` path) — only
needed to break `dev.yaml`'s chicken-and-egg (it requires a secrets
env file to exist before you can get inside to generate a token).
Skip to here only if `sandbox` genuinely isn't available yet.

### Claude Code — token bootstrap, step by step

**1. Start the container** (placeholder env file must exist first:
`: > ~/.secrets/hello-test.env`):
```bash
cd ~/workspace/infrastructure/compose
PROJECT=hello-test docker compose --env-file ../workspace.env -f dev.yaml up -d
```

**2. Generate a fresh token** — prints a URL, log in with your Max
account, terminal prints `sk-ant-oat01-...`:
```bash
PROJECT=hello-test docker compose --env-file ../workspace.env -f dev.yaml exec dev claude setup-token
```

**3. Store it, verify the byte count:**
```bash
cat > ~/.secrets/hello-test.env << 'EOF'
CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-paste-the-real-token-here
EOF
wc -c ~/.secrets/hello-test.env     # expect ~95-117, NOT 0 or 1
```

**4. Recreate, log in interactively:**
```bash
PROJECT=hello-test docker compose --env-file ../workspace.env -f dev.yaml up -d --force-recreate
PROJECT=hello-test docker compose --env-file ../workspace.env -f dev.yaml exec dev claude
```
Theme picker (pick anything) → login picker → **"Claude account with
subscription"** → browser step → `/exit`. No JSON-corruption error —
`setup.sh` seeds `claude-home.json` with `{}`.

**5. THE test** — recreate again, launch again, should go straight
into a session, no picker:
```bash
PROJECT=hello-test docker compose --env-file ../workspace.env -f dev.yaml up -d --force-recreate
PROJECT=hello-test docker compose --env-file ../workspace.env -f dev.yaml exec dev claude
```

**6. Confirm on the host:**
```bash
ls -la ~/.secrets/claude-home/     # .credentials.json, real size
```

### Codex — after Claude Code passes

**1. Start the container:**
```bash
cd ~/workspace/infrastructure/compose
PROJECT=codex/hello-test docker compose --env-file ../workspace.env -f dev.yaml up -d --force-recreate
```

**2. Sanity-check the persistence fix is in place FIRST** (seeded by
`setup.sh` — without it, login won't survive a recreate):
```bash
cat ~/.secrets/codex-home/config.toml    # must say: cli_auth_credentials_store = "file"
```

**3. Device-code login:**
```bash
PROJECT=codex/hello-test docker compose --env-file ../workspace.env -f dev.yaml exec dev codex login --device-auth
```
Open the printed URL, enter the device code, wait for "Successfully
logged in." A device-code prompt here is **expected on every fresh
setup** — the fix in step 2 is what makes it the *only* one. (The
device-code toggle may need re-enabling at
`chatgpt.com/#settings/Security` if the command complains — hasn't
always stuck between sessions.)

**4. THE check** — `auth.json` should exist on the FIRST try:
```bash
ls -la ~/.secrets/codex-home/auth.json
```

**5. Persistence test** — recreate, launch, straight in:
```bash
PROJECT=codex/hello-test docker compose --env-file ../workspace.env -f dev.yaml up -d --force-recreate
PROJECT=codex/hello-test docker compose --env-file ../workspace.env -f dev.yaml exec dev codex
```
Inside, `/status` should show your account and the monthly-limit bar
(subscription, not API). `/exit`.

---
See also: `reference/getting_started.md` (the full manual longhand
build — what `setup.sh` automates, written out step by step; only
worth opening if `init.sh`/`setup.sh` genuinely can't be trusted or
used), `authentication.md` (full reasoning and debugging history
behind every step above), `quick_reference.md` (day-to-day commands
once setup is done).
