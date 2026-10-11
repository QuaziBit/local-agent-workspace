# Agent Authentication

**Companion to `architecture.md` and `getting-started.md`. How to get
an agent CLI actually authenticated inside an isolated container,
using a subscription instead of metered API billing — and the
mistakes that will otherwise eat an hour finding out the hard way.**

## The One Rule

Two different environment variables authenticate Claude Code, and
they are **not equivalent**:

| Variable | Billing | Use when |
|---|---|---|
| `ANTHROPIC_API_KEY` | Pay-per-token, metered | You want direct API billing |
| `CLAUDE_CODE_OAUTH_TOKEN` | Uses your Pro/Max subscription allocation | You already pay for Claude Pro/Max and want to use it |

**If both are set, `ANTHROPIC_API_KEY` wins — silently.** You can be
logged in and paying for Max and still get billed per-token, with no
warning. If a secrets file ever has both, delete the API key line.

The same logic applies to Codex CLI (`OPENAI_API_KEY` vs. a
ChatGPT Plus/Pro/Team login) — but as of this writing, Codex's
headless-subscription path hasn't been verified here the way
Claude's `setup-token` has. Treat Codex as API-key-only until that's
checked properly.

## Step-by-Step: Claude Code via Subscription

Assumes a project already exists under `~/workspace/projects/<name>/`
and the agent image builds cleanly (`docker compose ... build`).

### 1. Create a placeholder secrets file first

`dev.yaml` requires `${SECRETS_DIR}/${PROJECT}.env` to **exist**
before the container can start at all — including before you can get
inside it to generate a token. Chicken and egg. Break it with an
empty file:

```bash
touch ~/.secrets/<project>.env
chmod 600 ~/.secrets/<project>.env
```

### 2. Build and start the container

From `~/workspace/infrastructure/compose` — a native WSL terminal,
**not** a Windows terminal `cd`'d into `\\wsl.localhost\...` (same 9P
performance/path issues flagged everywhere else in this setup):

```bash
PROJECT=<project> docker compose --env-file ../workspace.env -f dev.yaml up --build -d
```

`PROJECT=<project>` must be glued directly to the front of the
command with no space breaking it — that's bash's syntax for "set
this variable for this one command." If it's on its own line, bash
tries to execute `<project>` as a program and fails with
`command not found`. If typing it inline each time is annoying,
`export PROJECT=<project>` once per terminal session instead.

### 3. Generate the token from inside the container

```bash
PROJECT=<project> docker compose --env-file ../workspace.env -f dev.yaml exec dev claude setup-token
```

Note: `exec dev claude setup-token` — not `exec dev bash claude
setup-token`. The latter doesn't chain two commands; it passes
`claude` and `setup-token` to `bash` as arguments, which bash tries
to interpret as a script filename and fails. Either run the command
directly against the container (above), or open a shell first and
run `claude setup-token` as a separate line once inside it.

This prints a URL. Open it in any regular browser — it doesn't need
to run inside WSL or the container. Log in with the Pro/Max account.
The terminal then prints a token starting `sk-ant-oat01-...` —
**shown once, copy it immediately.**

### 4. Write the real token into the secrets file — on the host

```bash
cat > ~/.secrets/<project>.env << 'EOF'
CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-your-actual-token-here
EOF
```

Confirm there's no `ANTHROPIC_API_KEY` line left over in this file
from an earlier attempt.

### 5. Force the container to pick up the new file

Editing the file on disk does **not** reach a container that's
already running — env vars are injected once, at container creation,
from whatever the file contained at that moment (in this case, the
empty placeholder from step 1):

```bash
PROJECT=<project> docker compose --env-file ../workspace.env -f dev.yaml up -d --force-recreate
```

### 6. Verify

```bash
PROJECT=<project> docker compose --env-file ../workspace.env -f dev.yaml exec dev claude
```

Should start straight into a session — no login prompt. First run
shows a one-time theme picker (`1. Auto`, `2. Dark mode`, ...); pick
one, it's cosmetic onboarding, not an error. Once inside, `/status`
should show the Pro/Max plan as the authenticated account, not an
API key.

## Mistakes Actually Made Getting Here

Kept deliberately, not cleaned up — these are exactly what a
first-time reader will otherwise hit:

- Tried to `cd` into `docker/agent/` and run `docker compose up`
  directly. Wrong directory — the compose *profiles* live in
  `infrastructure/compose/`; `docker/agent/` only holds the
  Dockerfile, referenced *by* those profiles, never run on its own.
- Used the Windows `\\wsl.localhost\Ubuntu\...` path instead of a
  native WSL terminal. Same 9P slowness/path-translation issues as
  everywhere else — always work from inside Ubuntu directly.
- Dropped the `PROJECT=` prefix, leaving bash trying to execute
  `hello-test` as a command.
- Tried to bring up the container before the secrets file existed at
  all — `env file ... not found`. Fixed by the placeholder-file step.
- Set `ANTHROPIC_API_KEY` initially (this doc's whole reason for
  existing) — would have silently overridden the subscription and
  billed per-token instead.
- Chained `exec dev bash claude setup-token` as one command, which
  bash parsed as "run `bash`, passing `claude` and `setup-token` as
  arguments" rather than two sequential commands.
- Edited the secrets file while the container was still running from
  before the token existed — the new value never reached it until
  `--force-recreate`.

Every one of these is now a step above instead of a debugging
session. If a future setup hits something new, add it here.

## Extending to Other Profiles

The same token works for `docs.yaml`, `review.yaml`, and `sandbox.yaml`
too — it's tied to the Claude.ai account, not to a single project or
profile. Reuse the same `CLAUDE_CODE_OAUTH_TOKEN` value in each
project's secrets file rather than generating a new one per project;
`claude setup-token` only needs to run again if the token is revoked
or its year-long validity expires.

## Addendum: the Browser Login Prompt on First Interactive Launch

Even with `CLAUDE_CODE_OAUTH_TOKEN` correctly set, the first
interactive `claude` launch inside a fresh container may still show
the login-method picker rather than skipping straight to a session.
This is a known first-run quirk, not a sign the token isn't working.

Selecting **"Claude account with subscription"** and completing the
resulting browser login — **with the same account that holds the
subscription** — still bills against the subscription either way.
The picker is about which auth path this one launch takes, not which
account gets billed.

## Addendum: Login Not Surviving `--force-recreate` — the Real Cause

Persisting `~/.claude/` alone is **not enough** to survive a
container recreate, even though it looks like it should be — this
took real debugging to track down, worth recording precisely.

**What happens:** after completing the browser login, `ls -la
~/.claude` correctly shows a fresh `.credentials.json`, owned by the
right user, right size, right timestamp. Everything looks like it
worked. Recreate the container, though, and it prompts for login
again — as if nothing had persisted at all.

**Why:** Claude Code splits its session state across **two separate
paths**, confirmed against Anthropic's own bug tracker
([anthropics/claude-code#14313](https://github.com/anthropics/claude-code/issues/14313))
and a community devcontainer report describing this exact scenario:

- `~/.claude/` — a directory; `.credentials.json` (the actual OAuth
  token) lives here.
- `~/.claude.json` — a **separate sibling file**, sitting directly in
  the home directory, *not* inside `.claude/` at all. This tracks
  onboarding/account status and is checked **first**. If it's
  missing, Claude Code re-triggers the full login flow — even with a
  perfectly valid credential sitting untouched in `.claude/`.

Persisting only `~/.claude/` leaves `~/.claude.json` on the
container's throwaway filesystem, wiped on every recreate. The
credential survives; the file that says "you're already logged in"
doesn't.

**Fix: bind-mount both paths, not one — and use `~/.secrets/`, not a
Docker-managed named volume.** This is genuinely a credential, so it
belongs where every other secret in this setup lives: host-visible,
removable with `rm`, not opaque behind `docker volume` commands.

```bash
# host-side, created once during bootstrap
mkdir -p ~/.secrets/claude-home
touch ~/.secrets/claude-home.json
chmod 700 ~/.secrets/claude-home
chmod 600 ~/.secrets/claude-home.json
```

```yaml
services:
  dev:
    volumes:
      # ...existing mounts...
      - ${SECRETS_DIR}/claude-home:/home/ubuntu/.claude
      - ${SECRETS_DIR}/claude-home.json:/home/ubuntu/.claude.json
```

Both lines are required — mounting only the directory reproduces the
exact bug this addendum describes. Applied identically across all
four profiles, since the login is tied to the Claude.ai account, not
any one profile or project.

**Verifying the fix actually worked** — this is the test that
matters, not just "the container starts":

1. Recreate, log in once (expected — the paths are freshly empty).
2. Recreate again, **immediately**, no other changes.
3. Launch `claude` a second time. It should now drop straight into a
   session with no picker, no browser, nothing. That's confirmation
   the fix holds — not step 1 succeeding, which would look identical
   whether or not persistence actually works.

If step 3 still prompts, check both paths landed correctly:

```bash
PROJECT=<project> docker compose --env-file ../workspace.env -f dev.yaml exec dev \
  ls -la /home/ubuntu/.claude.json /home/ubuntu/.claude/.credentials.json
```

If either is missing or empty, the mount isn't reaching the
container — check the compose file has both lines, and that
`~/.secrets/claude-home.json` exists as an actual file on the host
before the container starts (Docker silently creates a *directory*
at that path instead if the source file doesn't already exist,
which breaks the mount in a confusing, hard-to-diagnose way).

## Addendum: The Placeholder Itself Was Broken — `touch` vs. `echo '{}'`

A second, distinct bug, found the hard way on a genuinely fresh
bootstrap — separate from the persistence issue above, and it hits
**before** persistence even becomes relevant, on the very first
`claude` or `claude setup-token` launch against a brand-new
`claude-home.json`.

**Symptom:**

```
Claude configuration file at /home/ubuntu/.claude.json is corrupted:
JSON Parse error: Unexpected EOF
The corrupted file has been backed up to:
/home/ubuntu/.claude/backups/.claude.json.corrupted.<timestamp>
  Choose an option:
  ❯ 1. Exit and fix manually
    2. Reset with default configuration
```

**Cause:** the bootstrap step (both here and in `setup.sh`) originally
created the placeholder with `touch ~/.secrets/claude-home.json` — a
genuinely empty, 0-byte file. Claude Code tries to `JSON.parse()` this
file at startup; parsing an empty string throws exactly this error.
This isn't rare or environment-specific — it reproduced identically
across **two separate fresh bootstraps** in the same session, and
would hit anyone following the original steps exactly as written.

**Fix:** seed the placeholder with a valid empty JSON object instead
of nothing:

```bash
echo '{}' > ~/.secrets/claude-home.json
```

**Choosing "2. Reset with default configuration"** when this prompt
appears on an already-corrupted file is safe — it only resets the
onboarding/status file, not the actual credential sitting in
`~/.claude/.credentials.json`, which is a separate mount entirely and
untouched by this.

**A second bug, found while fixing the first one:** an early version
of this fix used `echo '{}' > ~/.secrets/claude-home.json`
unconditionally, every time the bootstrap script ran. That's *not*
idempotent — re-running the bootstrap against an environment with a
real, already-authenticated login silently overwrote it back to `{}`,
deleting a working login on every re-run. Caught by deliberately
simulating that exact scenario (write realistic login-shaped content,
re-run bootstrap, check whether it survived) rather than assuming a
fix that solves one problem doesn't introduce another. The corrected,
actually-safe version only seeds `{}` if the file is missing or still
genuinely empty:

```bash
if [ ! -s ~/.secrets/claude-home.json ]; then
  echo '{}' > ~/.secrets/claude-home.json
fi
```

`setup.sh` and `getting-started.md` both use this guarded form now.

## Confirmed Working End-to-End

The full chain — fresh workspace, correct compose files (bind mounts,
not the earlier named-volume dead end), clean `~/.secrets/`,
`claude setup-token` generating a fresh year-long token, a complete
interactive login, and a `--force-recreate` immediately afterward
that skipped the login prompt entirely — was run in full and
confirmed working. Specifically verified, not just assumed:

- `~/.secrets/claude-home/.credentials.json` — real content on the
  host (508 bytes), not empty.
- `~/.secrets/claude-home.json` — real JSON content after login, not
  `{}` and not corrupted.
- `docker volume ls` — empty; nothing Claude-related lives in a
  Docker-managed volume anymore, everything is host-visible under
  `~/.secrets/` as intended.
- A `--force-recreate` performed *after* a successful login dropped
  straight into a session — no theme picker, no login picker, no
  browser. That's the actual property this whole addendum exists to
  guarantee, and it held.

What it took to get there, in order, matches this document as
written above — plus the two bugs in this addendum, which weren't
known when the steps above were first drafted and are now fixed at
the source rather than left as something every future run rediscovers.

## Addendum: `CLAUDE_CODE_OAUTH_TOKEN` Is a One-Time Bootstrap Key, Not an Ongoing Dependency

Tested directly, not assumed: with a working login already established,
`CLAUDE_CODE_OAUTH_TOKEN` in `hello-test.env` was deliberately replaced
with a garbage value (`intentionally-broken`), the container was
`--force-recreate`'d, and `claude` was launched again.

**Result: it authenticated normally, no prompt, no error.** The broken
env var was never consulted. `~/.secrets/claude-home/.credentials.json`
is genuinely self-sufficient once populated — it holds an OAuth
access token *and* refresh token pair, so Claude Code renews its own
access token internally as needed, entirely within `.claude/`,
without reading `CLAUDE_CODE_OAUTH_TOKEN` again.

**What this means in practice:**

- `CLAUDE_CODE_OAUTH_TOKEN` matters for exactly one thing: getting
  through the *first* authorization, before any credential cache
  exists yet. After that, it's not actively read on every launch.
- **Still worth keeping, correctly stored, not discarded as
  "unused."** If `claude-home/` is ever deleted, corrupted, or
  moved to a fresh machine, this token is what lets you
  re-authenticate without generating a brand new one via
  `claude setup-token` again.
- This explains something from earlier in this document that
  wasn't obvious at the time: a *valid* token in the env file was
  never enough on its own to skip the login picker — the picker
  only stops appearing once the interactive step has actually run
  and populated the credential cache for the first time. The token
  authorizes the account; completing the login is what writes the
  cache that everything after that point actually relies on.

## Addendum: Where Credentials Are *Actually* Stored (No Fallback Tier)

Worth confirming directly rather than assuming, since several CLI
tools use a tiered strategy (try an OS keychain, fall back to a
plaintext file only if none is available) — Claude Code does **not**
do this for its core login credential. Per Anthropic's own docs
([code.claude.com/docs/en/authentication](https://code.claude.com/docs/en/authentication)):

> On macOS, credentials are stored in the encrypted macOS Keychain.
> On Linux, credentials are stored in `~/.claude/.credentials.json`
> with file mode 0600.

**On Linux — which is what this container runs — the file is the
primary, canonical storage, not a fallback.** There's no hidden
keyring tier underneath it that only sometimes gets used; macOS gets
Keychain integration for this specific credential, Linux never does,
by design. So `~/.secrets/claude-home/.credentials.json` genuinely
*is* the real thing, exactly as this document's mount design assumes
— nothing to second-guess there.

One separate thing worth not confusing with this: a newer Claude Code
feature (2.1.83+) stores *plugin-declared* credentials (API keys a
plugin asks for at install time) in an OS keychain where available.
That's a different credential system, for a different kind of secret,
and doesn't apply to the core OAuth login this document is about.

The 0600 permission Anthropic documents for `.credentials.json` also
matches what was independently observed in this project's own `ls -la`
output — confirmation the file mode isn't just this project's
convention, it's Claude Code's own documented behavior lining up with
it.

**Closing this out — the removal/restoration test, run for real:**

`claude-home/` and `claude-home.json` were moved out entirely (to a
temporary backup, not deleted), replaced with fresh empty
placeholders, and the container recreated. Result: the login prompt
returned, exactly as expected — confirming removal breaks it, not
just a broken token.

Then the original files were moved back onto the same host paths and
the container recreated again. Result: straight back into a working
session, no re-login needed.

That second half is the more useful confirmation: the credential is
fully portable, ordinary data — moving the exact same two files back
onto the same paths restored a working login immediately, with
nothing tied to a specific container instance. The entire Claude Code
login for this project lives in those two files, in full, and is
backup-able and restorable like anything else under `~/.secrets/`.

**One more quick confirmation:** a manual search through `~/.secrets/`
found `CLAUDE_CODE_OAUTH_TOKEN` in exactly one place — `hello-test.env`.
No copy of it in `claude-home.json` or `claude-home/`. Expected, and
good hygiene, not a gap: the bootstrap token and the live session
credential (`claudeAiOauth` / `accessToken` / `refreshToken`) are
different data entirely — Claude Code doesn't duplicate the token
into its own cache, it generates fresh session material from it once
and stores that instead. Single source of truth for the bootstrap
secret, as it should be.

## Codex CLI: Subscription Auth in a Container — Solved

The `features.md` open item ("verify Codex CLI's headless-subscription
auth path") is now resolved — it works, bills against the ChatGPT
plan, and persists across recreates. But it took two sessions of real
debugging, and the working recipe has two non-obvious parts, both
required.

### The working flow

1. **Login method: `codex login --device-auth`** — not plain
   `codex login`. The default flow starts a callback server on
   `localhost:1455` inside the container, which a host browser can
   never reach (confirmed: `ERR_CONNECTION_REFUSED` on the callback).
   Device-code auth polls OpenAI's servers instead — no callback, no
   port mapping needed. Prerequisite: enable **device code
   authorization** in ChatGPT → Settings → Security first (personal
   accounts; Workspace accounts need an admin to enable it). Note:
   this toggle needed re-enabling at least once across sessions — it
   may not stick permanently.
2. **Persistence: force `cli_auth_credentials_store = "file"` in
   `config.toml` BEFORE the first login** — this is the part that
   cost two sessions. Details below.

Billing confirmation: `/status` shows the account email with the plan
name and a monthly-limit bar; `/usage` shows lifetime token counts,
streaks, and a usage heatmap — subscription-quota language, not
dollar metering. No `OPENAI_API_KEY` anywhere in the environment.

### The persistence bug and its fix

**Symptom:** login always succeeded, but every `--force-recreate`
showed the sign-in screen again — identical to Claude Code's
pre-fix behavior, but with a completely different root cause.

**Ruled out, with evidence, before finding the real cause:**

- *The mount being broken* — ruled out three separate ways: the
  compose line was verified present and correct; host and container
  listings of `~/.codex` were byte-identical (goals/memories/logs
  SQLite databases all landing on the host with current timestamps);
  and real data persisted across recreates. The mount always worked.
- *Credential tied to container hostname* — tested directly:
  hostname changed across recreates (`4be48f6ff270` →
  `ee21d1b65d56`) while `installation_id` stayed identical, and
  the behavior didn't correlate. Not the mechanism.

**Root cause:** Codex's `cli_auth_credentials_store` setting defaults
to `"auto"` — use the OS keyring when available, fall back to
`auth.json` otherwise. Inside this minimal Ubuntu container, auto
mode routed the credential somewhere that died with the container —
so `auth.json` never appeared on the mounted path at all (searches
found only third-party plugin docs with "auth" in their filenames),
while everything else in `~/.codex` persisted fine. The credential
was the one thing not landing on the mount.

**Fix:** write this to the host side of the mount *before* the first
login:

```bash
echo 'cli_auth_credentials_store = "file"' > ~/.secrets/codex-home/config.toml
```

With that in place, a fresh device-code login produced
`~/.secrets/codex-home/auth.json` (4.2KB, mode 600) — the first time
it appeared in any attempt — and a subsequent `--force-recreate`
dropped straight into a working session with no sign-in screen.
Confirmed twice.

`setup.sh` and `getting-started.md` now seed this config.toml
automatically (guarded — an existing customized config.toml is never
overwritten), and all four compose profiles bind-mount
`${SECRETS_DIR}/codex-home:/home/ubuntu/.codex`.

### Ordering matters — the general lesson, twice confirmed

Both agents' persistence bugs shared one shape: **the fix must be in
place before the login happens, or the login lands somewhere that
doesn't survive.** For Claude Code that meant both bind mounts
present before the interactive login; for Codex it means config.toml
forcing file storage before `codex login --device-auth`. A login
performed before the fix looks successful and works for that
container's lifetime — the failure only shows on the next recreate,
which is exactly what makes this class of bug expensive to diagnose.
