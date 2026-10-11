# Setting Up a Fresh Machine

Two phases, run in order: `init.sh` gets the machine and workspace
bootstrapped; then a one-time login gets both CLIs authenticated.
Nothing to memorize — both phases are interactive and tell you what's
next.

## Phase 1: `init.sh`

One script, run FIRST on any machine. Detects what's missing, offers
the next step, resumes where it left off.

Drop `init.sh` together with `setup.sh`, `setup.bats`, `init.bats`
and `migrate_docker_backend.sh` in any folder (a fresh folder, or a
checkout of this repo's `scripts/`), then run it from there.

```bash
bash init.sh              # interactive: scan, then offer the next fix
bash init.sh --dir ~/dev/agents   # pick the workspace folder, no question
bash init.sh --check      # report only — changes nothing, always exit 0
bats init.bats            # the script's own test suite
```

**Where the workspace lives.** Resolved in this order: `--dir`, then
the folder `init.sh` already sits in (when it is `<root>/init/` of an
existing workspace), then the choice remembered from an earlier run,
then an existing `~/workspace` install, then a one-time question
(Enter = `~/workspace`). `--check` never asks and never saves.
The folder name is yours to pick; the guard looks at the folder, not
the name: it refuses `/`, your home folder or its parents, system
directories, Windows drives under `/mnt/<letter>`, and any non-empty
folder that isn't an existing install (staged scripts and the
workspace's own folders, like a `models/` left from a previous install,
don't count).
Paths may use letters, digits, `.`, `_`, `-` and `/` only. One
workspace per machine — container names and the dashboard port
(9119) are fixed.

After the workspace is built, the shipped scripts are COPIED into
`<root>/init/` — the originals stay where they are, so you can re-run
init from either place: `bash <root>/init/init.sh --check`.

Order it walks (each needs the one before it): machine env (systemd,
DNS, apt/https, git identity, bats) → docker backend → workspace
(`setup.sh`) → logins → hermes config.

The workspace step also copies `setup.sh` + `setup.bats` into
`<root>/infrastructure/bootstrap/` after bootstrapping — no manual
copy step needed. The `bootstrap/` copies stay for drift checks, and the same
files are copied into `<root>/init/` too.

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
