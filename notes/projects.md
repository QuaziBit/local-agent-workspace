# Working on a Real Project

Two separate ways to bring a project in, depending on whether you
want Hermes chat involved. Both need the project under
`~/workspace/projects/<name>` with its own `git init` — that part's
shared. Everything else differs.

| | `dev` tier | `--project=<name>` |
|---|---|---|
| Who drives `claude`/`codex` | You, directly, interactively | Hermes, via delegation |
| Hermes chat involved | No | Yes |
| `.secrets/<name>.env` | Required | Not used |
| `AGENTS.md` copied in | Recommended | Not needed |
| Mount | `/workspace`, read-write | `/workspace`, read-write |
| `git init` | Recommended (same reason) | Required (Codex's trust check) |

Nothing stops you from setting up both for the same project —
`git init` is shared, everything else is independent.

## One-time setup (needed either way)

```bash
mv /path/to/your/project ~/workspace/projects/<name>
cd ~/workspace/projects/<name>
git init      # Codex's trust check needs this; skip if already a repo
```

Zero commits is fine — confirmed sufficient in testing.

---

## Option A: the `dev` tier — you drive the CLIs directly

No Hermes chat involved. You get a container with the project
mounted read-write, the vault read-only (plus `agent_inbox`
writable), network on.

```bash
touch ~/.secrets/<name>.env      # dev.yaml requires this file to exist — empty is fine
cp ~/workspace/infrastructure/templates/AGENTS.md .
nano AGENTS.md                    # fill in "Project-Specific Instructions"
run.sh dev <name>
```

`AGENTS.md`'s top section (scope, standards, conventions) is shared
boilerplate — don't touch it. The bottom section is project-specific:
language/framework, build/test/lint commands, anything unusual.

**Interactive** (best for back-and-forth):
```bash
claude
# or
codex
```

**One-shot, non-interactive** — both CLIs default to blocking writes
here; these flags are required, not optional:
```bash
claude -p --permission-mode acceptEdits "<task>"
codex exec --sandbox workspace-write "<task>"
```
Real projects with their own `git init` don't need
`--skip-git-repo-check` — that flag is only for scratch/non-repo
directories.

### The other three tiers under `dev`

| Profile | Project mount | Network | Use for |
|---|---|---|---|
| `dev` | read-write | on | the default — real work |
| `docs` | read-write | **off** | file/doc editing, no AI |
| `review` | **read-only** | off | auditing without risk of changing anything |
| `sandbox` | none (own scratch space) | on | trying something before it has a project home |

```bash
run.sh docs <name>      # offline, still read-write
run.sh review <name>    # read-only, offline
```

`docs`/`review` are genuinely offline. Host-verified behavior: a
`claude -p`/`codex` call there doesn't fail fast — it hangs with no
self-timeout. Wrap in `timeout` if scripting it:
```bash
timeout 15 claude -p "say hi"    # exit code 124 = correctly blocked, not a bug
```
`review`'s read-only enforcement is real filesystem enforcement
(`EROFS`), confirmed by direct test — not an application-layer
suggestion.

---

## Option B: `--project=<name>` — Hermes chat drives it

Mounts `~/workspace/projects/<name>` read-write at `/workspace`
inside the Hermes container — for that one session (ephemeral
profiles) or for that dashboard's whole lifetime (dashboard
profiles). That's the only difference from a normal Hermes session.

```bash
run.sh --project=<name> hermes_all         # or hermes/hermes_claude/hermes_codex
run.sh --project=<name> dashboard_all      # or dashboard/dashboard_claude/dashboard_codex
```

No `.env` file, no `AGENTS.md` copy needed — those are `dev`-tier
specific.

### Writing into `/workspace` — the terminal tool only, confirmed both directions

Hermes's own `write_file` tool is hard-scoped to
`HERMES_WRITE_SAFE_ROOT` (`agent_inbox` + `/opt/data`) — a setting
`--project` never touches, since `--project` only adds a bind mount.
**`write_file` cannot reach `/workspace`, no matter the phrasing.**
Confirmed directly (host-verified, both sides of the same test):

```
write a file called test.txt with the text X to /workspace
```
→ correctly denied — raw tool output: `Write denied: '...' is
outside HERMES_WRITE_SAFE_ROOT`.

```
Use your terminal tool with workdir=/workspace to run: claude -p --permission-mode acceptEdits "create test.txt with the text X"
```
→ succeeded, file confirmed on disk.

Same pattern holds for Codex (`pty=true` + `--sandbox
workspace-write`) and for a bare shell redirect through the terminal
tool — all three AIs write to `/workspace` successfully, only
through the terminal tool:

```
Use your terminal tool with workdir=/workspace and pty=true to run: codex exec --skip-git-repo-check --sandbox workspace-write "<task>"
Use your terminal tool with workdir=/workspace to run: bash -c "echo '<content>' > <name>.txt"
```
(No `--skip-git-repo-check` needed for Codex if the project already
has its own real `git init` — the setup step above already
satisfies that gate.)

### `agent_inbox` writes are UNRELIABLE while `--project` is active — new finding

This is not the same as the `/workspace` restriction above, and it's
worth calling out on its own: while `--project` is active, asking
`write_file` to write into `agent_inbox` (not `/workspace`) has been
observed to fail intermittently — including at least one case where
Hermes reported success and the file was never actually created.
Confirmed across repeated attempts, both `hermes_all` and
`dashboard_all`: sometimes an honest failure, sometimes a fabricated
success, sometimes it genuinely works. No phrasing fix reliably
avoids it.

**Route `agent_inbox` writes through the terminal tool too, while
`--project` is active** — that path has been 100% reliable in every
test:
```
Use your terminal tool with workdir=/vault/agent_inbox to run: bash -c "echo '<content>' > <name>.txt"
```
Outside a `--project` session, plain `write_file` to `agent_inbox`
has never shown this problem — it's specific to the `--project`
combination.

| Target | `write_file` | Terminal tool |
|---|---|---|
| `agent_inbox`, no `--project` active | ✅ reliable | ✅ works |
| `agent_inbox`, `--project` active | ⚠️ unreliable — verify every time | ✅ reliable |
| `/workspace` (`--project`) | ❌ never works | ✅ works |

## Common snags

- **Write silently doesn't happen** → missing `--permission-mode
  acceptEdits` (claude) or `--sandbox workspace-write` (codex).
- **`dev.yaml declares env_file ... and it doesn't exist`** →
  `touch ~/.secrets/<name>.env`.
- **Codex refuses the directory** ("not a trusted directory") →
  needs its own `git init` at the project root, not a parent
  directory's.
- **`claude -p` hangs forever** → no self-timeout if offline; only
  relevant in `docs`/`review`, or if network genuinely drops.
- **Multi-command shell chains through Hermes** (not the `dev` tier)
  → wrap in `bash -c "cmd1 && cmd2"`.
- **A `write_file` call to `agent_inbox` reports success but the file
  isn't there** → you're in a `--project` session; see above.

---
See also: `workflows.md` ("what do I reach for"),
`agent_tier_operations.md` (the full mount-boundary and permission
details), `delegation_phrasing.md` (delegation phrasing and
`workdir=` requirements in depth).
